import Foundation

enum CableNotificationAuthorization: Equatable, Sendable {
    case unknown
    case notDetermined
    case authorized
    case denied

    var label: String {
        switch self {
        case .unknown: "Checking…"
        case .notDetermined: "Permission needed"
        case .authorized: "Allowed"
        case .denied: "Blocked by macOS"
        }
    }
}

struct CableStatus: Equatable, Sendable {
    var ports: [CablePort] = []
    var adapterWatts: Int?
    var isAvailable = true

    static let empty = CableStatus(isAvailable: false)

    var connectedPorts: [CablePort] {
        ports.filter(\.isConnected)
    }

    var primaryPowerPort: CablePort? {
        connectedPorts.first { $0.negotiatedWatts != nil }
            ?? connectedPorts.first { $0.chargerWatts != nil }
    }
}

enum CableConnectionChange: Equatable, Sendable {
    case connected(CablePort)
    case disconnected(CablePort)

    static func changes(from previous: CableStatus, to current: CableStatus) -> [CableConnectionChange] {
        guard previous.isAvailable, current.isAvailable else { return [] }
        let previousPorts = Dictionary(uniqueKeysWithValues: previous.connectedPorts.map { ($0.id, $0) })
        let currentPorts = Dictionary(uniqueKeysWithValues: current.connectedPorts.map { ($0.id, $0) })

        let connected = currentPorts.values
            .filter { previousPorts[$0.id] == nil }
            .sorted(by: portOrder)
            .map(CableConnectionChange.connected)
        let disconnected = previousPorts.values
            .filter { currentPorts[$0.id] == nil }
            .sorted(by: portOrder)
            .map(CableConnectionChange.disconnected)
        return connected + disconnected
    }

    var title: String {
        switch self {
        case .connected(let port): "\(port.displayName) connected"
        case .disconnected(let port): "\(port.displayName) disconnected"
        }
    }

    func notificationBody(battery: BatteryReading) -> String {
        switch self {
        case .connected(let port):
            return port.connectionSummary(includeNegotiatedPower: true)
        case .disconnected(let port):
            if port.negotiatedWatts != nil || port.chargerWatts != nil,
               !battery.isOnExternalPower {
                return ["Running on battery", battery.percentage.map { "\($0)%" }]
                    .compactMap { $0 }
                    .joined(separator: " · ")
            }
            return port.connectionSummary(includeNegotiatedPower: false)
        }
    }

    private static func portOrder(_ lhs: CablePort, _ rhs: CablePort) -> Bool {
        if lhs.typeCode != rhs.typeCode { return lhs.typeCode < rhs.typeCode }
        return lhs.number < rhs.number
    }
}

struct CableNotificationState: Sendable {
    private var knownStatus: CableStatus?
    private var needsReliableReprime = false

    mutating func prime(with status: CableStatus) {
        guard knownStatus == nil else { return }
        _ = changes(for: status)
    }

    mutating func changes(for status: CableStatus) -> [CableConnectionChange] {
        guard status.isAvailable else {
            needsReliableReprime = true
            return []
        }
        guard let previous = knownStatus, !needsReliableReprime else {
            knownStatus = status
            needsReliableReprime = false
            return []
        }

        knownStatus = status
        return CableConnectionChange.changes(from: previous, to: status)
    }
}

struct CableStatusResolution: Equatable, Sendable {
    let status: CableStatus
    let lastReliableAt: Date?
}

enum CableStatusPolicy {
    static let transientFailureGrace: TimeInterval = 30

    static func resolve(
        incoming: CableStatus,
        previous: CableStatus,
        battery: BatteryReading,
        lastReliableAt: Date?,
        now: Date
    ) -> CableStatusResolution {
        if incoming.isAvailable {
            return CableStatusResolution(status: incoming, lastReliableAt: now)
        }

        guard battery.isOnExternalPower,
              previous.isAvailable,
              let lastReliableAt,
              now.timeIntervalSince(lastReliableAt) <= transientFailureGrace else {
            return CableStatusResolution(status: incoming, lastReliableAt: nil)
        }

        return CableStatusResolution(status: previous, lastReliableAt: lastReliableAt)
    }
}

struct CablePort: Identifiable, Equatable, Sendable {
    let typeCode: Int
    let number: Int
    let typeName: String
    let isConnected: Bool
    let transports: [String]
    let negotiatedWatts: Int?
    let chargerWatts: Int?
    let cableWatts: Int?
    let cableSpeed: CableSpeed?

    var id: String { "\(typeCode)/\(number)" }

    var displayName: String {
        typeName.hasPrefix("MagSafe") ? typeName : "USB-C Port \(number)"
    }

