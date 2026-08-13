import Foundation

struct BatteryReading: Codable, Equatable, Sendable {
    var capturedAt = Date()
    var percentage: Int?
    var state = "Unavailable"
    var estimate: String?
    var powerSource = "Unknown"
    var voltageMillivolts: Int?
    var amperageMilliamps: Int?
    var estimatedWatts: Double?
    var cycleCount: Int?
    var temperatureCelsius: Double?
    var maxCapacity: Int?
    var isCharging = false
    var isFullyCharged = false

    static let empty = BatteryReading()

    var isOnExternalPower: Bool {
        powerSource.localizedCaseInsensitiveCompare("AC Power") == .orderedSame
    }

    var powerState: BatteryPowerState {
        guard percentage != nil else { return .unavailable }
        if isFullyCharged, isOnExternalPower { return .full }
        if isCharging { return .charging }
        if isOnExternalPower { return .pluggedIn }
        return .onBattery
    }

    var levelText: String {
        percentage.map { "\($0)%" } ?? "—"
    }

    var menuBarText: String {
        powerState == .full ? "" : levelText
    }

    var statusTitle: String {
        switch powerState {
        case .unavailable: "Unavailable"
        case .full: "Fully Charged"
        case .charging: "Charging"
        case .pluggedIn: "Plugged In"
        case .onBattery: "On Battery"
        }
    }

    var statusDetail: String {
        switch powerState {
        case .unavailable:
            powerSource
        case .full:
            "Plugged in · Battery standing by"
        case .charging:
            [powerSource, formattedEstimate].compactMap { $0 }.joined(separator: " · ")
        case .pluggedIn:
            "External power · Charging paused"
        case .onBattery:
            [powerSource, formattedEstimate].compactMap { $0 }.joined(separator: " · ")
        }
    }

    var symbolName: String {
        if powerState == .pluggedIn { return "powerplug.fill" }
        let suffix = powerState == .charging ? ".bolt" : ""
        guard let percentage else { return "battery.0percent\(suffix)" }
        switch percentage {
        case 90...: return "battery.100percent\(suffix)"
        case 65...: return "battery.75percent\(suffix)"
        case 40...: return "battery.50percent\(suffix)"
        case 15...: return "battery.25percent\(suffix)"
        default: return "battery.0percent\(suffix)"
        }
    }

    var temperatureFahrenheit: Double? {
        temperatureCelsius.map { ($0 * 9 / 5) + 32 }
    }

    var temperatureText: String {
        temperatureFahrenheit.map { String(format: "%.1f °F", $0) } ?? "—"
    }

    var temperaturePresentationText: String {
        switch temperatureStatus {
        case .normal: "\(temperatureText) · Typical"
        case .warning: "\(temperatureText) · Elevated"
        case .alert: "\(temperatureText) · High"
        case .unavailable: temperatureText
        }
    }

    var temperatureStatus: TemperatureStatus {
        guard let temperatureFahrenheit else { return .unavailable }
        switch temperatureFahrenheit {
        case ..<95: return .normal
        case ..<113: return .warning
        default: return .alert
        }
    }

    var wattsText: String {
        guard let estimatedWatts else { return "—" }
        let magnitude = abs(estimatedWatts)
        if magnitude < 0.05 { return "0.0 W" }
        if isCharging || estimatedWatts > 0 {
            return String(format: "+%.1f W", magnitude)
        }
        return String(format: "−%.1f W", magnitude)
    }

    var wattDirection: String {
        guard estimatedWatts != nil else { return "Live estimate unavailable" }
        if isBatteryIdle { return "Battery idle" }
        return isCharging ? "Into battery" : "Battery draw"
    }

    var livePowerExplanation: String {
        if isBatteryIdle {
            switch powerState {
            case .full:
                return "The battery is full. External power is running the Mac while the battery stands by."
            case .pluggedIn:
                return "External power is running the Mac while battery charging is paused."
            default:
                break
            }
        }
        return "Instantaneous battery-flow estimate, not the power adapter’s rated wattage."
    }

    var accessibilitySummary: String {
        let level = percentage.map { "Battery \($0) percent" } ?? "Battery level unavailable"
        return "\(level), \(statusTitle), \(wattsText)"
    }

