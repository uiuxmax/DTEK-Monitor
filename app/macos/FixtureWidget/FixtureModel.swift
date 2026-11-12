import SwiftUI

enum FixtureScenario: String, CaseIterable, Identifiable {
    case noAddress, loading, ready, tomorrowVerified, emergency, unavailable, longList
    var id: String { rawValue }
    var title: String {
        switch self {
        case .noAddress: return "Без адреси"
        case .loading: return "Завантаження"
        case .ready: return "Графік сьогодні"
        case .tomorrowVerified: return "Завтра підтверджено"
        case .emergency: return "Екстрені відключення"
        case .unavailable: return "Дані недоступні"
        case .longList: return "Довгий список"
        }
    }
}

enum FixtureTheme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "Системна"
        case .light: return "Світла"
        case .dark: return "Темна"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

struct FixtureInterval: Identifiable, Equatable {
    let startMinute: Int
    let endMinute: Int
    let hasPower: Bool
    var id: Int { startMinute }
    var time: String { "\(Self.clock(startMinute))–\(Self.clock(endMinute))" }
    var status: String { hasPower ? "Світло є" : "Без світла" }
    private static func clock(_ minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60, minute % 60)
    }
}

// M2 visual fixtures only. No date projection, countdown, I/O or engine adapter.
// Changing an address does not claim that a provider verified it.
final class FixtureModel: ObservableObject {
    @Published private(set) var scenario: FixtureScenario = .noAddress
    @Published private(set) var tomorrow = false
    @Published private(set) var address = "Адресу не задано"
    @Published var theme: FixtureTheme = .system
    var tomorrowAvailable: Bool { scenario == .tomorrowVerified }
    var hasSchedule: Bool { [.ready, .tomorrowVerified, .longList].contains(scenario) }
    var status: String {
        switch scenario {
        case .noAddress: return "Додайте тестову адресу"
        case .loading: return "Завантаження тестових даних…"
        case .ready, .tomorrowVerified, .longList: return "Тестовий графік доступний"
        case .emergency: return "Екстрені відключення — графік не діє"
        case .unavailable: return "Графік недоступний"
        }
    }
    var intervals: [FixtureInterval] {
        guard hasSchedule else { return [] }
        let count = scenario == .longList ? 48 : 6
        let duration = 1440 / count
        return (0..<count).map {
            FixtureInterval(startMinute: $0 * duration, endMinute: ($0 + 1) * duration,
                            hasPower: ($0 + (tomorrow ? 1 : 0)) % 2 == 0)
        }
    }
    func select(_ value: FixtureScenario) {
        scenario = value
        tomorrow = false
        address = value == .noAddress ? "Адресу не задано" : "Тестова вулиця, 2"
    }
    func selectTomorrow(_ value: Bool) { tomorrow = value && tomorrowAvailable }
    func apply(street: String, house: String) -> String? {
        let street = street.trimmingCharacters(in: .whitespacesAndNewlines)
        let house = house.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !street.isEmpty, !house.isEmpty else { return "Заповніть вулицю та будинок" }
        guard street.utf16.count <= 120, house.utf16.count <= 24 else {
            return "Задовга адреса. Скоротіть вулицю (до 120) або будинок (до 24)"
        }
        address = "\(street), \(house)"
        scenario = .ready
        tomorrow = false
        return nil
    }
}
