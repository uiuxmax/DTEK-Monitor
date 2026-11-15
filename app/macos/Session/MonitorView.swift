import SwiftUI
import AppKit

// Explicit opaque colours keep wallpaper tint and popover vibrancy out of the
// content. Resolve inside preferredColorScheme so the fill and text agree.
private struct MonitorSurface: View {
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        colorScheme == .dark
            ? Color(.sRGB,red:36/255,green:40/255,blue:48/255,opacity:1)
            : Color(.sRGB,red:250/255,green:251/255,blue:253/255,opacity:1)
    }
}

@MainActor struct MonitorView: View {
    @ObservedObject var model: MonitorModel
    @ObservedObject var login: LoginItemModel
    let showSchedule: () -> Void
    let showFloating: () -> Void
    let showSettings: () -> Void
    let closeWindow: () -> Void
    @State private var editing=false
    @State private var street=""
    @State private var house=""
    @State private var validation=""
    @State private var choosing=false
    @State private var choosingHouse=false
    @State private var searchingHouse=false
    @FocusState private var focus: Field?
    private enum Field: Hashable { case street, house, suggestion(Int) }

    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Image(systemName:"bolt.circle.fill").foregroundStyle(.orange)
                Text("DTEK Monitor").font(.headline)
                Spacer()
                Button("Віджет",action:showFloating).accessibilityIdentifier("open-floating")
                Button(action:showSettings) { Image(systemName:"gearshape") }
                    .help("Налаштування (⌘,)").accessibilityLabel("Налаштування").accessibilityIdentifier("open-settings")
            }
            #if DTEKMONITOR_MAC_TEST_BUILD
            Text("ТЕСТОВІ ДАНІ · не реальний графік").font(.caption.bold()).foregroundStyle(.orange)
                .accessibilityIdentifier("test-banner")
            #endif
            ScrollView {
                VStack(alignment:.leading,spacing:12) {
                    HStack(alignment:.center,spacing:12) {
                        MonitorStatusIcon(model:model,size:46)
                        VStack(alignment:.leading,spacing:4) {
                            Text(model.status).font(.headline).accessibilityIdentifier("status")
                                .fixedSize(horizontal:false,vertical:true)
                            if let countdown=model.state?.countdown, !countdown.isEmpty {
                                Text(countdown + " · орієнтовно").font(.subheadline).monospacedDigit()
                                    .accessibilityIdentifier("countdown")
                            }
                        }
                    }.padding(.vertical,4)
                    HStack {
                        Text(model.state?.address ?? "Адресу не задано").lineLimit(2).accessibilityIdentifier("address")
                        Spacer()
                        Button("Змінити",action:beginEditing).accessibilityIdentifier("edit-address")
                    }
                    if editing { addressForm }
                    if model.state?.stopped == true {
                        Text(model.state?.cleanupStopped == true ? "Не вдалося завершити попереднє з’єднання. Запити зупинено до наступного запуску програми." : "Автоматичні запити зупинено до наступного запуску програми")
                            .font(.caption).foregroundStyle(.orange).accessibilityIdentifier("source-stop")
                    }
                    if model.state?.storageWarning == true {
                        Text("Налаштування або графік не вдалося зберегти. Перевірте доступ до папки даних.")
                            .font(.caption).foregroundStyle(.orange).accessibilityIdentifier("storage-warning")
                    }
                    if model.state?.forecast == true && model.state?.failure != nil {
                        Text("Оновити графік не вдалося. Показано останні підтверджені дані.")
                            .font(.caption).foregroundStyle(.orange).accessibilityIdentifier("retained-warning")
                    }
                    HStack {
                        Button("Сьогодні") { model.selectTomorrow(false) }.accessibilityIdentifier("today")
                            .accessibilityValue(model.state?.tomorrow == true ? "Не вибрано" : "Вибрано")
                        Button("Завтра") { model.selectTomorrow(true) }.accessibilityIdentifier("tomorrow")
                            .disabled(model.state?.tomorrowAvailable != true)
                            .accessibilityValue(model.state?.tomorrow == true ? "Вибрано" : "Не вибрано")
                        Spacer()
                        Text(model.state?.tomorrow == true ? "Завтра" : "Сьогодні").font(.caption)
                            .accessibilityIdentifier("selected-day")
                    }
                    if model.state?.tomorrowAvailable != true {
                        Text("Завтра ще не підтверджене").font(.caption).foregroundStyle(.secondary)
                    }
                    if model.state?.forecast == true {
                        ScheduleTimeline(rows:model.state?.rows ?? [])
                        OutageSummary(rows:model.state?.rows ?? [],totalMinutes:model.state?.totalOutageMinutes ?? 0)
                        Text("Груповий прогноз не підтверджує стан окремої лінії")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(model.state?.emergency == true ? "Час відновлення невідомий" : "Підтвердженого графіка немає")
                            .foregroundStyle(.secondary).padding(.vertical,12)
                    }
                    if let received=model.receivedText { Text(received).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("received") }
                    #if DTEKMONITOR_MAC_TEST_BUILD
                    Text("Тестові GET: \(model.state?.requestCount ?? 0)").font(.caption).accessibilityIdentifier("request-count")
                    #endif
                }.frame(maxWidth:.infinity,alignment:.leading)
            }.accessibilityIdentifier("schedule-scroll")
            Divider()
            HStack {
                Button("Налаштування…",action:showSettings).accessibilityIdentifier("open-settings-footer")
                Spacer()
                Button("Вийти") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q").accessibilityIdentifier("quit")
            }
            Text("v\(Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "—")")
                .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("app-version")
        }.padding(16).frame(width:380).frame(maxHeight:.infinity)
            .background(MonitorSurface())
            .preferredColorScheme(model.theme.colorScheme)
            .background(MonitorWindowReader(onEscape:escape,onSuggestionKey:suggestionKey).frame(width:0,height:0).accessibilityHidden(true))
            .onExitCommand(perform:escape)
    }
    private var addressForm: some View {
        VStack(alignment:.leading,spacing:8) {
            Text("Вулиця").font(.caption.bold())
            TextField("Вулиця в Києві",text:$street).focused($focus,equals:.street).accessibilityIdentifier("street")
                .onChange(of:street) { value in
                    if choosing { choosing=false } else { searchingHouse=false; model.editStreet(value) }
                }
                .onSubmit {
                    guard focus == .street else { return }
                    if !searchingHouse, suggestionsMatch, let first=model.state?.suggestions.first { choose(first) } else { focus = .house }
                }
            if !searchingHouse { suggestionContent }
            Text("Будинок").font(.caption.bold())
            TextField("Будинок",text:$house).focused($focus,equals:.house).accessibilityIdentifier("house")
                .onChange(of:house) { value in
                    if choosingHouse { choosingHouse=false } else { searchingHouse=true; model.editHouse(street:street,house:value) }
                }
                .onSubmit { if focus == .house { apply() } }
            if searchingHouse { suggestionContent }
            if !validation.isEmpty { Text(validation).font(.caption).foregroundStyle(.red).accessibilityIdentifier("address-error") }
            HStack {
                Button("Застосувати",action:apply).accessibilityIdentifier("apply-address")
                Button("Скасувати",action:cancelEditing).accessibilityIdentifier("cancel-address")
            }
        }.textFieldStyle(.roundedBorder)
    }
    @ViewBuilder private var suggestionContent: some View {
        if model.state?.stopped == true {
            Text(model.state?.cleanupStopped == true ? "Пошук зупинено: попереднє з’єднання не завершилося." : "Пошук зупинено джерелом до наступного запуску програми.")
                .font(.caption).foregroundStyle(.orange)
        } else if model.state?.loading == true {
            Text(searchingHouse ? "Пошук будинку…" : "Пошук вулиці…").font(.caption).foregroundStyle(.secondary)
        } else if suggestionsMatch, let result=model.state?.suggestionResult, result != "ready" {
            Text(suggestionMessage(result))
                .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("suggestion-message")
        }
        if suggestionsMatch, let choices=model.state?.suggestions, !choices.isEmpty {
            ForEach(Array(choices.prefix(8).enumerated()),id:\.offset) { index,label in
                Button(action:{ chooseSuggestion(label) }) {
                    Text(label).frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,9).padding(.vertical,6)
                }.buttonStyle(.plain).background(.quaternary,in:RoundedRectangle(cornerRadius:6)).focused($focus,equals:.suggestion(index))
                    .accessibilityIdentifier("suggestion-\(index)")
            }
        }
    }
    private func suggestionMessage(_ result: String) -> String {
        switch result {
        case "empty": return searchingHouse ? "Будинок не знайдено. Перевірте номер." : "Вулицю не знайдено. Спробуйте іншу назву."
        case "address_mismatch": return "Оберіть точну назву вулиці зі списку."
        case "schema": return "Джерело повернуло незрозумілу відповідь. Спробуйте пізніше."
        case "dns": return "Не вдалося знайти сервер джерела. Перевірте з’єднання."
        case "tls": return "Не вдалося встановити захищене з’єднання з джерелом."
        case "timeout": return "Джерело не відповіло вчасно. Спробуйте ще раз."
        case "invalid_response","incomplete_body","body_too_large": return "Не вдалося прочитати відповідь джерела для підказок."
        case "http": return "Джерело тимчасово недоступне. Спробуйте пізніше."
        default: return "Не вдалося отримати підказки. Перевірте з’єднання та спробуйте ще раз."
        }
    }
    private var suggestionsMatch: Bool {
        model.state?.suggestionKind == (searchingHouse ? "house" : "street") &&
            model.state?.suggestionInput == (searchingHouse ? street + "\n" + house : street)
    }
    private func beginEditing() {
        street=model.state?.street ?? ""; house=model.state?.house ?? ""
        validation=""; editing=true; focus = .street; model.editStreet(nil)
    }
    private func choose(_ value: String) {
        if value != street { choosing=true; street=value }
        focus = .house; model.editStreet(nil)
    }
    private func chooseSuggestion(_ value: String) {
        guard suggestionsMatch else { return }
        if model.state?.suggestionKind == "house" {
            if value != house { choosingHouse=true; house=value }
            model.editStreet(nil); focus = .house
        } else { choose(value) }
    }
    private func apply() {
        if let error=model.apply(street:street,house:house) { validation=error }
        else { editing=false; validation=""; focus=nil }
    }
    private func cancelEditing() { editing=false; validation=""; focus=nil; model.cancelEditing() }
    private func escape() { if editing { cancelEditing() } else { closeWindow() } }
    private func suggestionKey(_ key: UInt16) -> Bool {
        guard editing, suggestionsMatch, let choices=model.state?.suggestions,!choices.isEmpty else { return false }
        if key==125 {
            if focus == .street || focus == .house { focus = .suggestion(0); return true }
            if case .some(.suggestion(let index))=focus { focus = .suggestion(min(index+1,min(8,choices.count)-1)); return true }
        }
        if key==126,case .some(.suggestion(let index))=focus {
            focus = index>0 ? .suggestion(index-1) : (searchingHouse ? .house : .street); return true
        }
        if (key==36 || key==76),case .some(.suggestion(let index))=focus,choices.indices.contains(index) {
            chooseSuggestion(choices[index]); return true
        }
        return false
    }
}