    private var formattedEstimate: String? {
        guard let estimate else { return nil }
        let components = estimate.split(separator: ":").compactMap { Int($0) }
        guard components.count == 2 else { return estimate }
        guard components[0] > 0 || components[1] > 0 else { return nil }
        let duration = components[0] == 0 ? "\(components[1])m" : "\(components[0])h \(components[1])m"
        return powerState == .charging ? "\(duration) to full" : "\(duration) left"
    }

    private var isBatteryIdle: Bool {
        guard isOnExternalPower, !isCharging, let estimatedWatts else { return false }
        return abs(estimatedWatts) < 0.05
    }
}

enum BatteryPowerState: Equatable, Sendable {
    case unavailable
    case full
    case charging
    case pluggedIn
    case onBattery
}

enum TemperatureStatus: Equatable, Sendable {
    case normal
    case warning
    case alert
    case unavailable
}

struct PowerAssertion: Identifiable, Equatable, Sendable {
    let id: String
    let process: String
    let kind: String
    let reason: String
    let age: String
}

struct PowerConsumer: Identifiable, Equatable, Sendable {
    let name: String
    let powerScore: Double
    let cpuPercentage: Double
    let processCount: Int
    let isApplication: Bool

    var id: String { name }

    var displayName: String {
        Self.friendlyDetails[name]?.name ?? name
    }

    var explanation: String {
        if let details = Self.friendlyDetails[name] {
            return details.explanation
        }
        return isApplication ? "Active application process" : "Background macOS service"
    }

    var symbolName: String {
        if let details = Self.friendlyDetails[name] {
            return details.symbol
        }
        return isApplication ? "app.fill" : "gearshape.fill"
    }

    private static let friendlyDetails: [String: (name: String, explanation: String, symbol: String)] = [
        "searchpartyd": (
            "Find My & device discovery",
            "Supports Find My and nearby-device discovery.",
            "location.fill"
        ),
        "searchpartyuseragent": (
            "Find My & device discovery",
            "Supports Find My and nearby-device discovery.",
            "location.fill"
        ),
        "CoreDeviceService": (
            "Device services",
            "Supports iPhone, iPad, simulator, and developer connections.",
            "iphone.and.arrow.forward"
        ),
        "WindowServer": (
            "Window & display services",
            "Composites windows and keeps connected displays updated.",
            "macwindow.on.rectangle"
        ),
        "kernel_task": (
            "System kernel",
            "Coordinates hardware and helps macOS manage thermal load.",
            "cpu"
        ),
        "coreaudiod": (
            "Audio services",
            "Routes audio and microphone input for apps and the system.",
            "speaker.wave.2.fill"
        ),
        "powerd": (
            "Power management",
            "Coordinates charging, sleep, and energy policy.",
            "bolt.fill"
        ),
        "locationd": (
            "Location services",
            "Provides location updates to apps and system services.",
            "location.fill"
        ),
        "mds": (
            "Spotlight indexing",
            "Builds the index used to find files and content quickly.",
            "magnifyingglass"
        ),
        "mds_stores": (
            "Spotlight indexing",
            "Stores and maintains the index used by Spotlight search.",
            "magnifyingglass"
        ),
        "mdworker": (
            "Spotlight indexing",
            "Reads file metadata while Spotlight updates its search index.",
            "magnifyingglass"
        ),
        "mdworker_shared": (
            "Spotlight indexing",
            "Reads file metadata while Spotlight updates its search index.",
            "magnifyingglass"
        ),
        "photolibraryd": (
            "Photos library",
            "Indexes and synchronizes the Photos library in the background.",
            "photo.on.rectangle"
        ),
        "cloudd": (
            "iCloud sync",
            "Synchronizes iCloud data in the background.",
            "icloud.fill"
        ),
        "bird": (
            "iCloud Drive sync",
            "Synchronizes files and folders stored in iCloud Drive.",
            "icloud.and.arrow.up"
        ),
        "corespeechd": (
            "Speech recognition",
            "Processes dictation and other speech input.",
            "waveform"
        ),
        "bluetoothd": (
            "Bluetooth services",
            "Maintains Bluetooth connections and nearby-device discovery.",
            "dot.radiowaves.left.and.right"
        ),
        "launchservicesd": (
            "App launch services",
            "Keeps track of installed apps and which app opens each document.",
            "arrow.up.forward.app"
        ),
        "runningboardd": (
            "App lifecycle services",
            "Coordinates app launches, suspension, and resource limits.",
            "app.badge"
        ),
        "swcd": (
            "Web credential services",
            "Supports secure credential handoff between apps and websites.",
            "key.fill"
        )
    ]
}

