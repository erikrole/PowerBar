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
    private(set) var snapshotLoadError: String?
    private(set) var historyLoadError: String?
    private(set) var consumers: [PowerConsumer] = []
    private(set) var cables = CableStatus.empty
    private(set) var isRefreshing = false
    private(set) var isRefreshingConsumers = false
    private(set) var lastError: String?
    private(set) var lastUpdated: Date?
    private(set) var consumersUpdated: Date?
    private(set) var consumerError: String?
    private(set) var cableNotificationsEnabled: Bool
    private(set) var cableNotificationAuthorization = CableNotificationAuthorization.unknown
    private(set) var cableNotificationFeedback: String?
    private var lastReliableCableReadingAt: Date?
    private var powerSourceObserver: PowerSourceObserver?
    private var cableConnectionObserver: CableConnectionObserver?
    @ObservationIgnored private lazy var cableNotificationController = CableNotificationController()
    private var cableNotificationRefreshTask: Task<Void, Never>?
    private var consumerRefreshTask: Task<Void, Never>?
    private var cableRefreshGeneration = 0

    init() {
        let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        if isRunningTests {
            cableNotificationsEnabled = false
            return
        }

        switch SnapshotStore.load() {
        case .loaded(let loadedSnapshots):
            snapshots = loadedSnapshots
        case .unreadable(let error):
            snapshotLoadError = error
        }
        switch HistoryStore.load() {
        case .loaded(let loadedHistory):
            history = loadedHistory
        case .unreadable(let error):
            historyLoadError = error
        }
        cableNotificationsEnabled = UserDefaults.standard.object(forKey: "cableNotificationsEnabled") as? Bool ?? true
        powerSourceObserver = PowerSourceObserver { [weak self] in
            Task { @MainActor [weak self] in
                await self?.refreshAfterPowerSourceChange()
            }
        }
        cableConnectionObserver = CableConnectionObserver { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleCableNotificationRefresh()
            }
        }
        Task { [weak self] in
            // Publish the menu-bar value before asking for extended history so the
            // status item never starts blank.
            await self?.refresh(includeHistory: false)
            await self?.refresh(includeHistory: true)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard self != nil else { return }
                await self?.refresh(includeHistory: false)
            }
        }
    }

    func setPopoverVisible(_ isVisible: Bool) {
        consumerRefreshTask?.cancel()
        consumerRefreshTask = nil
        guard isVisible else { return }

        consumerRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while isRefreshingConsumers {
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    return
                }
            }
            await refreshConsumers()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    return
                }
                await refreshConsumers()
            }
        }
    }

    func startCableNotifications() {
        guard cableNotificationsEnabled else { return }
        requestCableNotificationAuthorization()
    }

    func setCableNotificationsEnabled(_ isEnabled: Bool) {
        cableNotificationsEnabled = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: "cableNotificationsEnabled")
        if isEnabled {
            requestCableNotificationAuthorization()
        }
    }

    func sendTestCableNotification() {
        requestCableNotificationAuthorization { [weak self] authorized in
            guard let self, authorized else { return }
            cableNotificationController.sendTestNotification { [weak self] error in
                guard let self else { return }
                cableNotificationFeedback = error.map { "Notification failed: \($0)" }
                    ?? "Notification request accepted"
            }
        }
    }

    func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    private func requestCableNotificationAuthorization(
        completion: (@MainActor @Sendable (Bool) -> Void)? = nil
    ) {
        cableNotificationController.requestAuthorizationIfNeeded { [weak self] status, error in
            guard let self else { return }
            cableNotificationAuthorization = status
            if let error {
                cableNotificationFeedback = "Permission failed: \(error)"
            } else if status == .denied {
                cableNotificationFeedback = "Notifications are blocked in System Settings"
            }
            completion?(status == .authorized)
        }
    }

    func refresh(includeHistory: Bool = true) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        let cableGeneration = beginCableRefresh()
        defer { isRefreshing = false }
        do {
            let status = try await PowerDataSource.load(includeHistory: includeHistory)
            reading = status.reading
            assertions = status.assertions
            let now = Date()
            acceptCableStatus(status.cables, generation: cableGeneration, now: now)
            if includeHistory {
                events = status.events
            }
            lastUpdated = now
            lastError = nil
            recordHistoryIfNeeded()
        } catch is CancellationError {
            return
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func refreshAfterPowerSourceChange() async {
        // Give macOS a moment to publish the new source, then avoid losing the
        // notification if another refresh is already in flight.
        do {
            try await Task.sleep(for: .milliseconds(150))
        } catch {
            return
        }
        while isRefreshing {
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return
            }
        }
        await refresh(includeHistory: false)
        scheduleCableNotificationRefresh()
    }

    private func scheduleCableNotificationRefresh() {
        cableNotificationRefreshTask?.cancel()
        let generation = beginCableRefresh()
        cableNotificationRefreshTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(1500))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            let incoming = await CableDataSource.load()
            guard !Task.isCancelled else { return }
            acceptCableStatus(incoming, generation: generation, now: Date())
        }
    }

    private func beginCableRefresh() -> Int {
        cableRefreshGeneration &+= 1
        return cableRefreshGeneration
    }

    private func acceptCableStatus(_ incoming: CableStatus, generation: Int, now: Date) {
        guard generation == cableRefreshGeneration else { return }
        let resolution = CableStatusPolicy.resolve(
            incoming: incoming,
            previous: cables,
            battery: reading,
            lastReliableAt: lastReliableCableReadingAt,
            now: now
        )
        cables = resolution.status
        lastReliableCableReadingAt = resolution.lastReliableAt
        cableNotificationController.reconcile(
            with: cables,
            battery: reading,
            notificationsEnabled: cableNotificationsEnabled
        )
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
            consumerError = nil
        } catch is CancellationError {
            return
        } catch {
            consumerError = error.localizedDescription
        }
    }

    func captureSnapshot() {
        guard reading.percentage != nil else { return }
        guard snapshotLoadError == nil else {
            lastError = "Snapshots could not be read, so PowerBar left the existing file unchanged."
            return
        }
        let updatedSnapshots = Array(([BatterySnapshot(reading: reading)] + snapshots).prefix(50))
        do {
            try SnapshotStore.save(updatedSnapshots)
            snapshots = updatedSnapshots
            NSSound(named: "Tink")?.play()
        } catch {
            lastError = "Couldn’t save snapshot: \(error.localizedDescription)"
        }
    }

    func openSnapshotsFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([SnapshotStore.fileURL])
    }

    func openHistoryFile() {
        NSWorkspace.shared.activateFileViewerSelecting([HistoryStore.fileURL])
    }

    private func recordHistoryIfNeeded() {
        guard reading.percentage != nil else { return }
        guard historyLoadError == nil else { return }
        if let lastSample = history.last,
           reading.capturedAt.timeIntervalSince(lastSample.capturedAt) < BatteryHistoryPolicy.minimumSampleInterval {
            return
        }

        let updatedHistory = BatteryHistoryPolicy.samplesToKeep(
            history + [BatteryHistorySample(reading: reading)],
            now: reading.capturedAt
        )
        do {
            try HistoryStore.save(updatedHistory)
            history = updatedHistory
        } catch {
            lastError = "Couldn’t save history: \(error.localizedDescription)"
        }
    }
}