// Match the Windows summary: total first, then only planned outage ranges.
// Keep every range when the source supplies more than two; the outer scroll
// view remains the screen-height fallback.
private struct OutageSummary: View {
    let rows: [MonitorSnapshot.Row]
    let totalMinutes: Int
    @Environment(\.colorScheme) private var colorScheme
    private var outages: [MonitorSnapshot.Row] { rows.filter { !$0.power } }
    private func range(_ row: MonitorSnapshot.Row) -> String {
        String(format:"%02d:%02d–%02d:%02d",row.start/60,row.start%60,row.end/60,row.end%60)
    }
    private func duration(_ minutes: Int) -> String {
        let hours=minutes/60,remainder=minutes%60
        if hours == 0 { return "\(remainder) хв" }
        return "\(hours) год" + (remainder == 0 ? "" : " \(remainder) хв")
    }
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            Text("За графіком без світла: " + duration(totalMinutes))
                .font(.caption.bold()).accessibilityIdentifier("outage-total")
            Divider()
            HStack(spacing:12) {
                Image(systemName:"clock").font(.system(size:22)).accessibilityHidden(true)
                if outages.isEmpty {
                    Text("Планових відключень немає").font(.subheadline)
                        .frame(maxWidth:.infinity).accessibilityIdentifier("no-outages")
                } else if outages.count <= 2 {
                    HStack(spacing:8) {
                        ForEach(Array(outages.enumerated()),id:\.element.start) { index,row in
                            if index > 0 { Divider().frame(height:40) }
                            VStack(spacing:4) {
                                Text(range(row)).font(.system(size:14,weight:.semibold)).monospacedDigit()
                                Text(duration(row.end-row.start)).font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth:.infinity)
                                .accessibilityElement(children:.combine).accessibilityIdentifier("interval-\(row.start)")
                        }
                    }
                } else {
                    VStack(spacing:8) {
                        ForEach(outages,id:\.start) { row in
                            HStack {
                                Text(range(row)).monospacedDigit()
                                Spacer()
                                Text(duration(row.end-row.start)).foregroundStyle(.secondary)
                            }.font(.caption)
                                .accessibilityElement(children:.combine).accessibilityIdentifier("interval-\(row.start)")
                        }
                    }
                }
            }
        }.padding(12).frame(maxWidth:.infinity,alignment:.leading)
            .background(colorScheme == .dark
                ? Color(.sRGB,red:59/255,green:68/255,blue:81/255,opacity:1)
                : Color(.sRGB,red:227/255,green:235/255,blue:244/255,opacity:1),in:RoundedRectangle(cornerRadius:8))
            .accessibilityElement(children:.contain).accessibilityIdentifier("outage-summary")
    }
}

