import SwiftUI
import AppKit
import Darwin

#if !os(macOS) || !arch(arm64)
#error("DTEK Monitor supports native Apple Silicon only")
#endif

@MainActor final class MonitorAppDelegate: NSObject,NSApplicationDelegate,NSWindowDelegate {
    private var model: MonitorModel?
    private var login: LoginItemModel?
    private var window: NSWindow?
    private var floating: NSPanel?
    private var item: NSStatusItem?
    private let popover=NSPopover()
    private var activationObserver: NSObjectProtocol?
    private var quitting=false

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            // The App init guard runs before any profile/backend is created.
            let profile=try MonitorProfile.open()
            #if DTEKMONITOR_MAC_TEST_BUILD
            let scenario=ProcessInfo.processInfo.environment["DTEKMONITOR_TEST_SCENARIO"] ?? "tomorrow"
            guard ["ready","tomorrow","emergency","unavailable","429"].contains(scenario) else { exit(64) }
            model=MonitorModel(profile:profile,clock:MonitorClock(),mode:.synthetic(scenario))
            login=LoginItemModel(backend:FakeLoginItemBackend())
            #else
            model=MonitorModel(profile:profile,clock:MonitorClock(),mode:.native)
            login=LoginItemModel(backend:NativeLoginItemBackend())
            #endif
        } catch {
            let alert=NSAlert(); alert.messageText="Не вдалося відкрити папку даних"
            alert.informativeText="Перевірте доступ до Application Support і запустіть програму ще раз."
            alert.runModal(); NSApplication.shared.terminate(nil); return
        }
        let status=NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)
        if let button=status.button {
            button.image=NSImage(systemSymbolName:"bolt.circle",accessibilityDescription:"DTEK Monitor")
            button.image?.isTemplate=true; button.toolTip="DTEK Monitor"
            button.setAccessibilityIdentifier("monitor-menubar"); button.setAccessibilityLabel("DTEK Monitor")
            button.target=self; button.action=#selector(togglePopover)
        }
        item=status; popover.behavior = .transient; popover.animates=false
        activationObserver=NotificationCenter.default.addObserver(forName:NSApplication.didBecomeActiveNotification,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor in self?.login?.refresh() }
        }
        showSchedule()
    }
    private var panelHeight: CGFloat { max(300,min(680,(NSScreen.main?.visibleFrame.height ?? 800)-80)) }
    private func content(close: @escaping () -> Void) -> MonitorView? {
        guard let model=model,let login=login else { return nil }
        return MonitorView(model:model,login:login,showSchedule:{ [weak self] in self?.showSchedule() },
            showFloating:{ [weak self] in self?.showFloating() },closeWindow:close)
    }
    private func showFloating() {
        guard let model=model else { return }
        if floating == nil {
            let panel=NSPanel(contentRect:NSRect(x:0,y:0,width:280,height:165),
                styleMask:[.titled,.closable,.utilityWindow,.nonactivatingPanel],backing:.buffered,defer:false)
            panel.title="DTEK Monitor"; panel.identifier=NSUserInterfaceItemIdentifier("floating-monitor")
            panel.isReleasedWhenClosed=false; panel.isRestorable=false; panel.level = .floating
            panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
            panel.contentView=NSHostingView(rootView:FloatingMonitorView(model:model,showSchedule:{ [weak self] in self?.showSchedule() }))
            panel.center(); floating=panel
        }
        floating?.orderFrontRegardless()
    }
    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil); model?.cancelEditing(); return }
        guard let button=item?.button,let view=content(close:{ [weak self] in self?.popover.performClose(nil); self?.model?.cancelEditing() }) else { return }
        window?.orderOut(nil); model?.cancelEditing(); model?.popupOpened(); login?.refresh()
        let controller=NSHostingController(rootView:view)
        controller.view.frame=NSRect(x:0,y:0,width:380,height:panelHeight)
        popover.contentViewController=controller; popover.contentSize=NSSize(width:380,height:panelHeight)
        popover.show(relativeTo:button.bounds,of:button,preferredEdge:.minY)
        popover.contentViewController?.view.window?.makeKey(); NSApplication.shared.activate(ignoringOtherApps:true)
    }
    func showSchedule() {
        guard let view=content(close:{ [weak self] in self?.window?.close() }) else { return }
        if popover.isShown { popover.performClose(nil) }
        model?.cancelEditing(); model?.popupOpened(); login?.refresh()
        if window==nil {
            let value=NSWindow(contentRect:NSRect(x:0,y:0,width:380,height:panelHeight),
                styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
            value.title="DTEK Monitor"; value.identifier=NSUserInterfaceItemIdentifier("monitor-window")
            value.isReleasedWhenClosed=false; value.isRestorable=false; value.collectionBehavior=[.fullScreenAuxiliary]
            value.delegate=self; value.center(); window=value
        }
        window?.contentView=NSHostingView(rootView:view)
        window?.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps:true)
    }
    func windowWillClose(_ notification: Notification) { model?.cancelEditing() }
    func applicationShouldHandleReopen(_ sender: NSApplication,hasVisibleWindows flag: Bool) -> Bool { showSchedule(); return false }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !quitting,let model=model else { return .terminateNow }
        quitting=true
        if let observer=activationObserver { NotificationCenter.default.removeObserver(observer); activationObserver=nil }
        Task { await model.stop(); sender.reply(toApplicationShouldTerminate:true) }
        return .terminateLater
    }
}

@main struct MonitorApp: App {
    @NSApplicationDelegateAdaptor(MonitorAppDelegate.self) private var delegate
    init() {
        #if DTEKMONITOR_MAC_TEST_BUILD
        guard TestEnvelope.isValid(ProcessInfo.processInfo.environment) else { exit(64) }
        #endif
    }
    var body: some Scene { Settings { EmptyView() } }
}