enum LocalStoreLoadResult<Value> {
    case loaded(Value)
    case unreadable(String)
}

enum SnapshotStore {
    static let fileURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appending(path: "PowerBar", directoryHint: .isDirectory)
            .appending(path: "snapshots.json", directoryHint: .notDirectory)
    }()

    static func load(from url: URL = fileURL) -> LocalStoreLoadResult<[BatterySnapshot]> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .loaded([]) }
        do {
            let data = try Data(contentsOf: url)
            return .loaded(try JSONDecoder.powerBar.decode([BatterySnapshot].self, from: data))
        } catch {
            return .unreadable("Couldn’t read snapshots.json: \(error.localizedDescription)")
        }
    }

    static func save(_ snapshots: [BatterySnapshot], to url: URL = fileURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder.powerBar.encode(snapshots)
        try data.write(to: url, options: .atomic)
    }
}

enum HistoryStore {
    static let fileURL: URL = {
        SnapshotStore.fileURL.deletingLastPathComponent()
            .appending(path: "history.json", directoryHint: .notDirectory)
    }()

    static func load(
        from url: URL = fileURL,
        now: Date = Date()
    ) -> LocalStoreLoadResult<[BatteryHistorySample]> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .loaded([]) }
        do {
            let data = try Data(contentsOf: url)
            let samples = try JSONDecoder.powerBar.decode([BatteryHistorySample].self, from: data)
            return .loaded(BatteryHistoryPolicy.samplesToKeep(samples, now: now))
        } catch {
            return .unreadable("Couldn’t read history.json: \(error.localizedDescription)")
        }
    }

    static func save(_ samples: [BatteryHistorySample], to url: URL = fileURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder.powerBar.encode(samples)
        try data.write(to: url, options: .atomic)
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