// Render exact minute boundaries; the interval list remains the accessible,
// text-based alternative and is also useful when colours are hard to distinguish.
private struct MonitorStatusIcon: View {
    @ObservedObject var model: MonitorModel
    let size: CGFloat
    var current = false
    var body: some View {
        let countdown=(current ? model.state?.currentCountdown : model.state?.countdown) ?? ""
        let emergency=current ? model.state?.currentEmergency : model.state?.emergency
        let name = emergency == true || countdown.hasPrefix("Відновлення") ? "power-off-v1" :
            countdown.hasPrefix("Відключення") ? "power-on-v1" : "notification-v1"
        Group {
            if let image=NSImage(named:NSImage.Name(name)) {
                Image(nsImage:image).resizable().scaledToFit()
            } else {
                Image(systemName:"bolt.circle.fill").resizable().scaledToFit().foregroundStyle(.orange)
            }
        }.frame(width:size,height:size).accessibilityHidden(true)
    }
}

private struct ScheduleTimeline: View {
    let rows: [MonitorSnapshot.Row]
    private var accessibilitySummary: String {
        let outages=rows.filter { !$0.power }
        if outages.isEmpty { return "Планових відключень немає" }
        return outages.map { row in
            String(format:"%02d:%02d–%02d:%02d",row.start/60,row.start%60,row.end/60,row.end%60)
        }.joined(separator:", ")
    }
    var body: some View {
        VStack(alignment:.leading,spacing:9) {
            Text("Планові відключення").font(.caption.bold())
            HStack(spacing:0) {
                ForEach(0..<9,id:\.self) { index in
                    Text(String(format:"%02d",index*3)).font(.system(size:9)).foregroundStyle(.secondary)
                        .frame(maxWidth:.infinity,alignment:index == 0 ? .leading : index == 8 ? .trailing : .center)
                }
            }.accessibilityHidden(true)
            GeometryReader { geometry in
                ZStack(alignment:.leading) {
                    RoundedRectangle(cornerRadius:4).fill(Color.green.opacity(0.36))
                    ForEach(rows.filter { !$0.power },id:\.start) { row in
                        Rectangle().fill(Color.orange.opacity(0.75))
                            .frame(width:geometry.size.width * CGFloat(row.end-row.start)/1440)
                            .offset(x:geometry.size.width * CGFloat(row.start)/1440)
                    }
                }.clipShape(RoundedRectangle(cornerRadius:4))
            }.frame(height:16).accessibilityHidden(true)
            HStack(spacing:18) {
                Label("За графіком зі світлом",systemImage:"circle.fill").foregroundStyle(.green)
                Label("Відключення",systemImage:"circle.fill").foregroundStyle(.orange)
            }.font(.system(size:10)).labelStyle(.titleAndIcon).accessibilityHidden(true)
        }.padding(12).background(.quaternary,in:RoundedRectangle(cornerRadius:9))
            .accessibilityElement(children:.ignore).accessibilityLabel("Шкала планових відключень")
            .accessibilityValue(accessibilitySummary).accessibilityIdentifier("schedule-timeline")
    }
}

