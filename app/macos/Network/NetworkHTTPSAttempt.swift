import Foundation
import Network
import Security
import dnssd
import Darwin

// One TLS/TCP connection, one explicitly constructed HTTP/1.1 GET. No HTTP stack
// exists below the parser to normalize headers, decode bodies or replay requests.
final class NetworkHTTPSAttempt: @unchecked Sendable {
    private let owner = DispatchQueue(label: "local.dtekmonitor.network-attempt")
    private let began = ContinuousClock.now
    private let budget: Int
    private let limit: Int
    private let parser: RawHTTPResponse
    private let completed: (MacHTTPResult) -> Void
    private var result: MacHTTPResult
    private var connection: NWConnection?
    private var deadline: Task<Void, Never>?
    private var terminal = false
    private var delivered = false
    private var connectionStarted = false
    private var cleanupDeadline: Task<Void,Never>?
    private var dnsReference: DNSServiceRef?
    private var dnsContext: UnsafeMutableRawPointer?
    private var dnsCompletion: ((NWEndpoint.Host) -> Void)?
    private var startedHTTP = false
    #if DTEKMONITOR_MAC_TEST_BUILD
    private var testCancelAt = "none"
    private var testCancelDNS = false
    #endif

    deinit { deadline?.cancel(); cleanupDeadline?.cancel(); connection?.cancel() }

    init(token: UInt64, address: String, resource: MacResource, bodyLimit: Int = 2_000_000,
         totalMilliseconds: Int = 30_000, completed: @escaping (MacHTTPResult) -> Void) {
        budget = totalMilliseconds; limit = bodyLimit; parser = RawHTTPResponse(bodyCap: bodyLimit)
        result = MacHTTPResult(token: token, address: address); self.completed = completed
        #if DTEKMONITOR_MAC_TEST_BUILD
        owner.async { self.finish("invalid_request") }
        #else
        guard let path = resource.path else { owner.async { self.finish("invalid_request") }; return }
        resolve(hostname:"app.yasno.ua", port:.https, serverName:"app.yasno.ua", authority:"app.yasno.ua", path:path)
        #endif
    }

    #if DTEKMONITOR_MAC_TEST_BUILD
    init(testPort: UInt16, mismatchHost: Bool, anchorDER: Data?, token: UInt64 = 1,
         bodyLimit: Int = 2_000_000, totalMilliseconds: Int = 2_000,
         testDNS: Bool = false, localhostDNS: Bool = false, cancelAt: String = "none",
         resource: MacResource? = nil, address: String = "synthetic-address",
         resolverMode: String = "normal",
         completed: @escaping (MacHTTPResult) -> Void) {
        budget = totalMilliseconds; limit = bodyLimit; parser = RawHTTPResponse(bodyCap: bodyLimit)
        result = MacHTTPResult(token: token, address: address); self.completed = completed
        guard TestEnvelope.isValid(ProcessInfo.processInfo.environment), testPort != 0,
              anchorDER == nil || anchorDER!.count <= 32_768 else {
            owner.async { self.finish("invalid_request") }; return
        }
        guard ["none", "header", "body"].contains(cancelAt) else { owner.async { self.finish("invalid_request") }; return }
        guard resource == nil || resource?.path != nil else { owner.async { self.finish("invalid_request") }; return }
        testCancelAt = cancelAt
        let name = testDNS ? "dtekmonitor-probe.invalid" : mismatchHost ? "127.0.0.1" : "localhost"
        let endpointHost = testDNS ? name : localhostDNS ? "localhost" : "127.0.0.1"
        let port = NWEndpoint.Port(rawValue:testPort)!
        let path = resource?.path ?? "/probe"
        guard ["normal","first-unreachable","dns-deadline","dns-cancel","real-dns-cancel","ipv6"].contains(resolverMode) else {
            owner.async { self.finish("invalid_request") }; return
        }
        testCancelDNS = resolverMode == "real-dns-cancel"
        if resolverMode != "normal" && !testCancelDNS {
            owner.async {
                guard self.active() else { return }; self.armDeadline()
                if resolverMode == "dns-deadline" { return }
                if resolverMode == "dns-cancel" {
                    // Exercise cancellation before a late simulated resolver
                    // result without depending on two unrelated timer queues.
                    self.cancel()
                    self.owner.async {
                        guard self.active() else { return }
                        self.start(endpoint:.hostPort(host:.ipv4(.loopback),port:port),serverName:name,authority:"\(name):\(testPort)",path:path,anchorDER:anchorDER)
                    }
                    return
                }
                // The first address is deliberately unreachable in this test.
                // Never submit the second candidate to Network.framework.
                let candidates = resolverMode == "ipv6" ? ["::1"] : ["127.0.0.2","127.0.0.1"]
                guard let first=candidates.first, let host=self.numericHost(first) else { self.finish("dns"); return }
                self.start(endpoint:.hostPort(host:host,port:port),serverName:name,authority:"\(name):\(testPort)",path:path,anchorDER:anchorDER)
            }
        } else if testDNS || localhostDNS || testCancelDNS {
            resolve(hostname:endpointHost,port:port,serverName:name,authority:"\(name):\(testPort)",path:path,
                anchorDER:anchorDER,protocols:localhostDNS ? DNSServiceProtocol(kDNSServiceProtocol_IPv4) : 0)
        } else {
            start(endpoint:.hostPort(host:.ipv4(.loopback),port:port),serverName:name,authority:"\(name):\(testPort)",path:path,anchorDER:anchorDER)
        }
    }
    #endif

