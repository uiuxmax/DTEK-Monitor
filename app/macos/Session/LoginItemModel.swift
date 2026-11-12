import Foundation
import Combine
import ServiceManagement

enum LoginItemStatus: Equatable { case enabled, notRegistered, requiresApproval, notFound, unknown }

@MainActor protocol LoginItemBackend: AnyObject {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
    func openSettings()
}

@MainActor final class LoginItemModel: ObservableObject {
    @Published private(set) var status: LoginItemStatus
    @Published private(set) var message: String?
    private let backend: LoginItemBackend
    init(backend: LoginItemBackend) { self.backend=backend; status=backend.status }
    var checked: Bool { status == .enabled }
    var canChange: Bool { status != .unknown && status != .notFound }
    var label: String {
        switch status {
        case .enabled: return "Запускати після входу — увімкнено"
        case .notRegistered: return "Запускати після входу — вимкнено"
        case .requiresApproval: return "Автозапуск очікує дозволу macOS"
        case .notFound: return "macOS не знайшла цю копію програми"
        case .unknown: return "Стан автозапуску не підтверджено"
        }
    }
    // Startup and returning from Settings only read actual status. No saved
    // preference or startup code can silently register/re-enable this app.
    func refresh() { status=backend.status }
    func requestEnabled(_ enabled: Bool) {
        refresh(); message=nil
        guard canChange else { return }
        if enabled && status == .requiresApproval {
            message="Дозвольте запуск цієї копії в параметрах входу macOS"; return
        }
        guard enabled != checked || (!enabled && status == .requiresApproval) else { return }
        do {
            if enabled { try backend.register() } else { try backend.unregister() }
        } catch { message="macOS не змінила автозапуск. Перевірте параметри входу." }
        refresh()
    }
    func openSettings() { backend.openSettings() }
}

#if DTEKMONITOR_MAC_TEST_BUILD
@MainActor final class FakeLoginItemBackend: LoginItemBackend {
    var status: LoginItemStatus = .notRegistered
    var registeredStatus: LoginItemStatus = .enabled
    var failRegister=false, failUnregister=false
    private(set) var registrations=0, unregistrations=0, settingsOpened=0
    func register() throws {
        registrations += 1
        if failRegister { throw NSError(domain:"SyntheticLoginItem",code:1) }
        status=registeredStatus
    }
    func unregister() throws {
        unregistrations += 1
        if failUnregister { throw NSError(domain:"SyntheticLoginItem",code:2) }
        status = .notRegistered
    }
    func openSettings() { settingsOpened += 1 }
}
#else
@MainActor final class NativeLoginItemBackend: LoginItemBackend {
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .notRegistered: return .notRegistered
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .unknown
        }
    }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}
#endif
