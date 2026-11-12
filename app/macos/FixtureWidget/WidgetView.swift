import SwiftUI
import AppKit

struct WidgetView: View {
    @ObservedObject var model: FixtureModel
    let showSchedule: () -> Void
    @State private var editing = false
    @State private var street = ""
    @State private var house = ""
    @State private var validation = ""
    @FocusState private var streetFocused: Bool
    @StateObject private var windowHandle = WidgetWindowHandle()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "bolt.circle.fill").foregroundStyle(.orange)
                Text("DTEK Monitor").font(.headline)
                Spacer()
                Button("Графік", action: showSchedule).accessibilityIdentifier("open-schedule")
            }
            Text("ТЕСТОВІ ДАНІ · не реальний графік")
                .font(.caption.bold()).foregroundStyle(.orange)
                .accessibilityIdentifier("test-banner")
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.status).font(.title3.bold()).accessibilityIdentifier("status")
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Text(model.address).lineLimit(2).accessibilityIdentifier("address")
                        Spacer()
                        Button("Змінити") { editing = true; validation = ""; streetFocused = true }
                            .accessibilityIdentifier("edit-address")
                    }
                    if editing { addressForm }
                    HStack {
                        Button("Сьогодні") { model.selectTomorrow(false) }
                            .accessibilityIdentifier("today")
                            .accessibilityValue(model.tomorrow ? "Не вибрано" : "Вибрано")
                        Button("Завтра") { model.selectTomorrow(true) }
                            .disabled(!model.tomorrowAvailable).accessibilityIdentifier("tomorrow")
                            .accessibilityValue(model.tomorrow ? "Вибрано" : "Не вибрано")
                        Spacer()
                        Text(model.tomorrow ? "Завтра" : "Сьогодні").font(.caption)
                            .accessibilityIdentifier("selected-day")
                    }
                    if !model.tomorrowAvailable {
                        Text("Завтра ще не підтверджене").font(.caption).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        if model.hasSchedule {
                            ForEach(model.intervals) { interval in
                                HStack {
                                    Image(systemName: interval.hasPower ? "bolt.fill" : "bolt.slash.fill")
                                        .foregroundStyle(interval.hasPower ? .green : .orange)
                                        .accessibilityHidden(true)
                                    Text(interval.time).monospacedDigit()
                                    Spacer()
                                    Text(interval.status)
                                }
                                .padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                                .accessibilityElement(children: .combine)
                                .accessibilityIdentifier("interval-\(interval.startMinute)")
                            }
                        } else {
                            Text(model.scenario == .emergency ? "Час відновлення невідомий" : "Підтвердженого графіка немає")
                                .foregroundStyle(.secondary).padding(.vertical, 16)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.accessibilityIdentifier("schedule-scroll")
            Divider()
            Picker("Тестовий стан", selection: Binding(get: { model.scenario }, set: { model.select($0) })) {
                ForEach(FixtureScenario.allCases) { Text($0.title).tag($0) }
            }.accessibilityIdentifier("fixture-scenario")
            HStack {
                ForEach(FixtureTheme.allCases) { theme in
                    Button(theme.title) { model.theme = theme }
                        .accessibilityIdentifier("theme-\(theme.rawValue)")
                        .accessibilityValue(model.theme == theme ? "Вибрано" : "Не вибрано")
                }
            }
            HStack {
                Text("Тема: \(model.theme.title)").font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("selected-theme")
                Spacer()
                Button("Вийти") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q").accessibilityIdentifier("quit")
            }
        }
        .padding(16).frame(width: 380)
        .frame(maxHeight: .infinity)
        .preferredColorScheme(model.theme.colorScheme)
        .background(WidgetWindowReader(handle: windowHandle).frame(width: 0, height: 0).accessibilityHidden(true))
        .onExitCommand {
            if editing { editing = false; validation = "" }
            else { windowHandle.window?.close() }
        }
    }

    private var addressForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Вулиця (тест)", text: $street).focused($streetFocused)
                .accessibilityIdentifier("street")
            TextField("Будинок", text: $house).accessibilityIdentifier("house")
            if !validation.isEmpty {
                Text(validation).font(.caption).foregroundStyle(.red).accessibilityIdentifier("address-error")
            }
            HStack {
                Button("Застосувати") { applyAddress() }.keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("apply-address")
                Button("Скасувати") { editing = false; validation = "" }
                    .accessibilityIdentifier("cancel-address")
            }
        }
        .textFieldStyle(.roundedBorder)
        .onSubmit { applyAddress() }
    }

    private func applyAddress() {
        if let error = model.apply(street: street, house: house) { validation = error }
        else { editing = false; validation = "" }
    }
}

// MenuBarExtra's panel is not reliably NSApp.keyWindow after field focus ends.
// Keep a weak reference to this view's own window; never close another scene.
private final class WidgetWindowHandle: ObservableObject {
    weak var window: NSWindow?
}

private struct WidgetWindowReader: NSViewRepresentable {
    let handle: WidgetWindowHandle
    final class TrackingView: NSView {
        weak var handle: WidgetWindowHandle?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            handle?.window = window
        }
    }
    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.handle = handle
        return view
    }
    func updateNSView(_ view: TrackingView, context: Context) { handle.window = view.window }
}
