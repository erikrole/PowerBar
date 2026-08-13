import Foundation
import Darwin

struct CommandResult: Sendable {
    let output: String
    let exitCode: Int32
}

enum CommandRunnerError: LocalizedError {
    case failed(command: String, exitCode: Int32, detail: String)
    case timedOut(command: String, seconds: TimeInterval)
    case outputLimitExceeded(command: String, bytes: Int)

    var errorDescription: String? {
        switch self {
        case .failed(let command, let exitCode, let detail):
            let suffix = detail.isEmpty ? "" : ": \(detail)"
            return "\(command) exited with status \(exitCode)\(suffix)"
        case .timedOut(let command, let seconds):
            return "\(command) did not finish within \(Int(seconds.rounded())) seconds."
        case .outputLimitExceeded(let command, let bytes):
            return "\(command) produced more than \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))."
        }
    }
}

enum CommandRunner {
    static let defaultTimeout: TimeInterval = 20
    static let defaultOutputLimit = 8 * 1_024 * 1_024

    static func run(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval = defaultTimeout,
        outputLimit: Int = defaultOutputLimit
    ) async throws -> CommandResult {
        let control = ProcessControl()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                let command = URL(fileURLWithPath: executable).lastPathComponent
                let process = Process()
                let output = Pipe()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.standardOutput = output
                process.standardError = output

                do {
                    try process.run()
                } catch {
                    _ = control.finish()
                    throw error
                }

                if control.attach(process) != nil {
                    control.stopAttachedProcess()
                }

                let reader = Task.detached(priority: .utility) {
                    try drain(
                        output.fileHandleForReading,
                        limit: outputLimit,
                        onLimitExceeded: { control.requestStop(.outputLimit) }
                    )
                }
                let timeoutTask = Task.detached(priority: .utility) {
                    let nanoseconds = UInt64(max(0.01, timeout) * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: nanoseconds)
                    guard !Task.isCancelled else { return }
                    control.requestStop(.timedOut)
                }

                process.waitUntilExit()
                timeoutTask.cancel()
                let data: Data
                do {
                    data = try await reader.value
                } catch {
                    _ = control.finish()
                    throw error
                }
                let stopReason = control.finish()

                switch stopReason {
                case .cancelled:
                    throw CancellationError()
                case .timedOut:
                    throw CommandRunnerError.timedOut(command: command, seconds: timeout)
                case .outputLimit:
                    throw CommandRunnerError.outputLimitExceeded(command: command, bytes: outputLimit)
                case nil:
                    break
                }

                let decoded = String(decoding: data, as: UTF8.self)
                guard process.terminationStatus == 0 else {
                    let detail = decoded
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .prefix(400)
                    throw CommandRunnerError.failed(
                        command: command,
                        exitCode: process.terminationStatus,
                        detail: String(detail)
                    )
                }

                return CommandResult(
                    output: decoded,
                    exitCode: process.terminationStatus
                )
            }.value
        } onCancel: {
            control.requestStop(.cancelled)
        }
    }

    private static func drain(
        _ handle: FileHandle,
        limit: Int,
        onLimitExceeded: () -> Void
    ) throws -> Data {
        var collected = Data()
        var didExceedLimit = false

        while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
            let remaining = max(0, limit - collected.count)
            if remaining > 0 {
                collected.append(chunk.prefix(remaining))
            }
            if chunk.count > remaining, !didExceedLimit {
                didExceedLimit = true
                onLimitExceeded()
            }
        }

        return collected
    }
}

private final class ProcessControl: @unchecked Sendable {
    enum StopReason: Equatable {
        case cancelled
        case timedOut
        case outputLimit
    }

    private let lock = NSLock()
    private var process: Process?
    private var stopReason: StopReason?
    private var isFinished = false

    func attach(_ process: Process) -> StopReason? {
        lock.lock()
        defer { lock.unlock() }
        self.process = process
        return stopReason
    }

    func requestStop(_ reason: StopReason) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        if stopReason == nil {
            stopReason = reason
        }
        let process = process
        lock.unlock()

        stop(process)
    }

    func stopAttachedProcess() {
        lock.lock()
        let process = process
        lock.unlock()
        stop(process)
    }

    func finish() -> StopReason? {
        lock.lock()
        defer { lock.unlock() }
        isFinished = true
        process = nil
        return stopReason
    }

    private func stop(_ process: Process?) {
        guard let process, process.isRunning else { return }
        let processIdentifier = process.processIdentifier
        process.terminate()

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) {
            guard process.isRunning else { return }
            Darwin.kill(processIdentifier, SIGKILL)
        }
    }
}