    private func numericHost(_ name: String) -> NWEndpoint.Host? {
        let host=NWEndpoint.Host(name)
        switch host { case .ipv4, .ipv6: return host; default: return nil }
    }
    // DNS-SD delivers system resolver results on the same serial owner queue.
    // Pick exactly the first address, cancel resolution, then create one numeric
    // connection. A failed address does not trigger fallback to another address.
    private func resolve(hostname: String, port: NWEndpoint.Port, serverName: String,
                         authority: String, path: String, anchorDER: Data? = nil,
                         protocols: DNSServiceProtocol = 0) {
        owner.async {
            guard self.result.token != 0, (1...2_000_000).contains(self.limit), (1...30_000).contains(self.budget) else {
                self.finish("invalid_request"); return
            }
            guard self.active() else { return }; self.armDeadline()
            self.dnsCompletion = { [weak self] host in
                self?.start(endpoint:.hostPort(host:host,port:port),serverName:serverName,authority:authority,path:path,anchorDER:anchorDER)
            }
            // The reference owns this context until cancelDNS; the common deadline
            // also retires stalled queries, so it cannot outlive the attempt.
            let context=Unmanaged.passRetained(self).toOpaque(); self.dnsContext=context
            var reference: DNSServiceRef?
            // Without ReturnIntermediates, DNS-SD suppresses NXDOMAIN and keeps
            // the query alive. Surface that native error within the same budget.
            let flags=DNSServiceFlags(kDNSServiceFlagsTimeout | kDNSServiceFlagsReturnIntermediates)
            let code=DNSServiceGetAddrInfo(&reference,flags,0,protocols,hostname,
                { _, flags, _, error, _, address, _, context in
                    guard let context=context else { return }
                    let attempt=Unmanaged<NetworkHTTPSAttempt>.fromOpaque(context).takeUnretainedValue()
                    attempt.resolved(flags:flags,error:error,address:address)
                },context)
            self.dnsReference=reference
            guard code == kDNSServiceErr_NoError, let reference=reference,
                  DNSServiceSetDispatchQueue(reference,self.owner) == kDNSServiceErr_NoError else { self.finish("dns"); return }
            #if DTEKMONITOR_MAC_TEST_BUILD
            if self.testCancelDNS { self.finish("cancelled") }
            #endif
        }
    }
    private func cancelDNS() {
        if let reference=dnsReference { dnsReference=nil; DNSServiceRefDeallocate(reference) }
        dnsCompletion=nil
        if let context=dnsContext { dnsContext=nil; Unmanaged<NetworkHTTPSAttempt>.fromOpaque(context).release() }
    }
    private func resolved(flags: DNSServiceFlags, error: DNSServiceErrorType, address: UnsafePointer<sockaddr>?) {
        guard active() else { return }
        guard error == kDNSServiceErr_NoError else { finish("dns"); return }
        guard flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0 else { return }
        guard let address=address, [AF_INET,AF_INET6].contains(Int32(address.pointee.sa_family)) else { finish("dns"); return }
        var name=[CChar](repeating:0,count:Int(NI_MAXHOST))
        let capacity=socklen_t(name.count)
        guard getnameinfo(address,socklen_t(address.pointee.sa_len),&name,capacity,nil,0,NI_NUMERICHOST)==0,
              let host=numericHost(String(cString:name)) else { finish("dns"); return }
        let completed=dnsCompletion
        cancelDNS()
        completed?(host)
    }
    private func armDeadline() {
        guard deadline == nil else { return }
        let instant=began.advanced(by:.milliseconds(budget))
        deadline=Task { [weak self] in
            do { try await ContinuousClock().sleep(until:instant) } catch { return }
            self?.owner.async { [weak self] in self?.finish("timeout") }
        }
    }
    private func active() -> Bool {
        guard !terminal else { return false }
        if began.duration(to: ContinuousClock.now) >= .milliseconds(budget) { finish("timeout"); return false }
        return true
    }
    func cancel() { owner.async { self.finish("cancelled") } }
    func revalidateDeadline() { owner.async { _ = self.active() } }
    private func finish(_ error: String) {
        guard !terminal else { return }
        terminal = true
        deadline?.cancel(); deadline = nil
        result.error = error; result.status = parser.status
        result.headers = parser.headers; result.rawHeaderBytes = parser.rawHeaderBytes
        result.diagnostic = parser.diagnostic
        if error == "none" { result.body = parser.body; result.received = Date() }
        else { result.body.removeAll(); result.received = nil }
        cancelDNS()
        guard let connection=connection, connectionStarted else { deliver(clean:true); return }
        connection.cancel()
        // A cancelled state is the final native callback. Deliver only after it,
        // so the serial lookup worker cannot overlap an unretired connection.
        cleanupDeadline=Task { [weak self] in
            do { try await Task.sleep(for:.seconds(1)) } catch { return }
            self?.owner.async { [weak self] in self?.deliver(clean:false) }
        }
    }
    private func deliver(clean: Bool) {
        guard !delivered else { return }; delivered=true
        cleanupDeadline?.cancel(); cleanupDeadline=nil
        connection?.stateUpdateHandler=nil; connection=nil
        result.cleanupFailed = !clean
        if !clean && result.error == "none" { result.error="cleanup"; result.body.removeAll(); result.received=nil }
        completed(result)
    }
    private func kind(_ error: NWError) -> String {
        switch error {
        case .dns: return "dns"
        case .tls: return "tls"
        default: return "connection"
        }
    }
    private func start(endpoint: NWEndpoint, serverName: String, authority: String, path: String,
                       anchorDER: Data? = nil) {
        owner.async {
            guard self.active() else { return }
            guard case .hostPort(let host,_) = endpoint else { self.finish("invalid_request"); return }
            switch host { case .ipv4, .ipv6: break; default: self.finish("invalid_request"); return }
            guard self.result.token != 0, (1...2_000_000).contains(self.limit), (1...30_000).contains(self.budget) else {
                self.finish("invalid_request"); return
            }
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
            serverName.withCString { sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, $0) }
            "http/1.1".withCString { sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, $0) }
            #if DTEKMONITOR_MAC_TEST_BUILD
            // Scope test anchors to this connection's SecTrust. Never install a root.
            let anchor = anchorDER.flatMap { SecCertificateCreateWithData(nil, $0 as CFData) }
            if anchorDER != nil && anchor == nil { self.finish("invalid_request"); return }
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, verify in
                let reference = sec_trust_copy_ref(trust).takeRetainedValue()
                var good = SecTrustSetNetworkFetchAllowed(reference, false) == errSecSuccess
                if let anchor = anchor {
                    good = good && SecTrustSetAnchorCertificates(reference, [anchor] as CFArray) == errSecSuccess
                    good = good && SecTrustSetAnchorCertificatesOnly(reference, true) == errSecSuccess
                }
                good = good && SecTrustSetPolicies(reference, SecPolicyCreateSSL(true, serverName as CFString)) == errSecSuccess
                good = good && SecTrustEvaluateWithError(reference, nil)
                verify(good)
            }, self.owner)
            #endif
            // Normal build retains Network.framework's default chain/hostname verification.
            let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
            parameters.preferNoProxies = true
            parameters.allowFastOpen = false
            guard self.result.connectionAttempts == 0 else { self.finish("invalid_response"); return }
            self.result.connectionAttempts += 1
            let connection = NWConnection(to: endpoint, using: parameters)
            self.connection = connection
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard let self = self else { return }
                if case .cancelled = state, self.terminal { self.deliver(clean:true); return }
                guard self.active() else { return }
                switch state {
                case .ready:
                    guard !self.startedHTTP, let connection = connection else { self.finish("invalid_response"); return }
                    self.startedHTTP = true
                    // Do not label proxy=false without an actual establishment report.
                    connection.requestEstablishmentReport(queue: self.owner) { [weak self] report in
                        guard let self = self, self.active() else { return }
                        guard let report = report else { self.finish("invalid_response"); return }
                        self.result.proxyReported = true; self.result.proxy = report.usedProxy
                        self.result.previousAttempts = Int(report.previousAttemptCount)
                        guard !report.usedProxy, report.previousAttemptCount == 0 else { self.finish("invalid_response"); return }
                        self.send(authority: authority, path: path)
                    }
                case .waiting(let error), .failed(let error): self.finish(self.kind(error))
                case .cancelled: self.finish("cancelled")
                default: break
                }
            }
            self.armDeadline()
            guard self.active() else { return }
            self.connectionStarted=true
            connection.start(queue: self.owner)
        }
    }
    private func send(authority: String, path: String) {
        guard active(), let connection = connection else { return }
        let request = "GET \(path) HTTP/1.1\r\nHost: \(authority)\r\nAccept: application/json\r\nAccept-Encoding: identity\r\nConnection: close\r\n\r\n"
        result.transactions = 1; result.protocols = ["http/1.1"]
        connection.send(content: Data(request.utf8), completion: .contentProcessed { [weak self] error in
            guard let self = self, self.active() else { return }
            if let error = error { self.finish(self.kind(error)); return }
            self.receive()
        })
    }
    private func receive() {
        guard active(), let connection = connection else { return }
        let maximum = parser.nextReadLimit
        connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { [weak self] data, _, eof, error in
            guard let self = self, self.active() else { return }
            if let error = error { self.finish(self.kind(error)); return }
            if let data = data, !data.isEmpty {
                self.result.largestRead = max(self.result.largestRead, data.count)
                guard data.count <= maximum else { self.finish("invalid_response"); return }
                self.result.deliveredBytes += data.count
                self.parser.feed(data)
                if let error = self.parser.error { self.finish(error); return }
                #if DTEKMONITOR_MAC_TEST_BUILD
                if (self.testCancelAt == "header" && self.parser.rawHeaderBytes > 0) ||
                    (self.testCancelAt == "body" && !self.parser.body.isEmpty) {
                    self.cancel(); return
                }
                #endif
            }
            if eof {
                self.finish(self.parser.eof() ? "none" : self.parser.error ?? "incomplete_body")
            } else { self.receive() }
        }
    }
}
