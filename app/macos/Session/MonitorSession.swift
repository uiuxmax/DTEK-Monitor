import Foundation

private enum MonitorEvent: Int { case startup, addressApplied, lookupOK, lookupFailed, sourceStopped, wake, clockChanged, themeChanged, shutdown }

struct MonitorMoment: Sendable { let milliseconds: Int64; let epoch: Int64 }
struct MonitorClock: Sendable {
    private let elapsed = MacContinuousMilliseconds()
    private let fixedEpoch: Int64?
    init(fixedEpoch: Int64? = nil) { self.fixedEpoch = fixedEpoch }
    func read() -> MonitorMoment? {
        guard let milliseconds = elapsed.now() else { return nil }
        let epoch: Int64
        if let base = fixedEpoch {
            let next = base.addingReportingOverflow(milliseconds / 1000)
            guard !next.overflow else { return nil }
            epoch = next.partialValue
        } else {
            let seconds = floor(Date().timeIntervalSince1970)
            guard seconds.isFinite, seconds >= -11644473600, seconds <= 253402300799 else { return nil }
            epoch = Int64(seconds)
        }
        return MonitorMoment(milliseconds: milliseconds, epoch: epoch)
    }
}

struct MonitorSnapshot: Sendable {
    struct Row: Sendable { let start: Int; let end: Int; let power: Bool }
    let sequence: UInt64
    let street: String
    let house: String
    let address: String
    let theme: String
    let forecast: Bool
    let emergency: Bool
    let tomorrow: Bool
    let tomorrowAvailable: Bool
    let countdown: String
    let rows: [Row]
    let suggestions: [String]
    let suggestionResult: String?
    let suggestionKind: String?
    let suggestionInput: String?
    let totalOutageMinutes: Int
    let received: Int64?
    let editing: Bool
    let loading: Bool
    let stopped: Bool
    let storageWarning: Bool
    let floatingVisible: Bool
    let floatingPositioned: Bool
    let floatingX: Int
    let floatingY: Int
    let floatingSize: Int
    let failure: String?
    let requestCount: Int
}