enum PowerParser {
    static func battery(pmset: String, ioreg: String, capturedAt: Date = Date()) -> BatteryReading {
        var reading = BatteryReading(capturedAt: capturedAt)
        let lines = pmset.components(separatedBy: .newlines)
        if let sourceLine = lines.first(where: { $0.contains("Now drawing from") }),
           let source = firstCapture("'([^']+)'", in: sourceLine) {
            reading.powerSource = source
        }

        if let batteryLine = lines.first(where: { $0.contains("InternalBattery") }) {
            if let percent = firstCapture("(\\d+)%", in: batteryLine) {
                reading.percentage = Int(percent)
            }
            let fields = batteryLine.split(separator: ";").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if fields.count > 1 { reading.state = fields[1] }
            if fields.count > 2 {
                reading.estimate = firstCapture(#"(\d+:\d+)"#, in: fields[2])
            }
        }

        reading.voltageMillivolts = registryInteger("Voltage", in: ioreg).flatMap(Int.init(exactly:))
        reading.amperageMilliamps = signedRegistryInteger("InstantAmperage", in: ioreg).flatMap(Int.init(exactly:))
        reading.cycleCount = registryInteger("CycleCount", in: ioreg).flatMap(Int.init(exactly:))
        reading.maxCapacity = registryInteger("MaxCapacity", in: ioreg).flatMap(Int.init(exactly:))
        if let rawTemperature = registryInteger("Temperature", in: ioreg) {
            reading.temperatureCelsius = Double(rawTemperature) / 100
        }
        reading.isCharging = registryBoolean("IsCharging", in: ioreg) || reading.state.localizedCaseInsensitiveCompare("charging") == .orderedSame
        reading.isFullyCharged = registryBoolean("FullyCharged", in: ioreg) || reading.state.localizedCaseInsensitiveContains("charged")

        if let millivolts = reading.voltageMillivolts,
           let milliamps = reading.amperageMilliamps {
            reading.estimatedWatts = Double(millivolts) * Double(milliamps) / 1_000_000
        }
        return reading
    }

    static func assertions(_ text: String) -> [PowerAssertion] {
        var results: [PowerAssertion] = []
        let pattern = #"pid\s+\d+\(([^)]+)\):\s+\[[^]]+\]\s+([0-9:]+)\s+([^\s]+)\s+named:\s+\"([^\"]+)\""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        for line in text.components(separatedBy: .newlines) where line.contains("pid ") {
            let range = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: line, range: range), match.numberOfRanges == 5 else { continue }
            let process = capture(match, group: 1, in: line)
            let age = capture(match, group: 2, in: line)
            let kind = capture(match, group: 3, in: line)
            let reason = capture(match, group: 4, in: line)
            results.append(PowerAssertion(
                id: "\(process)-\(kind)-\(reason)",
                process: process,
                kind: humanizeAssertion(kind),
                reason: reason,
                age: age
            ))
        }
        return Array(results.prefix(12))
    }

    static func events(_ text: String) -> [PowerEvent] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        let isoFormatter = ISO8601DateFormatter()

        let relevant = text.components(separatedBy: .newlines).filter { line in
            ["Entering Sleep", "Wake from", "DarkWake", "Using Batt", "Using AC", "Charge:"].contains {
                line.localizedCaseInsensitiveContains($0)
            }
        }
        return relevant.suffix(20).reversed().enumerated().map { offset, line in
            let timestamp = firstCapture(
                #"^(\d{4}-\d{2}-\d{2}(?: |T)\d{2}:\d{2}:\d{2}(?: [-+]\d{4}|Z|[-+]\d{2}:\d{2}))"#,
                in: line
            )
            let date = timestamp.flatMap { formatter.date(from: $0) ?? isoFormatter.date(from: $0) }
            let title: String
            if line.contains("Entering Sleep") { title = "Sleep" }
            else if line.contains("DarkWake") { title = "Dark wake" }
            else if line.contains("Wake from") { title = "Wake" }
            else if line.contains("Using AC") { title = "Connected to power" }
            else if line.contains("Using Batt") { title = "Switched to battery" }
            else { title = "Charge changed" }

            let detail = line
                .replacingOccurrences(of: timestamp ?? "", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return PowerEvent(id: "\(timestamp ?? "event")-\(offset)-\(title)", date: date, title: title, detail: detail)
        }
    }

    static func consumers(top: String, processes: String) -> [PowerConsumer] {
        let processPaths = processCommandPaths(processes)
        let lines = top.components(separatedBy: .newlines)
        guard let headerIndex = lines.lastIndex(where: { line in
            line.trimmingCharacters(in: .whitespaces).hasPrefix("PID") && line.contains("POWER")
        }) else { return [] }

        let pattern = #"^\s*(\d+)\s+(.+?)\s+(\d+(?:\.\d+)?)\s+(\d+(?:\.\d+)?)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var grouped: [String: (power: Double, cpu: Double, count: Int, isApplication: Bool)] = [:]

        for line in lines.suffix(from: lines.index(after: headerIndex)) {
            let range = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: line, range: range), match.numberOfRanges == 5,
                  let pid = Int(capture(match, group: 1, in: line)),
                  let cpu = Double(capture(match, group: 3, in: line)),
                  let power = Double(capture(match, group: 4, in: line)),
                  power > 0 else { continue }

            let command = capture(match, group: 2, in: line).trimmingCharacters(in: .whitespaces)
            let path = processPaths[pid] ?? ""
            let appName = firstCapture(#"(?:^|/)([^/]+)\.app(?:/|$)"#, in: path)
            let name = appName ?? command
            guard name != "PowerBar", name != "top" else { continue }

            let existing = grouped[name] ?? (0, 0, 0, appName != nil)
            grouped[name] = (
                existing.power + power,
                existing.cpu + cpu,
                existing.count + 1,
                existing.isApplication || appName != nil
            )
        }

        return grouped.map { name, value in
            PowerConsumer(
                name: name,
                powerScore: value.power,
                cpuPercentage: value.cpu,
                processCount: value.count,
                isApplication: value.isApplication
            )
        }
        .sorted {
            if $0.powerScore == $1.powerScore { return $0.name < $1.name }
            return $0.powerScore > $1.powerScore
        }
        .prefix(8)
        .map { $0 }
    }

    private static func registryInteger(_ key: String, in text: String) -> UInt64? {
        guard let raw = firstCapture("\\\"\(NSRegularExpression.escapedPattern(for: key))\\\"\\s*=\\s*(\\d+)", in: text) else { return nil }
        return UInt64(raw)
    }

    private static func signedRegistryInteger(_ key: String, in text: String) -> Int64? {
        guard let raw = registryInteger(key, in: text) else { return nil }
        return Int64(bitPattern: raw)
    }

    private static func registryBoolean(_ key: String, in text: String) -> Bool {
        firstCapture("\\\"\(NSRegularExpression.escapedPattern(for: key))\\\"\\s*=\\s*(Yes|No)", in: text) == "Yes"
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1 else { return nil }
        return capture(match, group: 1, in: text)
    }

    private static func capture(_ match: NSTextCheckingResult, group: Int, in text: String) -> String {
        guard let range = Range(match.range(at: group), in: text) else { return "" }
        return String(text[range])
    }

    private static func humanizeAssertion(_ value: String) -> String {
        switch value {
        case "NoDisplaySleepAssertion", "PreventUserIdleDisplaySleep": return "Keeps display awake"
        case "NoIdleSleepAssertion", "PreventUserIdleSystemSleep": return "Keeps Mac awake"
        default: return value
        }
    }

    private static func processCommandPaths(_ text: String) -> [Int: String] {
        var paths: [Int: String] = [:]
        let pattern = #"^\s*(\d+)\s+(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return paths }
        for line in text.components(separatedBy: .newlines) {
            let range = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: line, range: range), match.numberOfRanges == 3,
                  let pid = Int(capture(match, group: 1, in: line)) else { continue }
            paths[pid] = capture(match, group: 2, in: line)
        }
        return paths
    }
}

