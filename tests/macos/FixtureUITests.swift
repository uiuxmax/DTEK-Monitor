import XCTest
import AppKit

final class FixtureModelTests: XCTestCase {
    func testInitialState() {
        let model = FixtureModel()
        XCTAssertEqual(model.scenario, .noAddress)
        XCTAssertFalse(model.tomorrow)
        XCTAssertFalse(model.tomorrowAvailable)
        XCTAssertTrue(model.intervals.isEmpty)
    }

    func testTomorrowRequiresConfirmationAndResets() {
        let model = FixtureModel()
        model.select(.ready)
        model.selectTomorrow(true)
        XCTAssertFalse(model.tomorrow)
        model.select(.tomorrowVerified)
        XCTAssertFalse(model.tomorrow)
        let today = model.intervals
        model.selectTomorrow(true)
        XCTAssertTrue(model.tomorrow)
        XCTAssertNotEqual(model.intervals, today)
        model.select(.unavailable)
        XCTAssertFalse(model.tomorrow)
        XCTAssertTrue(model.intervals.isEmpty)
    }

    func testAllFixtureIntervalsCoverExactlyOneDay() {
        let model = FixtureModel()
        for scenario in FixtureScenario.allCases {
            model.select(scenario)
            if model.hasSchedule {
                let intervals = model.intervals
                XCTAssertEqual(intervals.first?.startMinute, 0)
                XCTAssertEqual(intervals.last?.endMinute, 1440)
                XCTAssertEqual(Set(intervals.map(\.id)).count, intervals.count)
                for pair in zip(intervals, intervals.dropFirst()) {
                    XCTAssertEqual(pair.0.endMinute, pair.1.startMinute)
                }
                XCTAssertEqual(intervals.count, scenario == .longList ? 48 : 6)
                XCTAssertTrue(intervals.last?.time.hasSuffix("24:00") == true)
            } else { XCTAssertTrue(model.intervals.isEmpty) }
        }
    }

    func testAddressValidationIsAtomicAndUsesUTF16() {
        let model = FixtureModel()
        XCTAssertNotNil(model.apply(street: " ", house: "2"))
        XCTAssertEqual(model.scenario, .noAddress)
        XCTAssertNil(model.apply(street: "  Тестова вулиця  ", house: " 2-А "))
        XCTAssertEqual(model.address, "Тестова вулиця, 2-А")
        let original = model.address
        XCTAssertNotNil(model.apply(street: String(repeating: "😀", count: 61), house: "2"))
        XCTAssertNotNil(model.apply(street: "Тест", house: String(repeating: "1", count: 25)))
        XCTAssertEqual(model.address, original)
        XCTAssertNil(model.apply(street: String(repeating: "😀", count: 60), house: String(repeating: "1", count: 24)))
        let fresh = FixtureModel()
        XCTAssertEqual(fresh.scenario, .noAddress, "Fixture addresses must stay in memory")
    }

    func testThemeMapping() {
        XCTAssertNil(FixtureTheme.system.colorScheme)
        XCTAssertEqual(FixtureTheme.dark.colorScheme, .dark)
        XCTAssertEqual(FixtureTheme.light.colorScheme, .light)
    }

    func testEnvelopeRejectsIncompleteAndUnsafePaths() throws {
        let root = try FixtureUITests.makeRunRoot()
        var envelope = FixtureUITests.envelope(root)
        XCTAssertTrue(TestEnvelope.isValid(envelope))
        XCTAssertFalse(TestEnvelope.isValid([:]))
        for key in envelope.keys {
            var incomplete = envelope
            incomplete.removeValue(forKey: key)
            XCTAssertFalse(TestEnvelope.isValid(incomplete), key)
        }
        for (key, value) in [("DTEKMONITOR_AUTOSTART_TEST_MODE", "0"),
                             ("DTEKMONITOR_DISABLE_PROVIDER", "0"),
                             ("DTEKMONITOR_TEST_INSTANCE", "../escape"),
                             ("DTEKMONITOR_TEST_ROOT", "/"),
                             ("DTEKMONITOR_TEST_PROFILE", root.path)] {
            var invalid = envelope
            invalid[key] = value
            XCTAssertFalse(TestEnvelope.isValid(invalid))
        }
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root.appendingPathComponent("profile"))
        envelope["DTEKMONITOR_TEST_PROFILE"] = alias.path
        XCTAssertFalse(TestEnvelope.isValid(envelope))
    }
}

final class FixtureUITests: XCTestCase {
    private var app: XCUIApplication!

