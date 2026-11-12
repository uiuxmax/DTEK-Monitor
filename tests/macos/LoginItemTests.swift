import Foundation

#if !DTEKMONITOR_MAC_TEST_BUILD
#error("Login tests require the fake-only protected build")
#endif

@MainActor func runLoginItemTests() -> Bool {
    var checks=0, failures=0
    func check(_ name: String,_ passed: Bool) {
        checks += 1; if !passed { failures += 1 }
        print("\(passed ? "PASS" : "FAIL") Login Item: \(name)")
    }
    let backend=FakeLoginItemBackend()
    let model=LoginItemModel(backend:backend)
    check("default off and no registration at init",!model.checked && backend.registrations==0)
    let value=model
    value.refresh(); value.refresh()
    check("refresh never registers",backend.registrations==0 && backend.unregistrations==0)
    value.requestEnabled(true)
    check("user opt-in reflects actual enabled status",value.checked && backend.registrations==1)
    value.requestEnabled(true)
    check("already enabled is not re-registered",backend.registrations==1)
    value.requestEnabled(false)
    check("user opt-out unregisters",!value.checked && backend.unregistrations==1)
    backend.registeredStatus = .requiresApproval; value.requestEnabled(true)
    check("pending approval is not a checkmark",value.status == .requiresApproval && !value.checked)
    let calls=backend.registrations
    value.requestEnabled(true)
    check("approval cannot be bypassed by retry",backend.registrations==calls && value.message != nil)
    value.openSettings()
    check("settings opens only after explicit action",backend.settingsOpened==1)
    value.requestEnabled(false)
    check("pending registration can be removed",backend.unregistrations==2 && value.status == .notRegistered)
    backend.status = .enabled; value.refresh(); backend.status = .requiresApproval; value.refresh()
    check("external system disable removes the checkmark",!value.checked && value.status == .requiresApproval && backend.registrations==calls)
    backend.status = .notFound; value.refresh(); value.requestEnabled(true)
    check("notFound blocks mutation",!value.canChange && !value.checked && backend.registrations==calls)
    backend.status = .unknown; value.refresh(); value.requestEnabled(true)
    check("unknown blocks mutation",!value.canChange && !value.checked && backend.registrations==calls)
    backend.status = .notRegistered; backend.failRegister=true; value.requestEnabled(true)
    check("failed register keeps actual unchecked state",!value.checked && value.message != nil)
    backend.status = .enabled; backend.failUnregister=true; value.requestEnabled(false)
    check("failed unregister preserves actual enabled state",value.checked && value.message != nil)
    print("RESULT \(checks-failures)/\(checks) fake Login Item checks passed")
    return checks==14 && failures==0
}
