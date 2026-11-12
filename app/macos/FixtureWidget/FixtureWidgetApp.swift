import SwiftUI
import AppKit
import Darwin

#if !DTEKMONITOR_MAC_TEST_BUILD || !os(macOS) || !arch(arm64)
#error("The fixture app requires the protected native Apple Silicon configuration.")
#endif

final class FixtureAppDelegate: NSObject, NSApplicationDelegate {
    let model = FixtureModel()
    private var scheduleWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "bolt.circle", accessibilityDescription: "ТЕСТ · DTEK")
            button.image?.isTemplate = true
            button.toolTip = "DTEK Monitor — ТЕСТОВІ ДАНІ"
            button.setAccessibilityIdentifier("fixture-menubar")
            button.setAccessibilityLabel("ТЕСТ · DTEK")
            button.target = self
            button.action = #selector(togglePopover)
        }
        statusItem = item
        popover.behavior = .transient
        popover.animates = false
        let controller = NSHostingController(rootView: WidgetView(model: model, showSchedule: { [weak self] in
            self?.showSchedule()
        }, closeWindow: { [weak self] in self?.popover.performClose(nil) }))
        controller.view.frame = NSRect(x: 0, y: 0, width: 380, height: panelHeight)
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: 380, height: panelHeight)
        showSchedule()
    }

    private var panelHeight: CGFloat {
        max(300, min(640, (NSScreen.main?.visibleFrame.height ?? 800) - 80))
    }

    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil); return }
        guard let button = statusItem?.button else { return }
        popover.contentSize = NSSize(width: 380, height: panelHeight)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSchedule()
        return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { false }

    func showSchedule() {
        if popover.isShown { popover.performClose(nil) }
        if scheduleWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: panelHeight),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "DTEK Monitor — ТЕСТОВІ ДАНІ"
            window.identifier = NSUserInterfaceItemIdentifier("fixture-window")
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.collectionBehavior = [.fullScreenAuxiliary]
            window.contentView = NSHostingView(rootView: WidgetView(model: model, showSchedule: { [weak self] in
                self?.showSchedule()
            }, closeWindow: { [weak self] in self?.scheduleWindow?.close() }))
            window.center()
            scheduleWindow = window
        }
        scheduleWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

@main
struct FixtureWidgetApp: App {
    @NSApplicationDelegateAdaptor(FixtureAppDelegate.self) private var delegate

    init() {
        guard TestEnvelope.isValid(ProcessInfo.processInfo.environment) else { exit(64) }
    }

    var body: some Scene {
        // M2 fallback after verified MenuBarExtra Escape/reopen failures.
        // AppKit owns status/popover lifecycle; SwiftUI still owns its content.
        Settings { EmptyView() }
    }
}
