import Foundation
import CryptoKit
import Darwin

struct ProbeManifest: Decodable {
    struct Entry: Decodable { let path: String; let sha256: String }
    let format: String
    let files: [Entry]
}

guard CommandLine.arguments.count == 2 else { exit(64) }
let root = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL.resolvingSymlinksInPath()
guard !FileManager.default.fileExists(atPath: root.appendingPathComponent("tools/preserved-files.json").path)
else { fatalError("Private checkout must retain the 504-file preservation check") }
let manifestURL = root.appendingPathComponent("tools/macos/probe-inputs.json")
let manifest = try JSONDecoder().decode(ProbeManifest.self, from: Data(contentsOf: manifestURL))
guard manifest.format == "dtek-monitor-public-core-probe-v1", !manifest.files.isEmpty,
      manifest.files.count <= 128 else { fatalError("Unexpected probe manifest") }
var paths = Set<String>()
for entry in manifest.files {
    guard paths.insert(entry.path).inserted, !entry.path.hasPrefix("/"),
          !entry.path.split(separator: "/").contains("..") else { fatalError("Invalid source path") }
    let file = root.appendingPathComponent(entry.path).standardizedFileURL.resolvingSymlinksInPath()
    guard file.path.hasPrefix(root.path + "/") else { fatalError("Source escaped the checkout") }
    let data = try Data(contentsOf: file, options: .mappedIfSafe)
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    guard digest == entry.sha256 else { fatalError("Source changed: \(entry.path)") }
}
print("{\"result\":\"PASS\",\"scope\":\"public-synthetic-probe\",\"verified_files\":\(paths.count)}")
