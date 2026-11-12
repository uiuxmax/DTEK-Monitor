import Foundation

// The UI target has its own guard so the already verified M1 probe stays intact.
// No settings, login backend or provider is created by this development app.
enum TestEnvelope {
    static func isValid(_ environment: [String: String]) -> Bool {
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
        guard root.path != "/", root.path != library, !root.path.hasPrefix(library + "/"),
              !library.hasPrefix(root.path + "/") else { return false }
        var directory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: root.path, isDirectory: &directory) && directory.boolValue &&
            FileManager.default.fileExists(atPath: profile.path, isDirectory: &directory) && directory.boolValue
    }
}
