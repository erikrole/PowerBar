import AppKit
import SwiftUI

@main
struct PowerBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let monitor = PowerMonitor()
    private let launchAtLogin = LaunchAtLoginController()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var outsideClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              NSClassFromString("XCTestCase") == nil else { return }
        configurePopover()
        configureStatusItem()
        configureOutsideClickMonitor()
        observeMonitor()
        monitor.startCableNotifications()
        AppUpdate.checkOnLaunch()
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else { return }

        button.target = self
        button.action = #selector(togglePopover(_:))
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        button.alignment = .center
        button.toolTip = "PowerBar"
        statusItem = item
        updateStatusItem()
    }

    private func configureOutsideClickMonitor() {
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.popover.isShown else { return }
                self.popover.performClose(nil)
            }
        }
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentSize = NSSize(width: 370, height: 520)
        popover.contentViewController = NSHostingController(
            rootView: PowerBarView(monitor: monitor, launchAtLogin: launchAtLogin)
        )
    }

    func popoverDidShow(_ notification: Notification) {
        monitor.setPopoverVisible(true)
    }

    func popoverDidClose(_ notification: Notification) {
        monitor.setPopoverVisible(false)
    }

    private func observeMonitor() {
        withObservationTracking {
            _ = monitor.reading.symbolName
            _ = monitor.reading.menuBarText
            _ = monitor.reading.accessibilitySummary
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.updateStatusItem()
                self.observeMonitor()
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppUpdate.isPreparing ? .terminateCancel : .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let reading = monitor.reading
        var configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        if reading.powerState == .full {
            configuration = configuration.applying(
                NSImage.SymbolConfiguration(hierarchicalColor: .systemGreen)
            )
        }
        let image = NSImage(
            systemSymbolName: reading.symbolName,
            accessibilityDescription: reading.accessibilitySummary
        )?.withSymbolConfiguration(configuration)
        image?.isTemplate = reading.powerState != .full
        button.image = image
        button.imagePosition = reading.powerState == .full ? .imageOnly : .imageLeading
        button.title = reading.menuBarText
        button.toolTip = reading.accessibilitySummary
        button.setAccessibilityLabel(reading.accessibilitySummary)
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.becomeKey()
        }
    }
}