// A compact, movable companion window shares the same session and countdown.
@MainActor struct FloatingMonitorView: View {
    @ObservedObject var model: MonitorModel
    let showSchedule: () -> Void
    let close: () -> Void
    let showMenu: () -> Void
    private var size: Int { model.state?.floatingSize ?? 1 }
    var body: some View {
        HStack(spacing:8) {
            MonitorStatusIcon(model:model,size:size == 0 ? 30 : 38,current:true)
                .overlay(alignment:.bottom) {
                    #if DTEKMONITOR_MAC_TEST_BUILD
                    Text("ТЕСТ").font(.system(size:7,weight:.bold)).padding(.horizontal,2)
                        .background(Color(nsColor:.windowBackgroundColor),in:RoundedRectangle(cornerRadius:2))
                        .accessibilityHidden(true)
                    #endif
                }
            VStack(alignment:.leading,spacing:2) {
                if let time=model.floatingTime {
                    Text(time).font(.system(size:size == 0 ? 21 : size == 2 ? 30 : 25,weight:.semibold)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .accessibilityIdentifier("floating-countdown")
                    Text(model.floatingEvent).font(.system(size:size == 0 ? 11 : 13,weight:.medium)).lineLimit(1)
                        .accessibilityIdentifier("floating-status")
                    if model.state?.failure != nil {
                        Text("Немає оновлення").font(.system(size:9)).foregroundStyle(.orange).lineLimit(1)
                            .accessibilityIdentifier("floating-refresh-warning")
                    }
                } else {
                    Text(model.floatingStatus).font(.system(size:size == 0 ? 12 : 14,weight:.semibold)).lineLimit(2)
                        .accessibilityIdentifier("floating-status")
                    #if DTEKMONITOR_MAC_TEST_BUILD
                    Text("ТЕСТОВІ ДАНІ").font(.system(size:8,weight:.bold)).foregroundStyle(.orange)
                    #endif
                }
            }.frame(maxWidth:.infinity,alignment:.leading)
                .contentShape(Rectangle()).onTapGesture(perform:showSchedule)
                .help(model.floatingSummary + ". Натисніть, щоб відкрити графік")
                .accessibilityAction(named:Text("Відкрити графік"),showSchedule)
            Spacer(minLength:0)
            Button(action:showMenu) { Image(systemName:"ellipsis").frame(width:22,height:28) }
                .buttonStyle(.plain).help("Меню віджета").accessibilityLabel("Меню віджета")
                .accessibilityIdentifier("floating-menu")
            Button(action:close) { Image(systemName:"xmark") }
                .buttonStyle(.plain).accessibilityLabel("Приховати віджет").accessibilityIdentifier("floating-close")
        }.padding(.horizontal,10).padding(.vertical,6).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.leading)
            .background(MonitorSurface().clipShape(RoundedRectangle(cornerRadius:11)))
            .overlay(RoundedRectangle(cornerRadius:11).strokeBorder(Color.primary.opacity(0.18),lineWidth:1))
            .preferredColorScheme(model.theme.colorScheme)
            .accessibilityElement(children:.contain).accessibilityIdentifier("floating-content")
    }
}

