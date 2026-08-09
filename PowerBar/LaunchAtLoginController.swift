import Foundation
import Observation
import ServiceManagement

@MainActor
@Observable
final class LaunchAtLoginController {
    private(set) var status: SMAppService.Status
    private(set) var errorMessage: String?

    private let service = SMAppService.mainApp

    init() {
        status = service.status
        guard !Self.isRunningTests else { return }
        enable()
    }

    var isEnabled: Bool {
        status == .enabled
    }

    var requiresApproval: Bool {
        status == .requiresApproval
    }

    var statusText: String {
        switch status {
        case .enabled: "On"
        case .requiresApproval: "Needs approval"
        case .notRegistered: "Off"
        case .notFound: "Unavailable"
        @unknown default: "Unknown"
        }
    }

    func setEnabled(_ enabled: Bool) {
        enabled ? enable() : disable()
    }

    func refresh() {
        status = service.status
    }

    func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func enable() {
        refresh()
        if status == .enabled {
            errorMessage = nil
            return
        }
        if status == .requiresApproval {
            errorMessage = "PowerBar needs approval in Login Items."
            return
        }
        do {
            try service.register()
            refresh()
            errorMessage = status == .enabled ? nil : "PowerBar needs approval in Login Items."
        } catch {
            refresh()
            errorMessage = error.localizedDescription
        }
    }

    private func disable() {
        refresh()
        guard status != .notRegistered else { return }
        do {
            try service.unregister()
            refresh()
            errorMessage = nil
        } catch {
            refresh()
            errorMessage = error.localizedDescription
        }
    }

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}
