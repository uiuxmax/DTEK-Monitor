import XCTest
import AppKit

final class MonitorUITests: XCTestCase {
    private var app: XCUIApplication!
    private var pid: pid_t?
    private var root: URL!
    private static var nextProfile=0
    override func setUpWithError() throws {
        continueAfterFailure=false
        guard NSRunningApplication.runningApplications(withBundleIdentifier:"local.dtekmonitor.MonitorTest").isEmpty else {
            throw XCTSkip("An existing MonitorTest app is running; leave it untouched")
        }
        guard let base=Bundle(for:Self.self).object(forInfoDictionaryKey:"DTEKMonitorRoot") as? String,
              base.hasPrefix("/"),!base.contains("$(") else { throw NSError(domain:"Run check-monitor.sh",code:1) }
        let number=Self.nextProfile; Self.nextProfile += 1
        root=URL(fileURLWithPath:base).appendingPathComponent("case-\(number)").standardizedFileURL.resolvingSymlinksInPath()
        XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent("profile").path))
        app=XCUIApplication(bundleIdentifier:"local.dtekmonitor.MonitorTest")
        app.launchEnvironment=["DTEKMONITOR_TEST_ROOT":root.path,"DTEKMONITOR_TEST_PROFILE":root.appendingPathComponent("profile").path,
            "DTEKMONITOR_TEST_INSTANCE":"monitor-case-\(number)","DTEKMONITOR_DISABLE_PROVIDER":"1","DTEKMONITOR_AUTOSTART_TEST_MODE":"1"]
    }
    override func tearDownWithError() throws {
        if let pid=pid,NSRunningApplication(processIdentifier:pid)?.bundleIdentifier=="local.dtekmonitor.MonitorTest" { app?.terminate() }
    }
    private func launch(_ scenario: String="tomorrow") {
        app.launchEnvironment["DTEKMONITOR_TEST_SCENARIO"]=scenario
        app.launch()
        pid=NSRunningApplication.runningApplications(withBundleIdentifier:"local.dtekmonitor.MonitorTest").first?.processIdentifier
        XCTAssertTrue(element("test-banner").waitForExistence(timeout:10))
    }
    private func element(_ id: String) -> XCUIElement { app.descendants(matching:.any).matching(identifier:id).firstMatch }
    private func text(_ item: XCUIElement) -> String {
        if let value=item.value as? String,!value.isEmpty { return value }; return item.label
    }
    private func waitText(_ id: String,_ expected: String) {
        let item=element(id)
        let predicate=NSPredicate { [weak self] _,_ in guard let self=self else { return false }; return item.exists && self.text(item).contains(expected) }
        let result=XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:predicate,object:nil)],timeout:8)
        XCTAssertEqual(result,.completed,"Expected \(id) to contain \(expected); actual: \(item.exists ? text(item) : "<missing>")")
    }
    private func applyAddress() {
        element("edit-address").click()
        element("street").click(); element("street").typeText("вул. Тестова")
        element("house").click(); element("house").typeText("2-А\r")
    }
    private func ready() { XCTAssertTrue(element("interval-510").waitForExistence(timeout:8)) }
    private func waitLogin(_ checked: Bool) {
        let native=app.checkBoxes.matching(identifier:"launch-at-login").firstMatch
        let toggle=native.exists ? native : element("launch-at-login")
        let predicate=NSPredicate { _,_ in
            if let number=toggle.value as? NSNumber { return number.boolValue==checked }
            if let text=toggle.value as? String { return text==(checked ? "1" : "0") }
            return false
        }
        let result=XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:predicate,object:nil)],timeout:8)
        XCTAssertEqual(result,.completed,"Toggle AX: \(toggle.debugDescription); value=\(String(describing:toggle.value))")
    }
    private func reopen() throws {
        guard let pid=pid,let url=NSRunningApplication(processIdentifier:pid)?.bundleURL else { throw NSError(domain:"Owned app missing",code:1) }
        let opened=expectation(description:"reopen owned app")
        let config=NSWorkspace.OpenConfiguration(); config.createsNewApplicationInstance=false; config.activates=true
        NSWorkspace.shared.openApplication(at:url,configuration:config) { _,error in XCTAssertNil(error); opened.fulfill() }
        wait(for:[opened],timeout:8)
    }
    func testInitialProfileAndBounds() {
        launch(); waitText("status","Додайте адресу"); waitText("request-count","0")
        XCTAssertFalse(element("tomorrow").isEnabled)
        XCTAssertFalse(element("fixture-scenario").exists)
        let window=app.windows.firstMatch
        XCTAssertLessThanOrEqual(window.frame.height,NSScreen.main!.visibleFrame.height)
        XCTAssertLessThanOrEqual(window.frame.width,NSScreen.main!.visibleFrame.width)
        element("open-floating").click()
        XCTAssertTrue(element("floating-status").waitForExistence(timeout:8))
        waitText("floating-status","Додайте адресу")
        element("floating-close").click()
        XCTAssertFalse(element("floating-status").exists)
        element("open-floating").click()
        XCTAssertTrue(element("floating-status").waitForExistence(timeout:8))
        waitText("request-count","0")
        let settings=root.appendingPathComponent("profile/settings.json")
        let saved=NSPredicate { _,_ in
            guard let bytes=try? Data(contentsOf:settings),
                  let value=(try? JSONSerialization.jsonObject(with:bytes)) as? [String:Any],
                  let floating=value["floating"] as? [String:Any] else { return false }
            return (floating["visible"] as? NSNumber)?.intValue == 1 && (floating["positioned"] as? NSNumber)?.intValue == 1
        }
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:saved,object:nil)],timeout:8),.completed)
        // Borderless NSPanel is exposed through its accessible contents rather
        // than consistently appearing in XCUIApplication.windows.
        let floating=element("floating-status")
        let old=floating.frame.origin
        app.terminate(); launch()
        XCTAssertTrue(element("floating-status").waitForExistence(timeout:8))
        XCTAssertTrue(floating.waitForExistence(timeout:8))
        XCTAssertLessThanOrEqual(abs(floating.frame.origin.x-old.x),2)
        XCTAssertLessThanOrEqual(abs(floating.frame.origin.y-old.y),2)
    }
    func testSuggestionsKeyboardApplyAndLocalTicks() {
        launch(); element("edit-address").click(); element("street").typeText("те")
        XCTAssertTrue(element("suggestion-0").waitForExistence(timeout:8))
        element("street").typeKey(.downArrow,modifierFlags:[]); app.typeKey(.return,modifierFlags:[])
        element("house").typeText("2")
        XCTAssertTrue(element("suggestion-0").waitForExistence(timeout:8))
        element("house").typeKey(.downArrow,modifierFlags:[]); app.typeKey(.return,modifierFlags:[])
        element("house").click(); element("house").typeText("-А\r"); ready()
        waitText("address","вул. Тестова, 2-А"); waitText("outage-total","3 г 30 хв")
        XCTAssertTrue(element("schedule-timeline").exists)
        waitText("request-count","7"); XCTAssertTrue(element("received").exists)
        Thread.sleep(forTimeInterval:1.2); waitText("request-count","7")
    }
    func testValidationDoesNotStartLookup() {
        launch(); element("edit-address").click(); element("apply-address").click()
        XCTAssertTrue(element("address-error").exists); waitText("request-count","0")
        element("street").typeKey(.escape,modifierFlags:[])
        XCTAssertFalse(element("street").exists); waitText("status","Додайте адресу")
    }
    func testEditingEscapeRestoresReceipt() {
        launch(); applyAddress(); ready()
        element("edit-address").click(); waitText("status","Редагування")
        XCTAssertFalse(element("interval-510").exists)
        element("street").typeKey(.escape,modifierFlags:[]); ready()
        XCTAssertFalse(element("street").exists)
    }
    func testTomorrowReopenAndCloseKeepsProcess() throws {
        launch(); applyAddress(); ready(); XCTAssertTrue(element("tomorrow").isEnabled)
        element("tomorrow").click(); waitText("selected-day","Завтра")
        XCTAssertFalse(element("countdown").exists)
        element("open-floating").click()
        XCTAssertTrue(element("floating-countdown").waitForExistence(timeout:8))
        let original=pid
        app.windows.firstMatch.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(app.state == .runningBackground || app.state == .runningForeground)
        XCTAssertNotNil(original.flatMap { NSRunningApplication(processIdentifier:$0) })
        try reopen()
        waitText("selected-day","Сьогодні")
        XCTAssertEqual(NSRunningApplication.runningApplications(withBundleIdentifier:"local.dtekmonitor.MonitorTest").count,1)
        XCTAssertEqual(NSRunningApplication.runningApplications(withBundleIdentifier:"local.dtekmonitor.MonitorTest").first?.processIdentifier,original)
    }
    func testEmergencyHasNoInventedCountdown() {
        launch("emergency"); applyAddress(); waitText("status","Екстрені")
        XCTAssertFalse(element("interval-510").exists); XCTAssertFalse(element("countdown").exists)
        XCTAssertFalse(element("tomorrow").isEnabled)
    }
    func testSourceStopSurvivesAddressEdit() {
        launch("429"); applyAddress(); XCTAssertTrue(element("source-stop").waitForExistence(timeout:8)); waitText("request-count","1")
        element("edit-address").click(); element("street").click(); app.typeKey("a",modifierFlags:.command)
        element("street").typeText("вул. Інша"); element("apply-address").click()
        waitText("address","вул. Інша"); waitText("request-count","1"); XCTAssertTrue(element("source-stop").exists)
    }
    func testThemeReceiptRestartAndFakeLogin() throws {
        launch(); waitLogin(false)
        element("launch-at-login").click(); waitLogin(true)
        element("launch-at-login").click(); waitLogin(false)
        applyAddress(); ready(); element("theme-dark").click(); waitText("selected-theme","Темна")
        let receipt=root.appendingPathComponent("profile/receipt.json")
        let original=try Data(contentsOf:receipt)
        app.terminate(); launch("unavailable"); ready(); waitText("selected-theme","Темна")
        waitText("address","вул. Тестова, 2-А"); waitText("request-count","1")
        XCTAssertEqual(try Data(contentsOf:receipt),original)
    }
}
