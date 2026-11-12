import Foundation
import Security
import Darwin

// Candidate M5 transport. Not wired to the widget until native contract acceptance.
enum MacResource {
    case streets(String), houses(String, String), group(String, String), planned
    var path: String? {
        func id(_ value: String) -> Bool {
            !value.isEmpty && value.utf8.count <= 10 && value.first != "0" &&
                value.utf8.allSatisfy { (48...57).contains($0) }
        }
        func query(_ value: String) -> String? {
            guard !value.isEmpty, value.utf8.count <= 256,
                  value.unicodeScalars.allSatisfy({ $0.value > 31 && !((127...159).contains($0.value)) }) else { return nil }
            return value.utf8.map { byte in
                if (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) ||
                    [45, 46, 95, 126].contains(byte) { return String(UnicodeScalar(byte)) }
                return String(format: "%%%02X", byte)
            }.joined()
        }
        let base = "/api/blackout-service/public/shutdowns/addresses/v2/"
        switch self {
        case .planned: return "/api/blackout-service/public/shutdowns/regions/25/dsos/902/planned-outages"
        case .streets(let text):
            guard let encoded = query(text) else { return nil }
            return base + "streets?regionId=25&query=" + encoded + "&dsoId=902"
        case .houses(let street, let text):
            guard id(street), let encoded = query(text) else { return nil }
            return base + "houses?regionId=25&streetId=" + street + "&query=" + encoded + "&dsoId=902"
        case .group(let street, let house):
            guard id(street), id(house) else { return nil }
            return base + "group?regionId=25&streetId=" + street + "&houseId=" + house + "&dsoId=902"
        }
    }
}

struct MacHTTPResult {
    let token: UInt64
    let address: String
    var error = "none"
    var status = 0
    var body = Data()
    var received: Date?
    var headers: [String: String] = [:]
    var transactions = 0
    var proxy = false
    var protocols: [String] = []
    var deliveredBytes = 0
    // Network.framework evidence; false means proxy state has not been measured.
    var proxyReported = false
    var rawHeaderBytes = 0
    var largestRead = 0
    var diagnostic = ""
    var previousAttempts = -1 // Unknown until an establishment report exists.
}

