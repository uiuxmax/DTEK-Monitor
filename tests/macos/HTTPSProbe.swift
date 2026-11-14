import Foundation
import Darwin

#if !DTEKMONITOR_MAC_TEST_BUILD || !os(macOS) || !arch(arm64)
#error("Native protected Apple Silicon probe required")
#endif

#if DTEKMONITOR_NETWORK_CANDIDATE
typealias ProbeAttempt = NetworkHTTPSAttempt
#else
typealias ProbeAttempt = MacHTTPSAttempt
#endif

@main enum HTTPSProbe {
    static func main() throws {
        let env = ProcessInfo.processInfo.environment
        guard TestEnvelope.isValid(env) else { exit(64) }
        #if DTEKMONITOR_NETWORK_CANDIDATE
        if CommandLine.arguments == [CommandLine.arguments[0], "--parser"] {
            try runRawHTTPTests()
            return
        }
        if CommandLine.arguments == [CommandLine.arguments[0], "--lifecycle"] {
            try runSessionPolicyTests()
            return
        }
        #endif
        if CommandLine.arguments == [CommandLine.arguments[0], "--resources"] {
            let base = "/api/blackout-service/public/shutdowns/addresses/v2/"
            let vectors: [(MacResource, String?)] = [
                (.planned, "/api/blackout-service/public/shutdowns/regions/25/dsos/902/planned-outages"),
                (.streets("Те"), base + "streets?regionId=25&query=%D0%A2%D0%B5&dsoId=902"),
                (.streets("a&query=/"), base + "streets?regionId=25&query=a%26query%3D%2F&dsoId=902"),
                (.houses("101", "2-А"), base + "houses?regionId=25&streetId=101&query=2-%D0%90&dsoId=902"),
                (.group("101", "201"), base + "group?regionId=25&streetId=101&houseId=201&dsoId=902"),
                (.streets(""), nil), (.streets("a\n"), nil), (.streets("a\u{0085}"), nil),
                (.streets(String(repeating: "a", count: 257)), nil),
                (.houses("01", "2"), nil), (.houses("0", "2"), nil), (.houses("../", "2"), nil),
                (.group("101", ""), nil), (.group("101", "201&x=2"), nil),
                (.group("101", "12345678901"), nil)
            ]
            guard vectors.allSatisfy({ $0.0.path == $0.1 }) else { exit(1) }
            let done = DispatchSemaphore(value: 0)
            let protected = ProbeAttempt(token: 1, address: "synthetic", resource: .planned) { result in
                guard result.error == "invalid_request", result.body.isEmpty, result.received == nil else { exit(1) }
                done.signal()
            }
            guard done.wait(timeout: .now() + .seconds(2)) == .success else { exit(1) }
            withExtendedLifetime(protected) {}
            print("RESULT 16/16 resource and provider-guard checks passed")
            return
        }
        guard CommandLine.arguments.count == 5,
              let port = UInt16(CommandLine.arguments[1]), port != 0,
              let milliseconds = Int(CommandLine.arguments[3]), (1...30_000).contains(milliseconds),
              ["trusted", "untrusted", "mismatch", "cancel", "dns", "hostname-dns", "cancel-header", "cancel-body",
               "first-unreachable", "dns-deadline", "dns-cancel", "real-dns-cancel", "ipv6"].contains(CommandLine.arguments[2]),
              let profile = env["DTEKMONITOR_TEST_PROFILE"] else { exit(64) }
        let certificate = URL(fileURLWithPath: profile).appendingPathComponent("root.der")
        guard certificate.resolvingSymlinksInPath().path == certificate.path else { exit(64) }
        let data = try Data(contentsOf: certificate)
        guard data.count <= 32_768 else { exit(64) }
        let mode = CommandLine.arguments[2]
        let lock = NSLock()
        let done = DispatchSemaphore(value: 0)
        var value: MacHTTPResult?
        var deliveries = 0
        let began = ContinuousClock.now
        let completion: (MacHTTPResult) -> Void = { result in
            lock.lock(); deliveries += 1; value = result; lock.unlock(); done.signal()
        }
        #if DTEKMONITOR_NETWORK_CANDIDATE
        let attempt = ProbeAttempt(testPort: port, mismatchHost: mode == "mismatch",
            anchorDER: mode == "untrusted" ? nil : data, totalMilliseconds: milliseconds,
            testDNS: mode == "dns", localhostDNS: mode == "hostname-dns",
            cancelAt: mode == "cancel-header" ? "header" : mode == "cancel-body" ? "body" : "none",
            resolverMode: ["first-unreachable","dns-deadline","dns-cancel","real-dns-cancel","ipv6"].contains(mode) ? mode : "normal",
            completed: completion)
        #else
        guard ["trusted", "untrusted", "mismatch", "cancel"].contains(mode) else { exit(64) }
        let attempt = ProbeAttempt(testPort: port, mismatchHost: mode == "mismatch",
            anchorDER: mode == "untrusted" ? nil : data, totalMilliseconds: milliseconds) { result in
                completion(result)
            }
        #endif
        if mode == "cancel" { DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(100)) { attempt.cancel() } }
        guard done.wait(timeout: .now() + .seconds(35)) == .success else { exit(1) }
        // Force cancellation and callbacks after termination; there must be no second delivery.
        attempt.cancel(); attempt.revalidateDeadline()
        Thread.sleep(forTimeInterval: 0.15)
        lock.lock()
        guard let result = value, deliveries == 1 else { lock.unlock(); exit(1) }
        lock.unlock()
        let duration = began.duration(to: .now).components
        let output: [String: Any] = ["token": result.token, "address": result.address,
            "error": result.error, "status": result.status, "bodyBytes": result.body.count,
            "bodyBase64": result.body.base64EncodedString(), "received": result.received != nil,
            "headers": result.headers, "transactions": result.transactions, "proxy": result.proxy,
            "protocols": result.protocols, "deliveredBytes": result.deliveredBytes,
            "proxyReported": result.proxyReported, "rawHeaderBytes": result.rawHeaderBytes,
            "largestRead": result.largestRead, "diagnostic": result.diagnostic,
            "previousAttempts": result.previousAttempts,
            "connectionAttempts":result.connectionAttempts,"cleanupFailed":result.cleanupFailed,
            "deliveries": deliveries, "elapsedMs": Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15]
        let destination = URL(fileURLWithPath: CommandLine.arguments[4]).standardizedFileURL
        guard destination.path.hasPrefix(profile + "/"), destination.path == destination.resolvingSymlinksInPath().path,
              !FileManager.default.fileExists(atPath: destination.path) else { exit(64) }
        try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]).write(to: destination, options: .withoutOverwriting)
    }
}