@MainActor struct MonitorSettingsView: View {
    @ObservedObject var model: MonitorModel
    @ObservedObject var login: LoginItemModel
    let setSize: (Int) -> Void
    let resetPosition: () -> Void
    private func option(_ option: MonitorFloatingOption) -> Binding<Bool> {
        Binding(get:{
            switch option {
            case .locked:return model.state?.floatingLocked == true
            case .topmost:return model.state?.floatingTopmost != false
            case .hideFullscreen:return model.state?.floatingHideFullscreen == true
            }
        },set:{ model.setFloatingOption(option,enabled:$0) })
    }
    var body: some View {
        ScrollView {
        VStack(alignment:.leading,spacing:14) {
            Text("Налаштування").font(.title2.bold()).accessibilityIdentifier("settings-title")
            GroupBox("Запуск програми") {
                VStack(alignment:.leading,spacing:8) {
                    Toggle(login.label,isOn:Binding(get:{ login.checked },set:{ login.requestEnabled($0) }))
                        .disabled(!login.canChange).accessibilityIdentifier("launch-at-login")
                    Text(login.statusText).font(.caption).accessibilityIdentifier("login-status")
                    if login.status == .notFound {
                        Text("Перемістіть програму до «Програми» й запустіть цю копію ще раз.").font(.caption)
                    }
                    Button("Параметри входу macOS…") { login.openSettings() }.accessibilityIdentifier("login-settings")
                    if let message=login.message { Text(message).font(.caption).foregroundStyle(.orange).accessibilityIdentifier("login-message") }
                }.frame(maxWidth:.infinity,alignment:.leading).padding(6)
            }
            GroupBox("Віджет") {
                VStack(alignment:.leading,spacing:10) {
                    Picker("Розмір",selection:Binding(get:{ model.state?.floatingSize ?? 1 },set:{ setSize($0) })) {
                        Text("Компактний").tag(0); Text("Звичайний").tag(1); Text("Великий").tag(2)
                    }.accessibilityIdentifier("widget-size")
                    Toggle("Закріпити позицію",isOn:option(.locked)).accessibilityIdentifier("widget-locked")
                    Toggle("Поверх інших вікон",isOn:option(.topmost)).accessibilityIdentifier("widget-topmost")
                    Toggle("Ховати у повноекранному режимі",isOn:option(.hideFullscreen)).accessibilityIdentifier("widget-fullscreen")
                    Button("Скинути позицію віджета",action:resetPosition).accessibilityIdentifier("reset-position")
                }.frame(maxWidth:.infinity,alignment:.leading).padding(6)
            }
            GroupBox("Оформлення") {
                VStack(alignment:.leading,spacing:8) {
                    HStack {
                        ForEach(MonitorTheme.allCases) { theme in
                            Button(theme.title) { model.setTheme(theme) }.accessibilityIdentifier("theme-\(theme.rawValue)")
                                .accessibilityValue(model.theme == theme ? "Вибрано" : "Не вибрано")
                        }
                    }
                    Text("Тема: \(model.theme.title)").font(.caption).accessibilityIdentifier("selected-theme")
                }.frame(maxWidth:.infinity,alignment:.leading).padding(6)
            }
            Text("Меню дій: ПКМ на віджеті або іконці в menu bar; кнопка «…» на віджеті.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        }.padding(20)
        }.frame(width:420).frame(maxHeight:.infinity)
            .background(MonitorSurface())
            .preferredColorScheme(model.theme.colorScheme)
    }
}

// App-local keyboard handling is limited to the owning visible window.
private struct MonitorWindowReader: NSViewRepresentable {
    let onEscape: () -> Void
    let onSuggestionKey: (UInt16) -> Bool
    final class Reader: NSView {
        var onEscape: (() -> Void)?
        var onSuggestionKey: ((UInt16) -> Bool)?
        var monitor: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); remove()
            guard window != nil else { return }
            monitor=NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] event in
                guard let self=self,let window=self.window,window.isVisible,event.window === window else { return event }
                if event.keyCode==53 { self.onEscape?(); return nil }
                return self.onSuggestionKey?(event.keyCode) == true ? nil : event
            }
        }
        func remove() { if let monitor=monitor { NSEvent.removeMonitor(monitor) }; monitor=nil }
    }
    func makeNSView(context: Context) -> Reader { let view=Reader(); view.onEscape=onEscape; view.onSuggestionKey=onSuggestionKey; return view }
    func updateNSView(_ view: Reader,context: Context) { view.onEscape=onEscape; view.onSuggestionKey=onSuggestionKey }
    static func dismantleNSView(_ view: Reader,coordinator: ()) { view.remove(); view.onEscape=nil; view.onSuggestionKey=nil }
}