enum PowerDataSource {
    static func load(includeHistory: Bool) async throws -> PowerStatus {
        async let batteryResult = CommandRunner.run("/usr/bin/pmset", ["-g", "batt"])
        async let registryResult = CommandRunner.run("/usr/sbin/ioreg", ["-rn", "AppleSmartBattery"])
        async let assertionResult = CommandRunner.run("/usr/bin/pmset", ["-g", "assertions"])
        async let cableResult = CableDataSource.load()

        let battery = try await batteryResult
        let registry = try await registryResult
        let assertion = try await assertionResult
        let cables = await cableResult
        var events: [PowerEvent] = []
        if includeHistory {
            events = try await loadRecentEvents()
        }
        return PowerStatus(
            reading: PowerParser.battery(pmset: battery.output, ioreg: registry.output),
            assertions: PowerParser.assertions(assertion.output),
            events: events,
            cables: cables
        )
    }

    static func loadConsumers() async throws -> [PowerConsumer] {
        async let topResult = CommandRunner.run(
            "/usr/bin/top",
            ["-l", "2", "-s", "1", "-n", "20", "-o", "power", "-stats", "pid,command,cpu,power"]
        )
        async let processResult = CommandRunner.run("/bin/ps", ["-wwaxo", "pid=,comm="])
        let top = try await topResult
        let processes = try await processResult
        return PowerParser.consumers(top: top.output, processes: processes.output)
    }

    private static func loadRecentEvents(now: Date = Date()) async throws -> [PowerEvent] {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy.MM.dd"

        let calendar = Calendar.current
        let candidateDates = [
            calendar.date(byAdding: .day, value: -1, to: now),
            now,
        ].compactMap { $0 }
        let files = candidateDates
            .map { "/var/log/powermanagement/\(formatter.string(from: $0)).asl" }
            .filter { FileManager.default.fileExists(atPath: $0) }
        guard !files.isEmpty else { return [] }

        let eventPattern = "Entering (DarkWake|Sleep)|Wake from|DarkWake|Using (Batt|AC)|Charge:"
        let result = try await CommandRunner.run(
            "/usr/bin/syslog",
            ["-f"] + files + [
                "-F", "$((Time)(ISO8601Z)) $Message",
                "-k", "Time", "ge", "-24h",
                "-k", "Message", "R", eventPattern,
            ]
        )
        return PowerParser.events(result.output)
    }
}
