import SwiftUI
import Combine
import AppKit

enum MonitorTheme: String,CaseIterable,Identifiable {
    case system,light,dark
    var id: String { rawValue }
    var title: String {
        switch self { case .system:return "Системна"; case .light:return "Світла"; case .dark:return "Темна" }
    }
    var colorScheme: ColorScheme? {
        switch self { case .system:return nil; case .light:return .light; case .dark:return .dark }
    }
}

// UI is a MainActor projection of immutable actor snapshots. Profile/receipt
// mutation and lookup callbacks never run in this object or SwiftUI body.
@MainActor final class MonitorModel: ObservableObject {
    @Published private(set) var state: MonitorSnapshot?
    private var session: MonitorSession?
    private var ticks: Task<Void,Never>?
    private var debounce: Task<Void,Never>?
    private var commands: Task<Void,Never>?
    private var observers = Set<AnyCancellable>()
    private var appliedSequence: UInt64 = 0

    init(profile: String, clock: MonitorClock, mode: MonitorTransportMode) {
        let owned=MonitorSession(profile:profile,clock:clock,mode:mode) { [weak self] value in
            Task { @MainActor [weak self] in self?.receive(value) }
        }
        session=owned
        commands=Task { await owned.start() }
        ticks=Task { [weak self] in
            guard let session=self?.session else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for:.seconds(1)) } catch { return }
                await session.tick()
            }
        }
        NSWorkspace.shared.notificationCenter.publisher(for:NSWorkspace.didWakeNotification)
            .receive(on:RunLoop.main).sink { [weak self] _ in self?.wake() }.store(in:&observers)
        NotificationCenter.default.publisher(for:.NSSystemClockDidChange)
            .receive(on:RunLoop.main).sink { [weak self] _ in self?.clockChanged() }.store(in:&observers)
    }
    private func receive(_ snapshot: MonitorSnapshot) {
        guard snapshot.sequence > appliedSequence else { return }
        appliedSequence=snapshot.sequence; state=snapshot
    }
    private func wake() {
        guard let session=session else { return }
        Task { await session.tick(wake:true) }
    }
    private func clockChanged() { guard let session=session else { return }; Task { await session.tick(wake:true,clockChanged:true) } }
    private func send(_ action: @escaping @Sendable (MonitorSession) async -> Void) {
        guard let session=session else { return }
        let previous=commands
        commands=Task { await previous?.value; await action(session) }
    }
    func popupOpened() {
        send { await $0.popupOpened() }
    }
    func editStreet(_ input: String?) {
        debounce?.cancel()
        send { await $0.editStreet(input) }
        // This task owns edit + debounce ordering; the session clock determines
        // eligibility again when the callback arrives after a possible sleep.
        debounce=Task { [weak self] in
            do { try await Task.sleep(for:.milliseconds(450)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.send { await $0.tick() }
        }
    }
    func cancelEditing() {
        debounce?.cancel()
        send { await $0.cancelEditing() }
    }
    func editHouse(street: String, house: String) {
        debounce?.cancel()
        send { await $0.editHouse(street:street,house:house) }
        debounce=Task { [weak self] in
            do { try await Task.sleep(for:.milliseconds(450)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.send { await $0.tick() }
        }
    }
    func apply(street: String, house: String) -> String? {
        guard let normalized=DMMonitorEngine.normalize(street:street,house:house),
              let street=normalized["street"], let house=normalized["house"] else {
            return "Вкажіть вулицю до 120 та будинок до 24 символів, без керівних знаків"
        }
        debounce?.cancel()
        guard session != nil else { return "Сесію завершено" }
        send { await $0.applyAddress(street:street,house:house) }
        return nil
    }
    func selectTomorrow(_ tomorrow: Bool) {
        send { await $0.selectTomorrow(tomorrow) }
    }
    func setTheme(_ theme: MonitorTheme) {
        send { await $0.setTheme(theme.rawValue) }
    }
    func setFloating(visible: Bool, positioned: Bool, x: Int, y: Int, size: Int) {
        send { await $0.setFloating(visible:visible,positioned:positioned,x:x,y:y,size:size) }
    }
    func stop() async {
        ticks?.cancel(); debounce?.cancel(); observers.removeAll()
        let owned=session; session=nil
        await commands?.value; commands=nil
        await owned?.close()
    }
    var theme: MonitorTheme { MonitorTheme(rawValue:state?.theme ?? "system") ?? .system }
    var status: String {
        guard let value=state else { return "Завантаження…" }
        if value.editing { return "Редагування адреси" }
        if value.street.isEmpty { return "Додайте адресу в Києві" }
        if value.emergency { return "Екстрені відключення — графік не діє" }
        if value.forecast { return "Орієнтовний груповий графік" }
        if value.stopped { return "Джерело тимчасово обмежило запити" }
        if value.loading { return "Завантаження графіка…" }
        if value.failure == "address_mismatch" { return "Адресу не знайдено" }
        if value.failure == "transport" { return "Не вдалося з’єднатися з джерелом" }
        if value.failure == "schema" { return "Не вдалося прочитати відповідь джерела" }
        return "Підтвердженого графіка немає"
    }
    var receivedText: String? {
        guard let epoch=state?.received, let zone=TimeZone(identifier:"Europe/Kyiv") else { return nil }
        let formatter=DateFormatter(); formatter.locale=Locale(identifier:"uk_UA")
        formatter.timeZone=zone; formatter.dateFormat="dd.MM HH:mm"
        return "Отримано " + formatter.string(from:Date(timeIntervalSince1970:Double(epoch)))
    }
    static func duration(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) хв" }
        return minutes % 60 == 0 ? "\(minutes/60) г" : "\(minutes/60) г \(minutes%60) хв"
    }
}
