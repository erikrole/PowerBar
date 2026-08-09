import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class PowerMonitor {
    private(set) var reading = BatteryReading.empty
    private(set) var assertions: [PowerAssertion] = []
    private(set) var events: [PowerEvent] = []
    private(set) var snapshots: [BatterySnapshot] = []
    private(set) var history: [BatteryHistorySample] = []
    private(set) var consumers: [PowerConsumer] = []
    private(set) var cables = CableStatus.empty
    private(set) var isRefreshing = false
    private(set) var isRefreshingConsumers = false
    private(set) var lastError: String?
    private(set) var lastUpdated: Date?
    private(set) var consumersUpdated: Date?
    private var lastReliableCableReadingAt: Date?

    init() {
        snapshots = SnapshotStore.load()
        history = HistoryStore.load()
        Task { [weak self] in
            // Get the menu-bar value immediately. Loading pmset's full sleep log can
            // take several seconds, and the status item should never start as blank.
            await self?.refresh(includeHistory: false)
            await self?.refresh(includeHistory: true)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard self != nil else { return }
                await self?.refresh(includeHistory: false)
            }
        }
        Task { [weak self] in
            await self?.refreshConsumers()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard self != nil else { return }
                await self?.refreshConsumers()
            }
        }
    }

    func refresh(includeHistory: Bool = true) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let status = try await PowerDataSource.load(includeHistory: includeHistory)
            reading = status.reading
            assertions = status.assertions
            let now = Date()
            let cableResolution = CableStatusPolicy.resolve(
                incoming: status.cables,
                previous: cables,
                battery: status.reading,
                lastReliableAt: lastReliableCableReadingAt,
                now: now
            )
            cables = cableResolution.status
            lastReliableCableReadingAt = cableResolution.lastReliableAt
            if includeHistory {
                events = status.events
            }
            lastUpdated = now
            lastError = nil
            recordHistoryIfNeeded()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func refreshAll() async {
        async let status: Void = refresh(includeHistory: true)
        async let energy: Void = refreshConsumers()
        _ = await (status, energy)
    }

    func refreshConsumers() async {
        guard !isRefreshingConsumers else { return }
        isRefreshingConsumers = true
        defer { isRefreshingConsumers = false }
        do {
            consumers = try await PowerDataSource.loadConsumers()
            consumersUpdated = Date()
        } catch {
            if consumers.isEmpty {
                lastError = error.localizedDescription
            }
        }
    }

    func captureSnapshot() {
        guard reading.percentage != nil else { return }
        snapshots.insert(BatterySnapshot(reading: reading), at: 0)
        snapshots = Array(snapshots.prefix(50))
        do {
            try SnapshotStore.save(snapshots)
            NSSound(named: "Tink")?.play()
        } catch {
            lastError = "Couldn’t save snapshot: \(error.localizedDescription)"
        }
    }

    func openSnapshotsFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([SnapshotStore.fileURL])
    }

    private func recordHistoryIfNeeded() {
        guard reading.percentage != nil else { return }
        if let lastSample = history.last,
           reading.capturedAt.timeIntervalSince(lastSample.capturedAt) < BatteryHistoryPolicy.minimumSampleInterval {
            return
        }

        history.append(BatteryHistorySample(reading: reading))
        history = BatteryHistoryPolicy.samplesToKeep(history, now: reading.capturedAt)
        do {
            try HistoryStore.save(history)
        } catch {
            lastError = "Couldn’t save history: \(error.localizedDescription)"
        }
    }
}

enum SnapshotStore {
    static let fileURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appending(path: "PowerBar", directoryHint: .isDirectory)
            .appending(path: "snapshots.json", directoryHint: .notDirectory)
    }()

    static func load() -> [BatterySnapshot] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder.powerBar.decode([BatterySnapshot].self, from: data)) ?? []
    }

    static func save(_ snapshots: [BatterySnapshot]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder.powerBar.encode(snapshots)
        try data.write(to: fileURL, options: .atomic)
    }
}

enum HistoryStore {
    static let fileURL: URL = {
        SnapshotStore.fileURL.deletingLastPathComponent()
            .appending(path: "history.json", directoryHint: .notDirectory)
    }()

    static func load() -> [BatteryHistorySample] {
        guard let data = try? Data(contentsOf: fileURL),
              let samples = try? JSONDecoder.powerBar.decode([BatteryHistorySample].self, from: data) else {
            return []
        }
        return BatteryHistoryPolicy.samplesToKeep(samples, now: Date())
    }

    static func save(_ samples: [BatteryHistorySample]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder.powerBar.encode(samples)
        try data.write(to: fileURL, options: .atomic)
    }
}

private extension JSONEncoder {
    static var powerBar: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var powerBar: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
