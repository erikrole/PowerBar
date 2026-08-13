import Foundation
import IOKit
import OSLog
@preconcurrency import UserNotifications

private let cableNotificationLogger = Logger(subsystem: "com.erole.PowerBar", category: "CableNotifications")

final class CableConnectionObserver: @unchecked Sendable {
    private let onChange: @Sendable () -> Void
    private var notificationPort: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private var interestNotifications: [UInt64: io_object_t] = [:]

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        notificationPort = port

        for className in CableDataSource.portClasses {
            registerPortMatches(className: className, port: port)
        }
        for className in CableDataSource.identityClasses + ["IOPortFeaturePowerSource"] {
            registerLifecycle(className: className, notification: kIOMatchedNotification, port: port)
            registerLifecycle(className: className, notification: kIOTerminatedNotification, port: port)
        }
    }

    deinit {
        for iterator in iterators { IOObjectRelease(iterator) }
        for notification in interestNotifications.values { IOObjectRelease(notification) }
        if let notificationPort { IONotificationPortDestroy(notificationPort) }
    }

    private func registerPortMatches(className: String, port: IONotificationPortRef) {
        let callback: IOServiceMatchingCallback = { context, iterator in
            guard let context else { return }
            let observer = Unmanaged<CableConnectionObserver>.fromOpaque(context).takeUnretainedValue()
            observer.drainPorts(iterator, notify: true)
        }
        var iterator: io_iterator_t = 0
        let result = IOServiceAddMatchingNotification(
            port,
            kIOMatchedNotification,
            IOServiceMatching(className),
            callback,
            Unmanaged.passUnretained(self).toOpaque(),
            &iterator
        )
        guard result == KERN_SUCCESS else { return }
        iterators.append(iterator)
        drainPorts(iterator, notify: false)
    }

    private func registerLifecycle(
        className: String,
        notification: UnsafePointer<CChar>,
        port: IONotificationPortRef
    ) {
        let callback: IOServiceMatchingCallback = { context, iterator in
            guard let context else { return }
            let observer = Unmanaged<CableConnectionObserver>.fromOpaque(context).takeUnretainedValue()
            if observer.drain(iterator) {
                observer.onChange()
            }
        }
        var iterator: io_iterator_t = 0
        let result = IOServiceAddMatchingNotification(
            port,
            notification,
            IOServiceMatching(className),
            callback,
            Unmanaged.passUnretained(self).toOpaque(),
            &iterator
        )
        guard result == KERN_SUCCESS else { return }
        iterators.append(iterator)
        _ = drain(iterator)
    }

    @discardableResult
    private func drain(_ iterator: io_iterator_t) -> Bool {
        var foundService = false
        while case let service = IOIteratorNext(iterator), service != 0 {
            foundService = true
            IOObjectRelease(service)
        }
        return foundService
    }

    private func drainPorts(_ iterator: io_iterator_t, notify: Bool) {
        var foundService = false
        while case let service = IOIteratorNext(iterator), service != 0 {
            foundService = true
            registerInterest(for: service)
            IOObjectRelease(service)
        }
        if notify, foundService { onChange() }
    }

    private func registerInterest(for service: io_service_t) {
        guard let notificationPort else { return }
        var entryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS,
              interestNotifications[entryID] == nil else { return }

        let callback: IOServiceInterestCallback = { context, _, _, _ in
            guard let context else { return }
            let observer = Unmanaged<CableConnectionObserver>.fromOpaque(context).takeUnretainedValue()
            observer.onChange()
        }
        var notification: io_object_t = 0
        let result = IOServiceAddInterestNotification(
            notificationPort,
            service,
            kIOGeneralInterest,
            callback,
            Unmanaged.passUnretained(self).toOpaque(),
            &notification
        )
        if result == KERN_SUCCESS {
            interestNotifications[entryID] = notification
        }
    }
}

@MainActor
final class CableNotificationController: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private var notificationState = CableNotificationState()

    override init() {
        super.init()
        center.delegate = self
    }

    func prime(with status: CableStatus) {
        notificationState.prime(with: status)
    }

    func requestAuthorizationIfNeeded(
        completion: @escaping @MainActor @Sendable (CableNotificationAuthorization, String?) -> Void
    ) {
        center.getNotificationSettings { [center] settings in
            let current = CableNotificationAuthorization(settings.authorizationStatus)
            cableNotificationLogger.info("Current authorization: \(current.label, privacy: .public)")
            guard settings.authorizationStatus == .notDetermined else {
                Task { @MainActor in completion(current, nil) }
                return
            }

            center.requestAuthorization(options: [.alert]) { granted, error in
                if let error {
                    cableNotificationLogger.error("Authorization failed: \(error.localizedDescription, privacy: .public)")
                } else {
                    cableNotificationLogger.info("Authorization response granted: \(granted)")
                }
                center.getNotificationSettings { refreshed in
                    let status = CableNotificationAuthorization(refreshed.authorizationStatus)
                    Task { @MainActor in completion(status, error?.localizedDescription) }
                }
            }
        }
    }

    func sendTestNotification(
        completion: @escaping @MainActor @Sendable (String?) -> Void
    ) {
        post(
            title: "PowerBar notifications are working",
            body: "Cable connection alerts will include detected speed and power.",
            completion: completion
        )
    }

    func reconcile(
        with status: CableStatus,
        battery: BatteryReading,
        notificationsEnabled: Bool
    ) {
        let changes = notificationState.changes(for: status)
        if !status.isAvailable {
            cableNotificationLogger.info("Cable discovery unavailable; preserving the last reliable baseline")
            return
        }
        cableNotificationLogger.info(
            "Reconciled cable state: \(status.connectedPorts.count) connected, \(changes.count) change(s), notifications enabled: \(notificationsEnabled)"
        )
        guard notificationsEnabled else { return }

        for change in changes {
            cableNotificationLogger.info("Posting: \(change.title, privacy: .public)")
            post(title: change.title, body: change.notificationBody(battery: battery)) { _ in }
        }
    }

    private func post(
        title: String,
        body: String,
        completion: @escaping @MainActor @Sendable (String?) -> Void
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        center.add(request) { error in
            if let error {
                cableNotificationLogger.error("Delivery failed: \(error.localizedDescription, privacy: .public)")
            } else {
                cableNotificationLogger.info("Notification request accepted")
            }
            Task { @MainActor in completion(error?.localizedDescription) }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner]
    }
}

private extension CableNotificationAuthorization {
    init(_ status: UNAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .denied: self = .denied
        case .authorized, .provisional, .ephemeral: self = .authorized
        @unknown default: self = .unknown
        }
    }
}
