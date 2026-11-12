import Foundation

final class MonitorReplyBox: @unchecked Sendable {
    let value: DMLookupReply
    let requests: Int
    init(_ value: DMLookupReply, requests: Int) { self.value = value; self.requests = requests }
}

enum MonitorTransportMode: Sendable {
    case native
    #if DTEKMONITOR_MAC_TEST_BUILD
    case synthetic(String)
    case loopback(UInt16, Data)
    #endif
}

// One shared serial queue owns synchronous lookup chains. Each active native
// attempt has its own serial queue; cancellation never waits on the UI thread.
final class NativeLookupWorker: @unchecked Sendable {
    private let sourceGate=MonitorSourceGate()
    private let queue = DispatchQueue(label: "local.dtekmonitor.lookup-worker", autoreleaseFrequency: .workItem)
    func start(ticket: MacSessionPolicy.Ticket, street: String, house: String, mode: MonitorTransportMode,
               epoch: @escaping @Sendable () -> Int64, completed: @escaping @Sendable (MonitorReplyBox) -> Void) -> MonitorWork {
        let work = MonitorWork(ticket: ticket, street: street, house: house, mode: mode, epoch: epoch, sourceGate:sourceGate)
        queue.async { let reply = work.run(); completed(MonitorReplyBox(reply, requests: work.requests)) }
        return work
    }
}

final class MonitorWork: @unchecked Sendable {
    private let sourceGate: MonitorSourceGate
    private let operation: DMLookupOperation
    private let ticket: MacSessionPolicy.Ticket
    private let street: String
    private let house: String
    private let mode: MonitorTransportMode
    private let epoch: @Sendable () -> Int64
    private let lock = NSLock()
    private var stopped = false
    private var attempt: NetworkHTTPSAttempt?
    private var began: ContinuousClock.Instant?
    private var budget = 30_000
    private var requestCount = 0
    var requests: Int { lock.lock(); defer { lock.unlock() }; return requestCount }

