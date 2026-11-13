import SwiftUI
import AppKit
import Darwin
import Combine

#if !os(macOS) || !arch(arm64)
#error("DTEK Monitor supports native Apple Silicon only")
#endif

private final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor final class MonitorAppDelegate: NSObject,NSApplicationDelegate,NSWindowDelegate,NSPopoverDelegate {
    private var model: MonitorModel?
    private var login: LoginItemModel?
    private var window: NSWindow?
    private var floating: NSPanel?
    private var item: NSStatusItem?
    private let popover=NSPopover()
    private var activationObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var stateObserver: AnyCancellable?
    private var floatingMoveTask: Task<Void,Never>?
    private var restoredFloating=false
    private var floatingSize=1
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
        item=status; popover.behavior = .transient; popover.animates=false; popover.delegate=self
        activationObserver=NotificationCenter.default.addObserver(forName:NSApplication.didBecomeActiveNotification,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor in self?.login?.refresh() }
        }
        screenObserver=NotificationCenter.default.addObserver(forName:NSApplication.didChangeScreenParametersNotification,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor in self?.repositionFloatingIfNeeded() }
        }
        stateObserver=model?.$state.sink { [weak self] state in
            guard let self=self, let state=state, !self.restoredFloating else { return }
            self.restoredFloating=true; self.floatingSize=state.floatingSize
            if state.floatingVisible { self.showFloating(restoring:true,initialState:state) }
        }
        showSchedule()
    }
    private var panelHeight: CGFloat { max(300,min(680,(NSScreen.main?.visibleFrame.height ?? 800)-80)) }
    private func content(close: @escaping () -> Void) -> MonitorView? {
        guard let model=model,let login=login else { return nil }
        return MonitorView(model:model,login:login,showSchedule:{ [weak self] in self?.showSchedule() },
            showFloating:{ [weak self] in self?.showFloating() },closeWindow:close)
    }
    private func dimensions(_ size: Int) -> NSSize {
        switch size { case 0:return NSSize(width:250,height:68); case 2:return NSSize(width:350,height:96); default:return NSSize(width:290,height:76) }
    }
    private func safeOrigin(_ origin: NSPoint, size: NSSize) -> NSPoint? {
        let rect=NSRect(origin:origin,size:size)
        let screens=NSScreen.screens
        let screen=screens.max { a,b in
            let x=a.visibleFrame.intersection(rect), y=b.visibleFrame.intersection(rect)
            let ax=x.isNull ? 0 : x.width*x.height, ay=y.isNull ? 0 : y.width*y.height
            return ax < ay
        }.flatMap { $0.visibleFrame.intersects(rect) ? $0 : nil } ?? NSScreen.main ?? screens.first
        guard let bounds=screen?.visibleFrame else { return nil }
        return NSPoint(x:max(bounds.minX,min(origin.x,bounds.maxX-size.width)),
                       y:max(bounds.minY,min(origin.y,bounds.maxY-size.height)))
    }
    private func persistFloating(visible: Bool) {
        guard let panel=floating else { return }
        let point=panel.frame.origin
        guard point.x.isFinite, point.y.isFinite, abs(point.x)<=100000, abs(point.y)<=100000 else { return }
        model?.setFloating(visible:visible,positioned:true,x:Int(point.x.rounded()),y:Int(point.y.rounded()),size:floatingSize)
    }
    private func repositionFloatingIfNeeded() {
        guard let panel=floating, panel.isVisible, let origin=safeOrigin(panel.frame.origin,size:panel.frame.size), origin != panel.frame.origin else { return }
        panel.setFrameOrigin(origin); persistFloating(visible:true)
    }
    private func setFloatingSize(_ size: Int) {
        guard (0...2).contains(size), let panel=floating else { return }
        floatingSize=size
        let dimensions=dimensions(size)
        let old=panel.frame
        let desired=NSPoint(x:old.minX,y:old.maxY-dimensions.height)
        let origin=safeOrigin(desired,size:dimensions) ?? desired
        panel.setFrame(NSRect(origin:origin,size:dimensions),display:true)
        persistFloating(visible:true)
    }
    private func hideFloating() { floatingMoveTask?.cancel(); floating?.orderOut(nil); persistFloating(visible:false) }
    private func showFloating(restoring: Bool = false, initialState: MonitorSnapshot? = nil) {
        guard let model=model else { return }
        if floating == nil {
            let panel=FloatingPanel(contentRect:NSRect(origin:.zero,size:dimensions(floatingSize)),
                styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
            panel.title="DTEK Monitor"; panel.identifier=NSUserInterfaceItemIdentifier("floating-monitor")
            panel.isReleasedWhenClosed=false; panel.isRestorable=false; panel.level = .floating
            panel.isOpaque=false; panel.backgroundColor = .clear; panel.hasShadow=true
            panel.isMovableByWindowBackground=true
            panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
            panel.contentView=NSHostingView(rootView:FloatingMonitorView(model:model,
                showSchedule:{ [weak self] in self?.showSchedule() },close:{ [weak self] in self?.hideFloating() },
                setSize:{ [weak self] in self?.setFloatingSize($0) }))
            panel.center()
            if let state=initialState ?? model.state, state.floatingPositioned,
               let origin=safeOrigin(NSPoint(x:CGFloat(state.floatingX),y:CGFloat(state.floatingY)),size:panel.frame.size) { panel.setFrameOrigin(origin) }
            floating=panel; panel.delegate=self
        }
        floating?.orderFrontRegardless()
        repositionFloatingIfNeeded()
        if !restoring { persistFloating(visible:true) }
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
    func windowWillClose(_ notification: Notification) {
        if let value=notification.object as? NSWindow, value === window { model?.cancelEditing() }
    }
    func popoverDidClose(_ notification: Notification) {
        if window?.isVisible != true { model?.cancelEditing() }
    }
    func windowDidMove(_ notification: Notification) {
        guard let value=notification.object as? NSWindow, value === floating, value.isVisible else { return }
        floatingMoveTask?.cancel()
        floatingMoveTask=Task { [weak self] in
            do { try await Task.sleep(for:.milliseconds(300)) } catch { return }
            self?.persistFloating(visible:true)
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication,hasVisibleWindows flag: Bool) -> Bool { showSchedule(); return false }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !quitting,let model=model else { return .terminateNow }
        quitting=true
        if let observer=activationObserver { NotificationCenter.default.removeObserver(observer); activationObserver=nil }
        if let observer=screenObserver { NotificationCenter.default.removeObserver(observer); screenObserver=nil }
        stateObserver=nil
        floatingMoveTask?.cancel(); if floating?.isVisible == true { persistFloating(visible:true) }
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