// The only mutable owner of profile/receipt/policy state. UI receives value
// snapshots; the separate worker queue owns blocking lookup chains.
actor MonitorSession {
    private let profile: String
    private var engine: DMMonitorEngine?
    private let worker = NativeLookupWorker()
    private let clock: MonitorClock
    private let mode: MonitorTransportMode
    private let publish: @Sendable (MonitorSnapshot) -> Void
    private var policy = MacSessionPolicy()
    private var active: (MacSessionPolicy.Ticket, MonitorWork)?
    private var sequence: UInt64 = 0
    private var completedRequests = 0
    private var started = false
    private var lastFailure: String?
    private var street = "", house = ""
    private var suggestions: [String] = []
    private var suggestionResult: String?
    private var suggestionKind: String?
    private var suggestionInput: String?

    init(profile: String, clock: MonitorClock, mode: MonitorTransportMode,
         publish: @escaping @Sendable (MonitorSnapshot) -> Void) {
        self.profile=profile; self.clock = clock; self.mode = mode; self.publish = publish
    }
    func start() {
        guard !started, !policy.closed else { return }
        let engine=DMMonitorEngine(profile:profile,epoch:clock.read()?.epoch ?? 0)
        self.engine=engine
        started = true
        record(.startup)
        let value = engine.snapshot(epoch: clock.read()?.epoch ?? 0)
        street = value["street"] as? String ?? ""; house = value["house"] as? String ?? ""
        _ = policy.selectAddress(street.isEmpty || house.isEmpty ? nil : key(street,house))
        tick()
    }
    private func record(_ event: MonitorEvent,status: Int = 0,reason: Int = 0,epoch: Int64? = nil) {
        guard let engine=engine else { return }
        _ = engine.record(event:event.rawValue,status:status,reason:reason,epoch:epoch ?? clock.read()?.epoch ?? 0)
    }
    private func key(_ street: String, _ house: String) -> String { street + "\n" + house }
    private func cancel(_ ticket: MacSessionPolicy.Ticket?) {
        if let ticket = ticket, active?.0 == ticket { active?.1.cancel(); active = nil }
    }
    private func execute(_ action: MacSessionPolicy.Action) {
        cancel(action.cancel)
        guard let ticket = action.start else { return }
        let clock = self.clock
        let parts = ticket.kind == .houseSuggestions ? ticket.selection.split(separator:"\n",maxSplits:1).map(String.init) : []
        let requestStreet = ticket.kind == .suggestions ? ticket.selection : ticket.kind == .houseSuggestions ? (parts.first ?? "") : street
        let requestHouse = ticket.kind == .suggestions ? "" : ticket.kind == .houseSuggestions ? (parts.count == 2 ? parts[1] : "") : house
        let work = worker.start(ticket:ticket,street:requestStreet,house:requestHouse,mode:mode,
            epoch:{ clock.read()?.epoch ?? 0 }) { [weak self] reply in
                Task { await self?.received(ticket, reply: reply) }
            }
        active = (ticket,work)
    }
    func tick(wake: Bool = false, clockChanged: Bool = false) {
        guard started, !policy.closed, let engine=engine else { return }
        guard let now = clock.read() else {
            execute(policy.tick(nowMS:-1,kyivDay:nil)); emit(epoch:0); return
        }
        if wake || clockChanged { record(clockChanged ? .clockChanged : .wake,epoch:now.epoch) }
        let snapshot = engine.snapshot(epoch:now.epoch)
        let day = snapshot["kyivDay"] as? String
        let expired = wake ? active?.1.revalidateDeadline() ?? false : false
        execute(policy.tick(nowMS:now.milliseconds,kyivDay:day,attemptExpired:expired))
        emit(epoch:now.epoch)
    }
    func editStreet(_ input: String?) {
        guard started, !policy.closed else { return }
        let now = clock.read()
        let query = input.flatMap { DMMonitorEngine.streetQuery($0) }
        cancel(policy.editStreetQuery(query,nowMS:now?.milliseconds ?? -1))
        suggestions = []
        suggestionResult = nil
        suggestionKind = "street"
        suggestionInput = input
        emit(epoch:now?.epoch ?? 0)
    }
    func editHouse(street: String, house: String) {
        guard started, !policy.closed else { return }
        let now = clock.read()
        let normalized = DMMonitorEngine.normalize(street:street,house:house)
        let query = normalized.flatMap { value -> String? in
            guard let street=value["street"], let house=value["house"] else { return nil }
            return key(street,house)
        }
        cancel(policy.editHouseQuery(query,nowMS:now?.milliseconds ?? -1))
        suggestions = []; suggestionResult = nil; suggestionKind = "house"; suggestionInput = key(street,house)
        emit(epoch:now?.epoch ?? 0)
    }
    func cancelEditing() {
        guard started, !policy.closed, policy.editing else { return }
        cancel(policy.cancelEditing()); suggestions = []; suggestionResult = nil; suggestionKind = nil; suggestionInput = nil; emit(epoch:clock.read()?.epoch ?? 0)
    }
    func applyAddress(street: String, house: String) {
        guard started, !policy.closed, let engine=engine else { return }
        let now = clock.read()?.epoch ?? 0
        guard let normalized = DMMonitorEngine.normalize(street:street,house:house),
              let normalizedStreet = normalized["street"], let normalizedHouse = normalized["house"],
              engine.select(street:normalizedStreet,house:normalizedHouse,epoch:now) else { lastFailure="invalid_address"; emit(epoch:now); return }
        self.street = normalizedStreet; self.house = normalizedHouse
        record(.addressApplied,epoch:now)
        cancel(policy.selectAddress(key(normalizedStreet,normalizedHouse)))
        suggestions = []
        suggestionResult = nil
        suggestionKind = nil
        suggestionInput = nil
        lastFailure = nil
        tick()
    }
    func setTheme(_ theme: String) {
        guard started, !policy.closed, let engine=engine else { return }
        _ = engine.setTheme(theme); record(.themeChanged); emit(epoch:clock.read()?.epoch ?? 0)
    }
    func setFloating(visible: Bool, positioned: Bool, x: Int, y: Int, size: Int) {
        guard started, !policy.closed, let engine=engine else { return }
        _ = engine.setFloating(visible:visible,positioned:positioned,x:x,y:y,size:size)
        emit(epoch:clock.read()?.epoch ?? 0)
    }
    func selectTomorrow(_ value: Bool) {
        guard started, !policy.closed, let engine=engine else { return }
        engine.selectTomorrow(value); emit(epoch:clock.read()?.epoch ?? 0)
    }
    func popupOpened() {
        guard started, !policy.closed, let engine=engine else { return }
        _ = policy.popupOpened()
        engine.selectTomorrow(false)
        emit(epoch:clock.read()?.epoch ?? 0)
    }
    func close() { guard !policy.closed else { return }; record(.shutdown); cancel(policy.close()); emit(epoch:clock.read()?.epoch ?? 0) }
    private func received(_ ticket: MacSessionPolicy.Ticket, reply: MonitorReplyBox) {
        guard let engine=engine else { return }
        completedRequests += reply.requests
        let metadata = reply.value.metadata
        let stages = metadata["stages"] as? [[String:Any]] ?? []
        let blocked = stages.compactMap { ($0["status"] as? NSNumber)?.intValue }.first { $0 == 403 || $0 == 429 }
        let failure = metadata["failure"] as? String ?? "schema"
        let decision = policy.completed(ticket,status:blocked ?? (failure == "none" ? 200 : 500))
        if active?.0 == ticket { active = nil }
        cancel(decision.cancel)
        if decision.disposition == .accepted {
            if ticket.kind == .lookup {
                let accepted = engine.accept(reply.value,epoch:clock.read()?.epoch ?? 0)
                lastFailure = accepted ? nil : failure == "none" ? "schema" : failure
                let status=(stages.last?["status"] as? NSNumber)?.intValue ?? 0
                let reason=accepted ? 0 : (failure == "schema" || failure == "none") ? 12 : failure == "address_mismatch" ? 13 : (stages.last?["error"] as? NSNumber)?.intValue ?? 0
                record(accepted ? .lookupOK : .lookupFailed,status:status,reason:reason)
            }
            else {
                suggestions = (metadata["suggestions"] as? [[String:Any]] ?? []).compactMap { $0["label"] as? String }
                suggestionResult = failure == "none" ? (suggestions.isEmpty ? "empty" : "ready") : failure
            }
        } else if decision.disposition == .sourceStopped { lastFailure="source_stopped"; suggestions = []; record(.sourceStopped,status:blocked ?? 0,reason:5) }
        emit(epoch:clock.read()?.epoch ?? 0)
    }
    private func emit(epoch: Int64) {
        guard let engine=engine else { return }
        guard sequence < UInt64.max else { cancel(policy.close()); return }
        sequence += 1
        let value = engine.snapshot(epoch:epoch)
        let rows = (value["intervals"] as? [[String:Any]] ?? []).compactMap { item -> MonitorSnapshot.Row? in
            guard let start = item["start"] as? NSNumber, let end = item["end"] as? NSNumber,
                  let power = item["power"] as? NSNumber else { return nil }
            return MonitorSnapshot.Row(start:start.intValue,end:end.intValue,power:power.boolValue)
        }
        publish(MonitorSnapshot(sequence:sequence,street:value["street"] as? String ?? "",house:value["house"] as? String ?? "",
            address:value["address"] as? String ?? "Адресу не задано",theme:value["theme"] as? String ?? "system",
            forecast:(value["forecast"] as? NSNumber)?.boolValue == true && policy.displayAllowed,
            emergency:(value["emergency"] as? NSNumber)?.boolValue == true,
            tomorrow:(value["tomorrow"] as? NSNumber)?.boolValue == true,
            tomorrowAvailable:(value["tomorrowAvailable"] as? NSNumber)?.boolValue == true && !policy.editing,
            countdown:policy.editing ? "" : value["countdown"] as? String ?? "",rows:policy.editing ? [] : rows,
            suggestions:suggestions,
            suggestionResult:suggestionResult,
            suggestionKind:suggestionKind,
            suggestionInput:suggestionInput,
            totalOutageMinutes:(value["totalOutageMinutes"] as? NSNumber)?.intValue ?? 0,
            received:(value["received"] as? NSNumber)?.int64Value,editing:policy.editing,loading:policy.pending != nil,
            stopped:policy.stopped,storageWarning:(value["storageWarning"] as? NSNumber)?.boolValue == true,
            floatingVisible:(value["floatingVisible"] as? NSNumber)?.boolValue == true,
            floatingPositioned:(value["floatingPositioned"] as? NSNumber)?.boolValue == true,
            floatingX:(value["floatingX"] as? NSNumber)?.intValue ?? 0,
            floatingY:(value["floatingY"] as? NSNumber)?.intValue ?? 0,
            floatingSize:(value["floatingSize"] as? NSNumber)?.intValue ?? 1,
            failure:lastFailure,requestCount:completedRequests+(active?.1.requests ?? 0)))
    }
}