struct PowerEvent: Identifiable, Equatable, Sendable {
    let id: String
    let date: Date?
    let title: String
    let detail: String

    var symbolName: String {
        switch title {
        case "Sleep": "moon.fill"
        case "Wake": "sunrise.fill"
        case "Dark wake": "moon.stars.fill"
        case "Connected to power": "powerplug.fill"
        case "Switched to battery": "battery.75percent"
        case "Charge changed": "arrow.up.arrow.down"
        default: "clock.arrow.circlepath"
        }
    }

    var tintRole: TintRole {
        switch title {
        case "Sleep", "Dark wake": .indigo
        case "Wake": .orange
        case "Connected to power": .green
        case "Switched to battery": .primary
        case "Charge changed": .blue
        default: .secondary
        }
    }

    enum TintRole: Equatable, Sendable {
        case primary
        case secondary
        case blue
        case green
        case indigo
        case orange
    }
}

struct BatterySnapshot: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let reading: BatteryReading

    init(id: UUID = UUID(), reading: BatteryReading) {
        self.id = id
        self.reading = reading
    }
}

struct BatteryHistorySample: Codable, Identifiable, Equatable, Sendable {
    let capturedAt: Date
    let percentage: Int?
    let estimatedWatts: Double?
    let isCharging: Bool

    var id: Date { capturedAt }

    init(reading: BatteryReading) {
        capturedAt = reading.capturedAt
        percentage = reading.percentage
        estimatedWatts = reading.estimatedWatts
        isCharging = reading.isCharging
    }
}

enum HistoryRange: String, CaseIterable, Identifiable, Sendable {
    case oneHour = "1H"
    case sixHours = "6H"
    case twentyFourHours = "24H"

    var id: Self { self }

    var duration: TimeInterval {
        switch self {
        case .oneHour: 60 * 60
        case .sixHours: 6 * 60 * 60
        case .twentyFourHours: 24 * 60 * 60
        }
    }
}

enum BatteryHistoryPolicy {
    static let minimumSampleInterval: TimeInterval = 60
    static let retentionInterval: TimeInterval = 24 * 60 * 60

    static func samplesToKeep(_ samples: [BatteryHistorySample], now: Date) -> [BatteryHistorySample] {
        let cutoff = now.addingTimeInterval(-retentionInterval)
        return samples.filter { $0.capturedAt >= cutoff }.sorted { $0.capturedAt < $1.capturedAt }
    }

    static func filtered(_ samples: [BatteryHistorySample], range: HistoryRange, now: Date) -> [BatteryHistorySample] {
        let cutoff = now.addingTimeInterval(-range.duration)
        return samples.filter { $0.capturedAt >= cutoff }.sorted { $0.capturedAt < $1.capturedAt }
    }
}

struct SnapshotComparison: Equatable, Sendable {
    let percentagePointDelta: Int?
    let wattDelta: Double?
    let elapsed: TimeInterval

    init(older: BatterySnapshot, newer: BatterySnapshot) {
        if let olderPercentage = older.reading.percentage,
           let newerPercentage = newer.reading.percentage {
            percentagePointDelta = newerPercentage - olderPercentage
        } else {
            percentagePointDelta = nil
        }

        if let olderWatts = older.reading.estimatedWatts,
           let newerWatts = newer.reading.estimatedWatts,
           Self.flowDirection(of: olderWatts) != 0,
           Self.flowDirection(of: olderWatts) == Self.flowDirection(of: newerWatts) {
            wattDelta = newerWatts - olderWatts
        } else {
            wattDelta = nil
        }

        elapsed = max(0, newer.reading.capturedAt.timeIntervalSince(older.reading.capturedAt))
    }

    private static func flowDirection(of watts: Double) -> Int {
        if abs(watts) < 0.05 { return 0 }
        return watts > 0 ? 1 : -1
    }
}

struct PowerStatus: Sendable {
    var reading: BatteryReading
    var assertions: [PowerAssertion]
    var events: [PowerEvent]
    var cables: CableStatus
}