final class MacHTTPSAttempt: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let owner = DispatchQueue(label: "local.dtekmonitor.https-attempt")
    private let clock = ContinuousClock()
    private let began = ContinuousClock.now
    private let limit: Int
    private let budget: Int
    private var result: MacHTTPResult
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var deadline: Task<Void, Never>?
    private var terminal = false
    private var acceptedHeaders = false
    private var length: Int?
    private let completed: (MacHTTPResult) -> Void
    #if DTEKMONITOR_MAC_TEST_BUILD
    private var anchor: SecCertificate?
    #endif

    init(token: UInt64, address: String, resource: MacResource, bodyLimit: Int = 2_000_000,
         totalMilliseconds: Int = 30_000, completed: @escaping (MacHTTPResult) -> Void) {
        self.limit = bodyLimit; self.budget = totalMilliseconds
        self.result = MacHTTPResult(token: token, address: address)
        self.completed = completed
        super.init()
        #if DTEKMONITOR_MAC_TEST_BUILD
        // Protected builds may never use the provider endpoint, even with a valid resource.
        owner.async { self.finish("invalid_request") }
        #else
        guard let path = resource.path, let url = URL(string: "https://app.yasno.ua" + path) else {
            owner.async { self.finish("invalid_request") }; return
        }
        start(url)
        #endif
    }

    #if DTEKMONITOR_MAC_TEST_BUILD
    // Only the native test executable can construct this endpoint. No arbitrary host/path.
    init(testPort: UInt16, mismatchHost: Bool, anchorDER: Data?, token: UInt64 = 1,
         bodyLimit: Int = 2_000_000, totalMilliseconds: Int = 2_000,
         completed: @escaping (MacHTTPResult) -> Void) {
        self.limit = bodyLimit; self.budget = totalMilliseconds
        self.result = MacHTTPResult(token: token, address: "synthetic-address")
        self.completed = completed
        self.anchor = anchorDER.flatMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        super.init()
        let env = ProcessInfo.processInfo.environment
        guard TestEnvelope.isValid(env),
              let url = URL(string: "https://\(mismatchHost ? "127.0.0.1" : "localhost"):\(testPort)/probe") else {
            owner.async { self.finish("invalid_request") }; return
        }
        start(url)
    }
    #endif

    private func start(_ url: URL) {
        owner.async {
            guard self.result.token != 0, (1...2_000_000).contains(self.limit), (1...30_000).contains(self.budget) else {
                self.finish("invalid_request"); return
            }
            let config = URLSessionConfiguration.ephemeral
            config.httpShouldSetCookies = false
            config.httpCookieAcceptPolicy = .never
            config.httpCookieStorage = nil
            config.urlCache = nil
            config.urlCredentialStorage = nil
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.connectionProxyDictionary = [:]
            config.waitsForConnectivity = false
            config.httpMaximumConnectionsPerHost = 1
            config.timeoutIntervalForRequest = Double(self.budget) / 1000
            config.timeoutIntervalForResource = Double(self.budget) / 1000
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            queue.underlyingQueue = self.owner
            self.session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            self.task = self.session!.dataTask(with: request)
            let instant = self.began.advanced(by: .milliseconds(self.budget))
            self.deadline = Task { [weak self] in
                do { try await ContinuousClock().sleep(until: instant) } catch { return }
                self?.owner.async { [weak self] in self?.finish("timeout") }
            }
            guard self.active() else { return }
            self.task!.resume()
        }
    }
    private func active() -> Bool {
        guard !terminal else { return false }
        if began.duration(to: clock.now) >= .milliseconds(budget) { finish("timeout"); return false }
        return true
    }
    func cancel() { owner.async { self.finish("cancelled") } }
    // Wake/clock notifications are serialized here; ContinuousClock includes sleep.
    func revalidateDeadline() { owner.async { _ = self.active() } }
    private func finish(_ error: String) {
        guard !terminal else { return }
        terminal = true
        result.error = error
        if error != "none" { result.body.removeAll(); result.received = nil }
        deadline?.cancel(); deadline = nil
        session?.invalidateAndCancel()
        completed(result)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
        guard active() else { return }
        result.status = response.statusCode
        finish("http")
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard active() else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil); finish("http"); return
        }
        #if DTEKMONITOR_MAC_TEST_BUILD
        guard let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil); finish("tls"); return
        }
        var good = SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess
        if let anchor = anchor {
            good = good && SecTrustSetAnchorCertificates(trust, [anchor] as CFArray) == errSecSuccess
            good = good && SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess
        }
        good = good && SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, challenge.protectionSpace.host as CFString)) == errSecSuccess
        good = good && SecTrustEvaluateWithError(trust, nil)
        completionHandler(good ? .useCredential : .cancelAuthenticationChallenge, good ? URLCredential(trust: trust) : nil)
        if !good { finish("tls") }
        #else
        // Retain platform certificate-chain and hostname verification.
        completionHandler(.performDefaultHandling, nil)
        #endif
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard active(), !acceptedHeaders, let http = response as? HTTPURLResponse else {
            completionHandler(.cancel); if !terminal { finish("invalid_response") }; return
        }
        result.status = http.statusCode
        for (name, value) in http.allHeaderFields { result.headers[String(describing: name).lowercased()] = String(describing: value) }
        guard http.statusCode == 200 else { completionHandler(.cancel); finish("http"); return }
        let mime = result.headers["content-type"] ?? ""
        let encoding = result.headers["content-encoding"] ?? ""
        // This is a post-allocation bound: URLSession does not expose raw header reads.
        let size = result.headers.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count + 4 }
        guard size <= 65_536, mime.utf8.count <= 256,
              mime.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json",
              encoding.isEmpty || encoding == "identity" else {
            completionHandler(.cancel); finish("invalid_response"); return
        }
        if let raw = result.headers["content-length"] {
            guard !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }), let count = Int(raw) else {
                completionHandler(.cancel); finish("invalid_response"); return
            }
            guard count <= limit else { completionHandler(.cancel); finish("body_too_large"); return }
            length = count
        }
        guard result.headers["transfer-encoding"] == nil || length == nil else {
            completionHandler(.cancel); finish("invalid_response"); return
        }
        acceptedHeaders = true
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard active() else { return }
        result.deliveredBytes += data.count
        guard data.count <= limit - result.body.count else { finish("body_too_large"); return }
        if let length = length, data.count > length - result.body.count { finish("invalid_response"); return }
        result.body.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard !terminal else { return }
        result.transactions = metrics.transactionMetrics.count
        result.proxy = metrics.transactionMetrics.contains { $0.isProxyConnection }
        result.protocols = metrics.transactionMetrics.compactMap { $0.networkProtocolName }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard active() else { return }
        if let error = error as NSError? {
            let kind: String
            switch error.code {
            case NSURLErrorTimedOut: kind = "timeout"
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: kind = "dns"
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
                 NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateHasUnknownRoot,
                 NSURLErrorServerCertificateNotYetValid: kind = "tls"
            case NSURLErrorCancelled: kind = "cancelled"
            default: kind = "connection"
            }
            finish(kind); return
        }
        guard acceptedHeaders, !result.body.isEmpty, length == nil || length == result.body.count else {
            finish("incomplete_body"); return
        }
        result.received = Date()
        finish("none")
    }
}
