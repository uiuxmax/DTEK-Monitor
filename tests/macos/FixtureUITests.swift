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
        envelope["DTEKMONITOR_TEST_PROFILE"] = alias.path
        XCTAssertFalse(TestEnvelope.isValid(envelope))
    }
}

final class FixtureUITests: XCTestCase {
    private var app: XCUIApplication!
    private var ownedProcess: pid_t?
    private static var nextProfile = 0

    static func makeRunRoot() throws -> URL {
        guard let path = Bundle(for: FixtureUITests.self).object(forInfoDictionaryKey: "DTEKFixtureRoot") as? String,
              path.hasPrefix("/"), !path.contains("$(") else {
            throw NSError(domain: "Run tools/macos/check-ui.sh to prepare isolated profiles", code: 1)
        }
        defer { nextProfile += 1 }
        let root = URL(fileURLWithPath: path).appendingPathComponent("case-\(nextProfile)")
            .standardizedFileURL.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("profile").path) else {
            throw NSError(domain: "Harness profile is missing", code: 2)
        }
        return root
    }

    static func envelope(_ root: URL) -> [String: String] {
        ["DTEKMONITOR_TEST_ROOT": root.path,
         "DTEKMONITOR_TEST_PROFILE": root.appendingPathComponent("profile").path,
         "DTEKMONITOR_TEST_INSTANCE": root.deletingLastPathComponent().lastPathComponent + "-" + root.lastPathComponent,
         "DTEKMONITOR_AUTOSTART_TEST_MODE": "1", "DTEKMONITOR_DISABLE_PROVIDER": "1"]
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "local.dtekmonitor.FixtureWidget").isEmpty
        else { throw XCTSkip("An existing fixture app is running; leave it untouched and close it manually before testing") }
        app = XCUIApplication(bundleIdentifier: "local.dtekmonitor.FixtureWidget")
        app.launchEnvironment = Self.envelope(try Self.makeRunRoot())
        app.launch()
        ownedProcess = NSRunningApplication.runningApplications(withBundleIdentifier: "local.dtekmonitor.FixtureWidget")
            .first?.processIdentifier
        XCTAssertTrue(element("test-banner").waitForExistence(timeout: 10))
    }
    override func tearDownWithError() throws {
        if let pid = ownedProcess, NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "local.dtekmonitor.FixtureWidget" {
            app?.terminate()
        }
    }
    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
    private func text(_ element: XCUIElement) -> String {
        // macOS static text exposes its content as AXValue; combined rows can
        // expose AXLabel. Assert the actual text through either native mapping.
        if let value = element.value as? String, !value.isEmpty { return value }
        return element.label
    }
    private func choose(_ scenario: FixtureScenario) {
        element("fixture-scenario").click()
        app.menuItems[scenario.title].click()
    }

    func testInitialStateAndWindowBounds() {
        XCTAssertTrue(text(element("status")).contains("Додайте тестову адресу"))
        XCTAssertFalse(element("tomorrow").isEnabled)
        XCTAssertEqual(text(element("selected-day")), "Сьогодні")
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
        XCTAssertTrue(text(element("address")).contains("Тестова вулиця, 2-А"))
        XCTAssertFalse(element("street").exists)
        XCTAssertTrue(text(element("status")).contains("доступний"))
    }

    func testStatesAndConfirmedTomorrow() {
        choose(.ready)
        XCTAssertFalse(element("tomorrow").isEnabled)
        choose(.tomorrowVerified)
        XCTAssertTrue(element("tomorrow").isEnabled)
        XCTAssertEqual(text(element("selected-day")), "Сьогодні")
        element("tomorrow").click()
        XCTAssertEqual(text(element("selected-day")), "Завтра")
        choose(.emergency)
        XCTAssertTrue(text(element("status")).contains("Екстрені"))
        XCTAssertFalse(element("tomorrow").isEnabled)
        XCTAssertEqual(text(element("selected-day")), "Сьогодні")
        choose(.loading)
        XCTAssertTrue(text(element("status")).contains("Завантаження"))
        choose(.unavailable)
        XCTAssertTrue(text(element("status")).contains("недоступний"))
    }

    func testThemesAndEscapeCancel() {
        for theme in FixtureTheme.allCases {
            element("theme-\(theme.rawValue)").click()
            XCTAssertEqual(text(element("selected-theme")), "Тема: \(theme.title)")
        }
        element("edit-address").click()
        element("street").typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(element("street").exists)
        XCTAssertTrue(text(element("address")).contains("не задано"))
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
        XCTAssertTrue(text(last).contains("24:00"))
        XCTAssertLessThanOrEqual(app.windows.firstMatch.frame.height, NSScreen.main!.visibleFrame.height)
    }

    func testMenuBarPanelAndEscape() {
        app.windows.firstMatch.buttons[XCUIIdentifierCloseWindow].click()
        let item = element("fixture-menubar")
        XCTAssertTrue(item.waitForExistence(timeout: 5), app.debugDescription)
        item.click()
        XCTAssertTrue(element("test-banner").waitForExistence(timeout: 5))
        element("edit-address").click()
        element("street").typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(element("street").exists)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(element("test-banner").isHittable)
        item.click()
        XCTAssertTrue(element("test-banner").waitForExistence(timeout: 5))
        XCTAssertTrue(element("test-banner").isHittable)
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
