import SwiftUI
import AppKit

@MainActor struct MonitorView: View {
    @ObservedObject var model: MonitorModel
    @ObservedObject var login: LoginItemModel
    let showSchedule: () -> Void
    let closeWindow: () -> Void
    @State private var editing=false
    @State private var street=""
    @State private var house=""
    @State private var validation=""
    @State private var choosing=false
    @FocusState private var focus: Field?
    private enum Field: Hashable { case street, house, suggestion(Int) }

    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Image(systemName:"bolt.circle.fill").foregroundStyle(.orange)
                Text("DTEK Monitor").font(.headline)
                Spacer()
                Button("Графік",action:showSchedule).accessibilityIdentifier("open-schedule")
            }
            #if DTEKMONITOR_MAC_TEST_BUILD
            Text("ТЕСТОВІ ДАНІ · не реальний графік").font(.caption.bold()).foregroundStyle(.orange)
                .accessibilityIdentifier("test-banner")
            #endif
            ScrollView {
                VStack(alignment:.leading,spacing:12) {
                    Text(model.status).font(.title3.bold()).accessibilityIdentifier("status")
                        .fixedSize(horizontal:false,vertical:true)
                    HStack {
                        Text(model.state?.address ?? "Адресу не задано").lineLimit(2).accessibilityIdentifier("address")
                        Spacer()
                        Button("Змінити",action:beginEditing).accessibilityIdentifier("edit-address")
                    }
                    if editing { addressForm }
                    if model.state?.stopped == true {
                        Text("Автоматичні запити зупинено до наступного запуску програми")
                            .font(.caption).foregroundStyle(.orange).accessibilityIdentifier("source-stop")
                    }
                    if model.state?.storageWarning == true {
                        Text("Налаштування або графік не вдалося зберегти. Перевірте доступ до папки даних.")
                            .font(.caption).foregroundStyle(.orange).accessibilityIdentifier("storage-warning")
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
                    if let countdown=model.state?.countdown, !countdown.isEmpty {
                        Text("Орієнтовно: " + countdown).font(.headline).monospacedDigit()
                            .accessibilityIdentifier("countdown")
                    }
                    if model.state?.forecast == true {
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
            TextField("Вулиця в Києві",text:$street).focused($focus,equals:.street).accessibilityIdentifier("street")
                .onChange(of:street) { value in
                    if choosing { choosing=false } else { model.editStreet(value) }
                }
                .onSubmit {
                    if let first=model.state?.suggestions.first { choose(first) } else { focus = .house }
                }
            if let choices=model.state?.suggestions, !choices.isEmpty {
                ForEach(Array(choices.prefix(8).enumerated()),id:\.offset) { index,label in
                    Button(label) { choose(label) }.buttonStyle(.plain).focused($focus,equals:.suggestion(index))
                        .accessibilityIdentifier("suggestion-\(index)")
                }
            }
            TextField("Будинок",text:$house).focused($focus,equals:.house).accessibilityIdentifier("house")
                .onSubmit(perform:apply)
            if !validation.isEmpty { Text(validation).font(.caption).foregroundStyle(.red).accessibilityIdentifier("address-error") }
            HStack {
                Button("Застосувати",action:apply).accessibilityIdentifier("apply-address")
                Button("Скасувати",action:cancelEditing).accessibilityIdentifier("cancel-address")
            }
        }.textFieldStyle(.roundedBorder)
    }
    private func beginEditing() {
        street=model.state?.street ?? ""; house=model.state?.house ?? ""
        validation=""; editing=true; focus = .street; model.editStreet(nil)
    }
    private func choose(_ value: String) {
        if value != street { choosing=true; street=value }
        focus = .house; model.editStreet(nil)
    }
    private func apply() {
        if let error=model.apply(street:street,house:house) { validation=error }
        else { editing=false; validation=""; focus=nil }
    }
    private func cancelEditing() { editing=false; validation=""; focus=nil; model.cancelEditing() }
    private func escape() { if editing { cancelEditing() } else { closeWindow() } }
    private func suggestionKey(_ key: UInt16) -> Bool {
        guard editing,let choices=model.state?.suggestions,!choices.isEmpty else { return false }
        if key==125 {
            if focus == .street { focus = .suggestion(0); return true }
            if case .some(.suggestion(let index))=focus { focus = .suggestion(min(index+1,min(8,choices.count)-1)); return true }
        }
        if key==126,case .some(.suggestion(let index))=focus {
            focus = index>0 ? .suggestion(index-1) : .street; return true
        }
        if (key==36 || key==76),case .some(.suggestion(let index))=focus,choices.indices.contains(index) {
            choose(choices[index]); return true
        }
        return false
    }
    private func time(_ minute: Int) -> String { String(format:"%02d:%02d",minute/60,minute%60) }
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
