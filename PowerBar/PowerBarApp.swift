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
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let monitor = PowerMonitor()
    private let launchAtLogin = LaunchAtLoginController()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        configurePopover()
        configureStatusItem()
        observeMonitor()
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

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 370, height: 520)
        popover.contentViewController = NSHostingController(
            rootView: PowerBarView(monitor: monitor, launchAtLogin: launchAtLogin)
        )
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

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let reading = monitor.reading
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        button.image = NSImage(
            systemSymbolName: reading.symbolName,
            accessibilityDescription: reading.accessibilitySummary
        )?.withSymbolConfiguration(configuration)
        button.image?.isTemplate = true
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
