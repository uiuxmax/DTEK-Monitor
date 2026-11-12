import Foundation
import Darwin

// Gate on the primary XCTest report, independently of xcodebuild's exit status
// or a shell's errexit behavior. Missing, partial and skipped results fail closed.
struct UISummary: Decodable {
    let failedTests: Int
    let passedTests: Int
    let skippedTests: Int
    let totalTestCount: Int
    let result: String
}

guard CommandLine.arguments.count == 2 else { exit(64) }
do {
    let summary = try JSONDecoder().decode(UISummary.self,
        from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
    guard summary.result == "Passed", summary.failedTests == 0, summary.skippedTests == 0,
          summary.passedTests == 13, summary.totalTestCount == 13 else {
        fputs("XCTest summary rejected: expected 13 passed, zero failed/skipped\n", stderr)
        exit(1)
    }
    print("RESULT 13/13 XCTest cases passed; zero failures or skips")
} catch {
    fputs("Missing or malformed XCTest summary\n", stderr)
    exit(1)
}