    fileprivate init(ticket: MacSessionPolicy.Ticket, street: String, house: String, mode: MonitorTransportMode,
         epoch: @escaping @Sendable () -> Int64, sourceGate: MonitorSourceGate) {
        self.sourceGate=sourceGate
        self.ticket = ticket; self.street = street; self.house = house; self.mode = mode; self.epoch = epoch
        operation = DMLookupOperation(street: street, house: house, token: ticket.generation, suggestions: ticket.kind == .suggestions)
    }
    func cancel() {
        lock.lock(); stopped = true; let current = attempt; lock.unlock()
        operation.cancel(); current?.cancel()
    }
    func revalidateDeadline() -> Bool {
        lock.lock(); let current = attempt; let start = began; let milliseconds = budget; lock.unlock()
        let expired = start.map { $0.duration(to: .now) >= .milliseconds(milliseconds) } ?? false
        if expired { cancel() } else { current?.revalidateDeadline() }
        return expired
    }
    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func run() -> DMLookupReply {
        operation.perform { [self] request in get(request) }
    }
    private func failure(_ request: [String: Any], _ error: String) -> [String: Any] {
        ["token": request["token"] ?? NSNumber(value: ticket.generation), "error": error,
         "status": 0, "mime": "", "body": Data(), "received": NSNull()]
    }
    private func get(_ request: [String:Any]) -> [String:Any] {
        if let status=sourceGate.status {
            var value=failure(request,"http"); value["status"]=status; return value
        }
        let value=performGet(request)
        sourceGate.observe((value["status"] as? NSNumber)?.intValue ?? 0)
        return value
    }
    private func performGet(_ request: [String: Any]) -> [String: Any] {
        guard !isStopped else { return failure(request, "cancelled") }
        lock.lock(); requestCount += 1; lock.unlock()
        #if DTEKMONITOR_MAC_TEST_BUILD
        if case .synthetic(let scenario) = mode { return synthetic(request, scenario: scenario) }
        #endif
        guard let kind = request["kind"] as? String, let query = request["query"] as? String,
              let streetID = request["streetID"] as? String, let houseID = request["houseID"] as? String,
              let token = request["token"] as? NSNumber, let cap = request["bodyLimit"] as? NSNumber,
              let timeout = request["timeoutMS"] as? NSNumber else { return failure(request,"invalid_request") }
        guard token.uint64Value == ticket.generation, (1...2_000_000).contains(cap.intValue),
              (1...30_000).contains(timeout.intValue) else { return failure(request,"invalid_request") }
        let resource: MacResource
        switch kind {
        case "streets": resource = .streets(query)
        case "houses": resource = .houses(streetID, query)
        case "group": resource = .group(streetID, houseID)
        case "planned": resource = .planned
        default: return failure(request,"invalid_request")
        }
        let completed = DispatchSemaphore(value: 0)
        let box = WorkerResultBox()
        let origin = ContinuousClock.now
        let completion: (MacHTTPResult) -> Void = { value in box.store(value); completed.signal() }
        let native: NetworkHTTPSAttempt
        #if DTEKMONITOR_MAC_TEST_BUILD
        if case .loopback(let port, let anchor) = mode {
            native = NetworkHTTPSAttempt(testPort:port,mismatchHost:false,anchorDER:anchor,token:token.uint64Value,
                bodyLimit:cap.intValue,totalMilliseconds:timeout.intValue,resource:resource,address:ticket.selection,completed:completion)
        } else {
            native = NetworkHTTPSAttempt(token: token.uint64Value, address: ticket.selection, resource: resource,
                bodyLimit: cap.intValue, totalMilliseconds: timeout.intValue, completed:completion)
        }
        #else
        native = NetworkHTTPSAttempt(token: token.uint64Value, address: ticket.selection, resource: resource,
            bodyLimit: cap.intValue, totalMilliseconds: timeout.intValue, completed:completion)
        #endif
        lock.lock(); attempt = native; began = origin; budget = timeout.intValue; let cancelNow = stopped; lock.unlock()
        if cancelNow { native.cancel() }
        defer { lock.lock(); attempt = nil; began = nil; lock.unlock() }
        var cancellationSent=cancelNow
        while completed.wait(timeout: .now() + .milliseconds(100)) != .success {
            if isStopped && !cancellationSent { cancellationSent=true; native.cancel() }
            // Network deadline remains unchanged; this grace only lets native
            // cancellation/its bounded cleanup report finish before next work.
            if origin.duration(to: .now) >= .milliseconds(timeout.intValue + 2000) {
                native.cancel(); return failure(request,isStopped ? "cancelled" : "timeout")
            }
        }
        guard let result = box.load(), result.token == ticket.generation, result.address == ticket.selection else {
            return failure(request,"invalid_response")
        }
        var output: [String: Any] = ["token": NSNumber(value: result.token), "error": result.error,
            "status": result.status, "cleanupFailed":result.cleanupFailed, "mime": result.headers["content-type"] ?? "", "body": result.body, "received": NSNull()]
        if let received = result.received { output["received"] = NSNumber(value: floor(received.timeIntervalSince1970)) }
        return output
    }
    #if DTEKMONITOR_MAC_TEST_BUILD
    private func synthetic(_ request: [String: Any], scenario: String) -> [String: Any] {
        let now = epoch()
        var output: [String: Any] = ["token":request["token"] ?? NSNumber(value: ticket.generation),
            "error":"none","status":200,"mime":"application/json","received":NSNumber(value:now)]
        if scenario == "403" || scenario == "429" {
            output["status"] = Int(scenario)!; output["error"] = "http"; output["body"] = Data(); output["received"] = NSNull()
            return output
        }
        if scenario == "unavailable" { return failure(request,"connection") }
        let body: Any
        switch request["kind"] as? String {
        case "streets": body = [["id":101,"value":ticket.kind == .suggestions ? "вул. Тестова" : street]]
        case "houses": body = [["id":201,"value":house]]
        case "group": body = ["group":2,"subgroup":1]
        default:
            var calendar = Calendar(identifier: .gregorian)
            guard let zone = TimeZone(identifier:"Europe/Kyiv") else { return failure(request,"invalid_response") }
            calendar.timeZone = zone
            let date = Date(timeIntervalSince1970:Double(now))
            let today = calendar.startOfDay(for:date)
            guard let tomorrow = calendar.date(byAdding:.day,value:1,to:today) else { return failure(request,"invalid_response") }
            let format = ISO8601DateFormatter(); format.timeZone = zone; format.formatOptions = [.withInternetDateTime]
            let slots: [[String: Any]] = [["start":0,"end":510,"type":"NotPlanned"],
                ["start":510,"end":720,"type":"Definite"],["start":720,"end":1440,"type":"NotPlanned"]]
            let emergency = scenario == "emergency"
            let next = scenario == "tomorrow"
            body = ["2.1":["updatedOn":format.string(from:date.addingTimeInterval(-300)),
                "today":["date":format.string(from:today),"status":emergency ? "EmergencyShutdowns" : "ScheduleApplies","slots":emergency ? [] : slots],
                "tomorrow":["date":format.string(from:tomorrow),"status":next ? "ScheduleApplies" : "WaitingForSchedule","slots":next ? slots : []]]]
        }
        guard let data = try? JSONSerialization.data(withJSONObject:body,options:[.sortedKeys]) else { return failure(request,"invalid_response") }
        output["body"] = data
        return output
    }
    #endif
}

private final class WorkerResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: MacHTTPResult?
    func store(_ result: MacHTTPResult) { lock.lock(); value = result; lock.unlock() }
    func load() -> MacHTTPResult? { lock.lock(); defer { lock.unlock() }; return value }
}

// Shared by all work items of one session. Latch before notifying the actor,
// so an already queued replacement cannot race a source-wide stop callback.
fileprivate final class MonitorSourceGate: @unchecked Sendable {
    private let lock=NSLock()
    private var value: Int?
    var status: Int? { lock.lock(); defer { lock.unlock() }; return value }
    func observe(_ status: Int) {
        guard status==403 || status==429 else { return }
        lock.lock(); if value==nil { value=status }; lock.unlock()
    }
}
