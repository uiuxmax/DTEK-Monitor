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

@MainActor final class MonitorAppDelegate: NSObject,NSApplicationDelegate,NSWindowDelegate,NSPopoverDelegate,ObservableObject {
    @Published private var model: MonitorModel?
    @Published private var login: LoginItemModel?
    private var window: NSWindow?
    private var settingsWindow: NSWindow?
    private var floating: NSPanel?
    private var item: NSStatusItem?
    private let popover=NSPopover()
    private var activationObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var stateObserver: AnyCancellable?
    private var presentationObserver: NSKeyValueObservation?
    private var workspaceObservers: [NSObjectProtocol]=[]
    private var contextMonitor: Any?
    private var floatingMoveTask: Task<Void,Never>?
    private var restoredFloating=false
    private var floatingSize=1
    private var floatingWanted=false
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
            button.target=self; button.action=#selector(statusClicked)
            button.sendAction(on:[.leftMouseUp,.rightMouseUp])
        }
        item=status; popover.behavior = .transient; popover.animates=false; popover.delegate=self
        activationObserver=NotificationCenter.default.addObserver(forName:NSApplication.didBecomeActiveNotification,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor in self?.login?.refresh() }
        }
        screenObserver=NotificationCenter.default.addObserver(forName:NSApplication.didChangeScreenParametersNotification,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor in self?.repositionFloatingIfNeeded() }
        }
        stateObserver=model?.$state.sink { [weak self] state in
            guard let self=self, let state=state else { return }
            if !self.restoredFloating {
                self.restoredFloating=true; self.floatingSize=state.floatingSize
                if state.floatingVisible { self.showFloating(restoring:true,initialState:state) }
            }
            // @Published emits before model.state changes. Apply the supplied snapshot.
            self.applyFloatingBehavior(state)
        }
        presentationObserver=NSApplication.shared.observe(\.currentSystemPresentationOptions,options:[.new]) { [weak self] _,_ in
            Task { @MainActor in self?.applyFloatingBehavior() }
        }
        for name in [NSWorkspace.activeSpaceDidChangeNotification,NSWorkspace.didActivateApplicationNotification,NSWorkspace.didWakeNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in
                Task { @MainActor in self?.applyFloatingBehavior() }
            })
        }
        contextMonitor=NSEvent.addLocalMonitorForEvents(matching:.rightMouseUp) { [weak self] event in
            guard let self=self,let panel=self.floating,event.window === panel,let view=panel.contentView else { return event }
            NSMenu.popUpContextMenu(self.makeMenu(),with:event,for:view); return nil
        }
        showSchedule()
    }
    private var panelHeight: CGFloat { max(300,min(680,(NSScreen.main?.visibleFrame.height ?? 800)-80)) }
    private func content(close: @escaping () -> Void) -> MonitorView? {
        guard let model=model,let login=login else { return nil }
        return MonitorView(model:model,login:login,showSchedule:{ [weak self] in self?.showSchedule() },
            showFloating:{ [weak self] in self?.showFloating() },showSettings:{ [weak self] in self?.showSettings() },closeWindow:close)
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
        let state=model?.state
        let point=floating?.frame.origin ?? NSPoint(x:CGFloat(state?.floatingX ?? 0),y:CGFloat(state?.floatingY ?? 0))
        guard point.x.isFinite, point.y.isFinite, abs(point.x)<=100000, abs(point.y)<=100000 else { return }
        model?.setFloating(visible:visible,positioned:floating != nil || state?.floatingPositioned == true,x:Int(point.x.rounded()),y:Int(point.y.rounded()),size:floatingSize)
    }
    private func repositionFloatingIfNeeded() {
        guard let panel=floating, let origin=safeOrigin(panel.frame.origin,size:panel.frame.size), origin != panel.frame.origin else { return }
        panel.setFrameOrigin(origin); persistFloating(visible:floatingWanted)
    }
    private func setFloatingSize(_ size: Int) {
        guard (0...2).contains(size) else { return }
        floatingSize=size
        guard let panel=floating else { persistFloating(visible:floatingWanted); return }
        let dimensions=dimensions(size)
        let old=panel.frame
        let desired=NSPoint(x:old.minX,y:old.maxY-dimensions.height)
        let origin=safeOrigin(desired,size:dimensions) ?? desired
        panel.setFrame(NSRect(origin:origin,size:dimensions),display:true)
        persistFloating(visible:floatingWanted)
    }
    private func hideFloating() { floatingWanted=false; floatingMoveTask?.cancel(); floating?.orderOut(nil); persistFloating(visible:false) }
    private func showFloating(restoring: Bool = false, initialState: MonitorSnapshot? = nil) {
        guard let model=model else { return }
        floatingWanted=true
        if floating == nil {
            let panel=FloatingPanel(contentRect:NSRect(origin:.zero,size:dimensions(floatingSize)),
                styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
            panel.title="DTEK Monitor"; panel.identifier=NSUserInterfaceItemIdentifier("floating-monitor")
            panel.isReleasedWhenClosed=false; panel.isRestorable=false; panel.level = .floating
            panel.hidesOnDeactivate=false
            panel.isOpaque=false; panel.backgroundColor = .clear; panel.hasShadow=true
            panel.isMovableByWindowBackground=true
            panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
            panel.contentView=NSHostingView(rootView:FloatingMonitorView(model:model,
                showSchedule:{ [weak self] in self?.showSchedule() },close:{ [weak self] in self?.hideFloating() },
                showMenu:{ [weak self] in self?.showFloatingMenu() }))
            panel.center()
            if let state=initialState ?? model.state, state.floatingPositioned,
               let origin=safeOrigin(NSPoint(x:CGFloat(state.floatingX),y:CGFloat(state.floatingY)),size:panel.frame.size) { panel.setFrameOrigin(origin) }
            floating=panel; panel.delegate=self
        }
        applyFloatingBehavior(initialState)
        repositionFloatingIfNeeded()
        if !restoring { persistFloating(visible:true) }
    }
    private func applyFloatingBehavior(_ supplied: MonitorSnapshot? = nil) {
        guard let panel=floating else { return }
        let state=supplied ?? model?.state
        panel.isMovableByWindowBackground=state?.floatingLocked != true
        panel.isMovable=state?.floatingLocked != true
        panel.level=state?.floatingTopmost == false ? .normal : .floating
        let suppressed=state?.floatingHideFullscreen == true && NSApplication.shared.currentSystemPresentationOptions.contains(.fullScreen)
        if !floatingWanted || suppressed { if panel.isVisible { panel.orderOut(nil) } }
        else if !panel.isVisible { repositionFloatingIfNeeded(); panel.orderFront(nil) }
    }
    private func resetFloatingPosition() {
        if floating == nil { showFloating() }
        guard let panel=floating else { return }
        panel.center()
        if let point=safeOrigin(panel.frame.origin,size:panel.frame.size) { panel.setFrameOrigin(point) }
        persistFloating(visible:floatingWanted)
    }
    @ViewBuilder var settingsContent: some View {
        if let model=model,let login=login {
            MonitorSettingsView(model:model,login:login,setSize:{ [weak self] in self?.setFloatingSize($0) },
                resetPosition:{ [weak self] in self?.resetFloatingPosition() })
        } else { ProgressView("Завантаження…").padding(24) }
    }
    func showSettings() {
        if popover.isShown { popover.performClose(nil) }
        login?.refresh()
        if settingsWindow == nil {
            let value=NSWindow(contentRect:NSRect(x:0,y:0,width:420,height:530),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            value.title="Налаштування DTEK Monitor"; value.identifier=NSUserInterfaceItemIdentifier("monitor-settings-window")
            value.isReleasedWhenClosed=false; value.isRestorable=false; value.center(); settingsWindow=value
        }
        settingsWindow?.contentView=NSHostingView(rootView:settingsContent)
        settingsWindow?.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps:true)
    }
    private func makeMenu() -> NSMenu {
        login?.refresh()
        let menu=NSMenu(); menu.autoenablesItems=false
        func add(_ title: String,_ action: String,_ checked: Bool? = nil,to parent: NSMenu? = nil) {
            let item=NSMenuItem(title:title,action:#selector(menuAction(_:)),keyEquivalent:"")
            item.target=self; item.representedObject=action
            if let checked=checked { item.state=checked ? .on : .off }
            (parent ?? menu).addItem(item)
        }
        add("Відкрити графік","schedule")
        add(floatingWanted ? "Приховати віджет" : "Показати віджет","visibility")
        add("Налаштування…","settings")
        menu.addItem(.separator())
        for (title,values) in [("Розмір віджета",["Компактний","Звичайний","Великий"]),("Тема",MonitorTheme.allCases.map(\.title))] {
            let parent=NSMenuItem(title:title,action:nil,keyEquivalent:""); let child=NSMenu(); child.autoenablesItems=false
            for (index,value) in values.enumerated() {
                let size=title == "Розмір віджета"
                add(value,size ? "size-\(index)" : "theme-\(MonitorTheme.allCases[index].rawValue)",
                    size ? floatingSize==index : model?.theme == MonitorTheme.allCases[index],to:child)
            }
            parent.submenu=child; menu.addItem(parent)
        }
        add("Закріпити позицію","locked",model?.state?.floatingLocked == true)
        add("Поверх інших вікон","topmost",model?.state?.floatingTopmost != false)
        add("Ховати у повноекранному режимі","hideFullscreen",model?.state?.floatingHideFullscreen == true)
        add("Скинути позицію віджета","reset")
        menu.addItem(.separator())
        add("Запускати після входу","login",login?.checked == true)
        menu.items.last?.isEnabled=login?.canChange == true
        let status=NSMenuItem(title:login?.statusText ?? "",action:nil,keyEquivalent:""); status.isEnabled=false; menu.addItem(status)
        add("Параметри входу macOS…","login-settings")
        menu.addItem(.separator())
        add("Про DTEK Monitor","about"); add("Вийти","quit")
        return menu
    }
    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let action=sender.representedObject as? String else { return }
        switch action {
        case "schedule":showSchedule()
        case "settings":showSettings()
        case "visibility":if floatingWanted { hideFloating() } else { showFloating() }
        case "reset":resetFloatingPosition()
        case "login":login?.requestEnabled(login?.checked != true)
        case "login-settings":login?.openSettings()
        case "about":NSApplication.shared.orderFrontStandardAboutPanel(nil)
        case "quit":NSApplication.shared.terminate(nil)
        default:
            if action.hasPrefix("size-"),let size=Int(action.dropFirst(5)) { setFloatingSize(size) }
            else if action.hasPrefix("theme-"),let theme=MonitorTheme(rawValue:String(action.dropFirst(6))) { model?.setTheme(theme) }
            else if let option=MonitorFloatingOption(rawValue:action) {
                let state=model?.state
                let value=option == .locked ? state?.floatingLocked == true : option == .topmost ? state?.floatingTopmost != false : state?.floatingHideFullscreen == true
                model?.setFloatingOption(option,enabled:!value)
            }
        }
    }
    private func showFloatingMenu() {
        guard let panel=floating,let view=panel.contentView else { return }
        makeMenu().popUp(positioning:nil,at:NSPoint(x:view.bounds.maxX-36,y:8),in:view)
    }
    @objc private func statusClicked() {
        if let event=NSApplication.shared.currentEvent,event.type == .rightMouseUp || event.modifierFlags.contains(.control),let button=item?.button {
            if popover.isShown { popover.performClose(nil) }
            NSMenu.popUpContextMenu(makeMenu(),with:event,for:button)
        } else { togglePopover() }
    }
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? { makeMenu() }
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
            guard let self=self else { return }; self.persistFloating(visible:self.floatingWanted)
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
        presentationObserver=nil
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }; workspaceObservers=[]
        if let monitor=contextMonitor { NSEvent.removeMonitor(monitor); contextMonitor=nil }
        floatingMoveTask?.cancel(); if floating != nil { persistFloating(visible:floatingWanted) }
        Task { await model.stop(); sender.reply(toApplicationShouldTerminate:true) }
        return .terminateLater
    }
}

@main @MainActor struct MonitorApp: App {
    @NSApplicationDelegateAdaptor(MonitorAppDelegate.self) private var delegate
    init() {
        #if DTEKMONITOR_MAC_TEST_BUILD
        guard TestEnvelope.isValid(ProcessInfo.processInfo.environment) else { exit(64) }
        #endif
    }
    var body: some Scene {
        Settings { delegate.settingsContent }
            .commands {
                CommandGroup(replacing:.appSettings) {
                    Button("Налаштування…") { delegate.showSettings() }.keyboardShortcut(",",modifiers:.command)
                }
            }
    }
}
