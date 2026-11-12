import SwiftUI
import AppKit
import Darwin

#if !DTEKMONITOR_MAC_TEST_BUILD || !os(macOS) || !arch(arm64)
#error("The fixture app requires the protected native Apple Silicon configuration.")
#endif

final class FixtureAppDelegate: NSObject, NSApplicationDelegate {
    let model = FixtureModel()
    private var scheduleWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) { showSchedule() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSchedule()
        return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { false }

    func showSchedule() {
        if scheduleWindow == nil {
            let availableHeight = (NSScreen.main?.visibleFrame.height ?? 800) - 80
            let height = max(300, min(640, availableHeight))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: height),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "DTEK Monitor — ТЕСТОВІ ДАНІ"
            window.identifier = NSUserInterfaceItemIdentifier("fixture-window")
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.collectionBehavior = [.fullScreenAuxiliary]
            window.contentView = NSHostingView(rootView: WidgetView(model: model, showSchedule: { [weak self] in
                self?.showSchedule()
            }))
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
        MenuBarExtra {
            WidgetView(model: delegate.model, showSchedule: { delegate.showSchedule() })
                .frame(height: min(640, max(300, (NSScreen.main?.visibleFrame.height ?? 800) - 80)))
        } label: {
            Label("ТЕСТ · DTEK", systemImage: "bolt.circle")
                .accessibilityIdentifier("fixture-menubar")
                .accessibilityLabel("ТЕСТ · DTEK")
        }
        .menuBarExtraStyle(.window)
    }
}
