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
        expectation(for:predicate,evaluatedWith:nil); waitForExpectations(timeout:8)
    }
    private func applyAddress() {
        element("edit-address").click()
        element("street").click(); element("street").typeText("вул. Тестова")
        element("house").click(); element("house").typeText("2-А\r")
    }
    private func ready() { XCTAssertTrue(element("interval-510").waitForExistence(timeout:8)) }
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
    }
    func testSuggestionsKeyboardApplyAndLocalTicks() {
        launch(); element("edit-address").click(); element("street").typeText("те")
        XCTAssertTrue(element("suggestion-0").waitForExistence(timeout:8))
        element("street").typeKey(.downArrow,modifierFlags:[]); app.typeKey(.return,modifierFlags:[])
        element("house").typeText("2-А\r"); ready()
        waitText("address","вул. Тестова, 2-А"); waitText("outage-total","3 г 30 хв")
        waitText("request-count","5"); XCTAssertTrue(element("received").exists)
        Thread.sleep(forTimeInterval:1.2); waitText("request-count","5")
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
        let original=pid
        app.windows.firstMatch.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(app.wait(for:.runningBackground,timeout:5)); try reopen()
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
        launch(); XCTAssertEqual(element("launch-at-login").value as? String,"0")
        element("launch-at-login").click(); XCTAssertEqual(element("launch-at-login").value as? String,"1")
        element("launch-at-login").click(); XCTAssertEqual(element("launch-at-login").value as? String,"0")
        applyAddress(); ready(); element("theme-dark").click(); waitText("selected-theme","Темна")
        let receipt=root.appendingPathComponent("profile/receipt.json")
        let original=try Data(contentsOf:receipt)
        app.terminate(); launch("unavailable"); ready(); waitText("selected-theme","Темна")
        waitText("address","вул. Тестова, 2-А"); waitText("request-count","1")
        XCTAssertEqual(try Data(contentsOf:receipt),original)
    }
}
