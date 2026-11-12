import Foundation
import Darwin

#if !DTEKMONITOR_MAC_TEST_BUILD
#error("This executable requires the isolated test configuration.")
#endif
#if !os(macOS) || !arch(arm64)
#error("This target supports native Apple Silicon macOS only.")
#endif

// Check the complete envelope before output, tests or any mutable application
// state. This console probe never writes settings or calls provider/login APIs.
func validEnvelope(_ environment: [String: String]) -> Bool {
    guard environment["DTEKMONITOR_AUTOSTART_TEST_MODE"] == "1",
          environment["DTEKMONITOR_DISABLE_PROVIDER"] == "1",
          let instance = environment["DTEKMONITOR_TEST_INSTANCE"],
          !instance.isEmpty, instance.utf8.count <= 64,
          instance.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) ||
              (97...122).contains($0) || $0 == 45 || $0 == 95 }),
          let rootPath = environment["DTEKMONITOR_TEST_ROOT"], rootPath.hasPrefix("/"),
          let profilePath = environment["DTEKMONITOR_TEST_PROFILE"], profilePath.hasPrefix("/")
    else { return false }
    let root = URL(fileURLWithPath: rootPath).standardizedFileURL.resolvingSymlinksInPath()
    let profile = URL(fileURLWithPath: profilePath).standardizedFileURL.resolvingSymlinksInPath()
    guard root.path == rootPath, profile.path == profilePath,
          profile.path == root.appendingPathComponent("profile").path else { return false }
    let library = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        .standardizedFileURL.resolvingSymlinksInPath().path
    guard root.path != library, !root.path.hasPrefix(library + "/"),
          !library.hasPrefix(root.path + "/"), root.path != "/" else { return false }
    var directory = ObjCBool(false)
    guard FileManager.default.fileExists(atPath: root.path, isDirectory: &directory), directory.boolValue,
          FileManager.default.fileExists(atPath: profile.path, isDirectory: &directory), directory.boolValue
    else { return false }
    return true
}

guard validEnvelope(ProcessInfo.processInfo.environment) else { exit(64) }
if CommandLine.arguments.count == 2 && CommandLine.arguments[1] == "--restore-data-probe" {
    let totals = DMCoreProbeBridge.runDataRestartTests()
    guard totals["checks"]?.intValue == 5, totals["failures"]?.intValue == 0 else { exit(1) }
    print("RESULT 5/5 Foundation restart checks passed")
    exit(0)
}
if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--session-probe" {
    guard let port = UInt16(CommandLine.arguments[2]), port != 0,
          let root = ProcessInfo.processInfo.environment["DTEKMONITOR_TEST_PROFILE"],
          CommandLine.arguments[3] == root + "/root.der",
          let anchor = try? Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[3])) else { exit(64) }
    Task.detached {
        let passed = await runMonitorSessionTests(port:port, anchor:anchor)
        exit(passed ? 0 : 1)
    }
    dispatchMain()
}
if CommandLine.arguments == [CommandLine.arguments[0], "--login-probe"] {
    Task.detached {
        let passed=await runLoginItemTests()
        exit(passed ? 0 : 1)
    }
    dispatchMain()
}
guard CommandLine.arguments.count == 1 else { exit(64) }
print("SYNTHETIC TEST DATA — NOT A REAL OUTAGE SCHEDULE")
let totals = DMCoreProbeBridge.runPortableTests()
guard totals["checks"]?.intValue == 67, totals["failures"]?.intValue == 0 else { exit(1) }
let scenarios: [(Int64, String, String, Int64?)] = [
    (0, "ready", "Відключення через 1 г", 3600),
    (5400, "ready", "Відновлення через 30 хв", 1800),
    (7200, "schedule_unavailable", "", nil)
]
for (offset, kind, text, seconds) in scenarios {
    let value = DMCoreProbeBridge.evaluateFixture(offsetSeconds: offset)
    guard value["kind"] as? String == kind, value["text"] as? String == text,
          value["synthetic"] as? Bool == true,
          (value["remainingSeconds"] as? NSNumber)?.int64Value == seconds else { exit(1) }
}
print("RESULT 67/67 portable checks; 3 bridge scenarios passed")
let timezoneTotals = DMCoreProbeBridge.runTimezoneTests()
guard timezoneTotals["checks"]?.intValue == 60, timezoneTotals["failures"]?.intValue == 0 else { exit(1) }
print("RESULT 60/60 Kyiv timezone checks passed")
let dataTotals = DMCoreProbeBridge.runDataTests()
guard dataTotals["checks"]?.intValue == 111, dataTotals["failures"]?.intValue == 0 else { exit(1) }
print("RESULT 111/111 Foundation data checks passed")
let lookupTotals = DMCoreProbeBridge.runLookupTests()
guard lookupTotals["checks"]?.intValue == 92, lookupTotals["failures"]?.intValue == 0 else { exit(1) }
print("RESULT 92/92 Foundation lookup checks passed")

let monitorTotals = DMCoreProbeBridge.runMonitorBridgeTests()
guard monitorTotals["checks"]?.intValue == 26, monitorTotals["failures"]?.intValue == 0 else { exit(1) }
print("RESULT 26/26 monitor receipt bridge checks passed")