    var symbolName: String {
        if typeName.hasPrefix("MagSafe") { return "powerplug.fill" }
        if transports.contains(where: { $0.localizedCaseInsensitiveContains("DisplayPort") }) {
            return "display"
        }
        if transports.contains(where: { $0.localizedCaseInsensitiveContains("USB4") || $0.localizedCaseInsensitiveContains("CIO") }) {
            return "bolt.horizontal.fill"
        }
        return "cable.connector"
    }

    var transportText: String? {
        let preferred = ["USB4", "CIO", "Thunderbolt", "DisplayPort", "USB3", "USB2"]
        let active = preferred.filter { target in
            transports.contains { $0.localizedCaseInsensitiveContains(target) }
        }
        return active.isEmpty ? nil : active.joined(separator: " + ")
    }

    func connectionSummary(includeNegotiatedPower: Bool) -> String {
        var details: [String] = []
        if let cableSpeed {
            details.append(cableSpeed.label)
        } else if let transportText {
            details.append(transportText)
        }
        if let cableWatts {
            details.append("\(cableWatts) W cable")
        }
        if includeNegotiatedPower, let negotiatedWatts {
            details.append("\(negotiatedWatts) W power available")
        } else if includeNegotiatedPower, let chargerWatts {
            details.append("Charger up to \(chargerWatts) W")
        }
        return details.isEmpty ? "Connection details unavailable" : details.joined(separator: " · ")
    }

    func diagnostic(for battery: BatteryReading) -> CableDiagnostic {
        CableDiagnostic(
            negotiatedWatts: negotiatedWatts,
            chargerWatts: chargerWatts,
            cableWatts: cableWatts,
            hasExternalPower: battery.isOnExternalPower,
            isCharging: battery.isCharging,
            isFullyCharged: battery.isFullyCharged,
            transportText: transportText
        )
    }
}

enum CableSpeed: Int, Equatable, Sendable {
    case usb2 = 0
    case fiveGbps = 1
    case tenGbps = 2
    case fortyGbps = 3
    case eightyGbps = 4

    var label: String {
        switch self {
        case .usb2: "USB 2.0 · 480 Mbps"
        case .fiveGbps: "USB 3 · 5 Gbps"
        case .tenGbps: "USB 3 · 10 Gbps"
        case .fortyGbps: "USB4 · 40 Gbps"
        case .eightyGbps: "USB4 · 80 Gbps"
        }
    }
}

struct CableDiagnostic: Equatable, Sendable {
    enum Severity: Equatable, Sendable {
        case normal
        case informational
        case warning
    }

    let title: String
    let detail: String
    let severity: Severity

    init(
        negotiatedWatts: Int?,
        chargerWatts: Int?,
        cableWatts: Int?,
        hasExternalPower: Bool,
        isCharging: Bool,
        isFullyCharged: Bool,
        transportText: String?
    ) {
        if !hasExternalPower {
            if let transportText {
                title = "Connected via \(transportText)"
            } else {
                title = "Connected"
            }
            detail = "No charging contract is active on this port."
            severity = .normal
        } else if let cableWatts, let chargerWatts, cableWatts < chargerWatts {
            title = "Cable is limiting charging speed"
            detail = "The charger supports \(chargerWatts) W, but this cable is rated for \(cableWatts) W."
            severity = .warning
        } else if isFullyCharged, negotiatedWatts != nil || chargerWatts != nil {
            title = "Fully charged"
            detail = "Plugged in and running on external power. Charging will resume when needed."
            severity = .normal
        } else if !isCharging, negotiatedWatts != nil {
            title = "Charging paused"
            detail = "Plugged in. macOS has paused battery charging for now."
            severity = .informational
        } else if let negotiatedWatts {
            if let chargerWatts,
               negotiatedWatts < chargerWatts - max(5, chargerWatts / 10) {
                title = "Charging at \(negotiatedWatts) W"
                detail = "The charger supports up to \(chargerWatts) W; the Mac is currently asking for less."
                severity = .informational
            } else {
                title = "Power connected · up to \(negotiatedWatts) W"
                detail = "The charger and cable are well matched."
                severity = .normal
            }
        } else if let chargerWatts {
            title = "Charger available · up to \(chargerWatts) W"
            detail = "Per-port negotiation details are not available yet."
            severity = .informational
        } else if let transportText {
            title = "Connected via \(transportText)"
            detail = "No charging contract is active on this port."
            severity = .normal
        } else {
            title = "Connected"
            detail = "Cable capabilities are not exposed by this connection."
            severity = .informational
        }
    }
}