    static func makeRunRoot() throws -> URL {
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { repository.deleteLastPathComponent() }
        guard FileManager.default.fileExists(atPath: repository.appendingPathComponent("app/macos/FixtureWidget/Info.plist").path)
        else { throw NSError(domain: "Missing checkout", code: 1) }
        let root = repository.appendingPathComponent("out/macos/ui-tests-" + UUID().uuidString)
            .standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("profile"), withIntermediateDirectories: true)
        return root
    }

    static func envelope(_ root: URL) -> [String: String] {
        ["DTEKMONITOR_TEST_ROOT": root.path,
         "DTEKMONITOR_TEST_PROFILE": root.appendingPathComponent("profile").path,
         "DTEKMONITOR_TEST_INSTANCE": root.lastPathComponent,
         "DTEKMONITOR_AUTOSTART_TEST_MODE": "1", "DTEKMONITOR_DISABLE_PROVIDER": "1"]
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "local.dtekmonitor.FixtureWidget")
        app.launchEnvironment = Self.envelope(try Self.makeRunRoot())
        app.launch()
        XCTAssertTrue(element("test-banner").waitForExistence(timeout: 10))
    }
    override func tearDownWithError() throws { app?.terminate() }
    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
    private func choose(_ scenario: FixtureScenario) {
        element("fixture-scenario").click()
        app.menuItems[scenario.title].click()
    }

    func testInitialStateAndWindowBounds() {
        XCTAssertTrue(element("status").label.contains("Додайте тестову адресу"))
        XCTAssertFalse(element("tomorrow").isEnabled)
        XCTAssertEqual(element("selected-day").label, "Сьогодні")
        let window = app.windows.firstMatch
        XCTAssertLessThanOrEqual(window.frame.height, NSScreen.main!.visibleFrame.height)
        XCTAssertLessThanOrEqual(window.frame.width, NSScreen.main!.visibleFrame.width)
    }

    func testAddressValidationAndKeyboardSubmit() {
        element("edit-address").click()
        element("apply-address").click()
        XCTAssertTrue(element("address-error").exists)
        element("street").click()
        element("street").typeText("Тестова вулиця")
        element("house").click()
        element("house").typeText("2-А\r")
        XCTAssertTrue(element("address").label.contains("Тестова вулиця, 2-А"))
        XCTAssertFalse(element("street").exists)
        XCTAssertTrue(element("status").label.contains("доступний"))
    }

    func testStatesAndConfirmedTomorrow() {
        choose(.ready)
        XCTAssertFalse(element("tomorrow").isEnabled)
        choose(.tomorrowVerified)
        XCTAssertTrue(element("tomorrow").isEnabled)
        XCTAssertEqual(element("selected-day").label, "Сьогодні")
        element("tomorrow").click()
        XCTAssertEqual(element("selected-day").label, "Завтра")
        choose(.emergency)
        XCTAssertTrue(element("status").label.contains("Екстрені"))
        XCTAssertFalse(element("tomorrow").isEnabled)
        XCTAssertEqual(element("selected-day").label, "Сьогодні")
        choose(.loading)
        XCTAssertTrue(element("status").label.contains("Завантаження"))
        choose(.unavailable)
        XCTAssertTrue(element("status").label.contains("недоступний"))
    }

    func testThemesAndEscapeCancel() {
        for theme in FixtureTheme.allCases {
            element("theme-\(theme.rawValue)").click()
            XCTAssertEqual(element("selected-theme").label, "Тема: \(theme.title)")
        }
        element("edit-address").click()
        element("street").typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(element("street").exists)
        XCTAssertTrue(element("address").label.contains("не задано"))
    }

    func testLongScheduleScrollsWithinWindow() {
        choose(.longList)
        let last = element("interval-1410")
        let scroll = element("schedule-scroll")
        XCTAssertTrue(scroll.exists)
        for _ in 0..<24 {
            if last.isHittable { break }
            scroll.scroll(byDeltaX: 0, deltaY: -220)
        }
        XCTAssertTrue(last.isHittable)
        XCTAssertTrue(last.label.contains("24:00"))
        XCTAssertLessThanOrEqual(app.windows.firstMatch.frame.height, NSScreen.main!.visibleFrame.height)
    }

    func testMenuBarPanelAndEscape() {
        app.windows.firstMatch.buttons[XCUIIdentifierCloseWindow].click()
        let item = app.menuBars.menuBarItems.matching(NSPredicate(format: "label CONTAINS %@", "ТЕСТ · DTEK")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), app.debugDescription)
        item.click()
        XCTAssertTrue(element("test-banner").waitForExistence(timeout: 5))
        element("edit-address").click()
        element("street").typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(element("street").exists)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(element("test-banner").isHittable)
    }

    func testReopenUsesSameProcessAndQuit() throws {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "local.dtekmonitor.FixtureWidget")
        XCTAssertEqual(running.count, 1)
        let instance = try XCTUnwrap(running.first)
        let bundle = try XCTUnwrap(instance.bundleURL)
        app.windows.firstMatch.buttons[XCUIIdentifierCloseWindow].click()
        let command = Process()
        command.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        command.arguments = [bundle.path]
        try command.run()
        command.waitUntilExit()
        XCTAssertEqual(command.terminationStatus, 0)
        XCTAssertTrue(element("test-banner").waitForExistence(timeout: 5))
        XCTAssertEqual(NSRunningApplication.runningApplications(withBundleIdentifier: "local.dtekmonitor.FixtureWidget")
            .map(\.processIdentifier), [instance.processIdentifier])
        element("quit").click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
    }
}
