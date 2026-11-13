import SwiftUI
import AppKit

@MainActor struct MonitorView: View {
    @ObservedObject var model: MonitorModel
    @ObservedObject var login: LoginItemModel
    let showSchedule: () -> Void
    let showFloating: () -> Void
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
                Button("Графік",action:showSchedule).accessibilityIdentifier("open-schedule")
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
                        Text("Груповий прогноз не підтверджує стан окремої лінії")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(model.state?.rows ?? [],id:\.start) { row in
                            HStack {
                                Image(systemName:row.power ? "bolt.fill" : "bolt.slash.fill")
                                    .foregroundStyle(row.power ? .green : .orange).accessibilityHidden(true)
                                VStack(alignment:.leading,spacing:2) {
                                    Text(time(row.start)+"–"+time(row.end)).monospacedDigit()
                                    Text(MonitorModel.duration(row.end-row.start)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(row.power ? "За графіком зі світлом" : "Планове відключення")
                                    .font(.caption).multilineTextAlignment(.trailing)
                            }.padding(8).background(.quaternary,in:RoundedRectangle(cornerRadius:8))
                                .accessibilityElement(children:.combine).accessibilityIdentifier("interval-\(row.start)")
                        }
                        Text("Разом без світла: " + MonitorModel.duration(model.state?.totalOutageMinutes ?? 0))
                            .font(.caption.bold()).accessibilityIdentifier("outage-total")
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
            Toggle(login.label,isOn:Binding(get:{ login.checked },set:{ login.requestEnabled($0) }))
                .disabled(!login.canChange).accessibilityIdentifier("launch-at-login")
            if login.status == .requiresApproval {
                Button("Параметри входу macOS") { login.openSettings() }.accessibilityIdentifier("login-settings")
            }
            if let message=login.message { Text(message).font(.caption).foregroundStyle(.orange).accessibilityIdentifier("login-message") }
            HStack {
                ForEach(MonitorTheme.allCases) { theme in
                    Button(theme.title) { model.setTheme(theme) }.accessibilityIdentifier("theme-\(theme.rawValue)")
                        .accessibilityValue(model.theme == theme ? "Вибрано" : "Не вибрано")
                }
                Spacer()
                Button("Вийти") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q").accessibilityIdentifier("quit")
            }
            Text("Тема: \(model.theme.title)").font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("selected-theme")
        }.padding(16).frame(width:380).frame(maxHeight:.infinity).preferredColorScheme(model.theme.colorScheme)
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
            Text(result == "empty" ? (searchingHouse ? "Будинок не знайдено. Перевірте номер." : "Вулицю не знайдено. Спробуйте іншу назву.") :
                 result == "address_mismatch" ? "Оберіть точну назву вулиці зі списку." :
                 result == "schema" ? "Джерело повернуло незрозумілу відповідь. Спробуйте пізніше." :
                 "Не вдалося отримати підказки. Перевірте з’єднання та спробуйте ще раз.")
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
    private func time(_ minute: Int) -> String { String(format:"%02d:%02d",minute/60,minute%60) }
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
    let setSize: (Int) -> Void
    var body: some View {
        HStack(spacing:10) {
            MonitorStatusIcon(model:model,size:38,current:true)
            VStack(alignment:.leading,spacing:3) {
            #if DTEKMONITOR_MAC_TEST_BUILD
                Text("ТЕСТОВІ ДАНІ").font(.caption2.bold()).foregroundStyle(.orange)
            #endif
                Text(model.floatingStatus).font(.subheadline.bold()).lineLimit(2).accessibilityIdentifier("floating-status")
                if let countdown=model.state?.currentCountdown, !countdown.isEmpty {
                    Text(countdown + (model.state?.failure == nil ? " · орієнтовно" : " · немає оновлення"))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        .accessibilityIdentifier("floating-countdown")
                }
            }
            Spacer(minLength:0)
            Button(action:showSchedule) { Image(systemName:"calendar") }
                .buttonStyle(.plain).accessibilityLabel("Відкрити графік").accessibilityIdentifier("floating-schedule")
            Menu {
                Button("Компактний") { setSize(0) }
                Button("Звичайний") { setSize(1) }
                Button("Великий") { setSize(2) }
            } label: { Image(systemName:"ellipsis") }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Розмір віджета")
                .accessibilityIdentifier("floating-size")
            Button(action:close) { Image(systemName:"xmark") }
                .buttonStyle(.plain).accessibilityLabel("Приховати віджет").accessibilityIdentifier("floating-close")
        }.padding(.horizontal,12).padding(.vertical,8).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.leading)
            .preferredColorScheme(model.theme.colorScheme)
            .background(.regularMaterial,in:RoundedRectangle(cornerRadius:11))
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
