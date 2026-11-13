import Foundation

// Single-owner scheduling policy. Its owner validates addresses/normalizes queries
// with M4, supplies named-Kyiv dates and cancels retired tickets before new work.
struct MacSessionPolicy {
    enum Kind: Equatable, Sendable { case lookup, suggestions, houseSuggestions }
    struct Ticket: Equatable, Sendable {
        let generation: UInt64
        let kind: Kind
        let selection: String
    }
    struct Action {
        var cancel: Ticket? = nil
        var start: Ticket? = nil
    }
    enum Disposition: Equatable { case accepted, obsolete, sourceStopped }
    struct CompletionAction { let disposition: Disposition; let cancel: Ticket? }

    private(set) var generation: UInt64
    private(set) var selection: String?
    private(set) var pending: Ticket?
    private(set) var editing = false
    private(set) var stopped = false
    private(set) var sourceStatus: Int?
    private(set) var closed = false
    private(set) var clockBroken = false
    private var lastObservedMS: Int64?
    private var lastLookupMS: Int64?
    private var lastKyivDay: String?
    private var draftQuery: String?
    private var draftKind: Kind = .suggestions
    private var editedMS: Int64?
    private var editGeneration: UInt64?
    private var issuedEditGeneration: UInt64?

    init(initialGeneration: UInt64 = 0) { generation = initialGeneration }
    var displayAllowed: Bool { !editing && selection != nil && !closed && !clockBroken }

    private mutating func nextGeneration() -> UInt64? {
        guard generation < UInt64.max else { closed = true; return nil }
        generation += 1
        return generation
    }
    private mutating func retire() -> Ticket? {
        let old = pending
        pending = nil
        _ = nextGeneration()
        return old
    }
    private mutating func observe(_ milliseconds: Int64) -> Bool {
        guard !clockBroken, milliseconds >= 0,
              lastObservedMS == nil || milliseconds >= lastObservedMS! else {
            clockBroken = true
            return false
        }
        lastObservedMS = milliseconds
        return true
    }
    mutating func selectAddress(_ validatedKey: String?) -> Ticket? {
        let old = retire()
        selection = validatedKey.flatMap { $0.isEmpty ? nil : $0 }
        editing = false; draftQuery = nil; editedMS = nil; editGeneration = nil
        lastLookupMS = nil; lastKyivDay = nil
        // A source-wide 403/429 stop survives all address changes.
        return old
    }
    mutating func editStreetQuery(_ query: String?, nowMS: Int64) -> Ticket? {
        let old = retire()
        editing = true
        draftQuery = query
        draftKind = .suggestions
        editedMS = observe(nowMS) ? nowMS : nil
        editGeneration = generation
        return old
    }
    mutating func editHouseQuery(_ query: String?, nowMS: Int64) -> Ticket? {
        let old = retire()
        editing = true
        draftQuery = query
        draftKind = .houseSuggestions
        editedMS = observe(nowMS) ? nowMS : nil
        editGeneration = generation
        return old
    }
    mutating func cancelEditing() -> Ticket? {
        let old = retire()
        editing = false; draftQuery = nil; editedMS = nil; editGeneration = nil
        return old
    }
    // Popup presentation deliberately issues no work. Refresh belongs to tick.
    func popupOpened() -> Action { Action() }

    mutating func tick(nowMS: Int64, kyivDay: String?, attemptExpired: Bool = false) -> Action {
        guard !closed else { return Action() }
        guard observe(nowMS), let day = kyivDay, !day.isEmpty else { return Action(cancel: retire()) }
        var action = Action()
        if let work = pending, attemptExpired || (work.kind == .lookup && lastKyivDay != day) {
            action.cancel = retire()
        }
        guard !closed, !stopped, pending == nil else { return action }
        if !editing, let key = selection {
            let due = lastLookupMS == nil || lastKyivDay != day ||
                (nowMS >= lastLookupMS! && nowMS - lastLookupMS! >= 1_800_000)
            if due, let token = nextGeneration() {
                let ticket = Ticket(generation: token, kind: .lookup, selection: key)
                pending = ticket; action.start = ticket
                lastLookupMS = nowMS; lastKyivDay = day
            }
        } else if editing, let query = draftQuery, (draftKind == .houseSuggestions || query.utf16.count >= 2),
                  let edited = editedMS, nowMS >= edited, nowMS - edited >= 450,
                  editGeneration != issuedEditGeneration, let token = nextGeneration() {
            let ticket = Ticket(generation: token, kind: draftKind, selection: query)
            pending = ticket; action.start = ticket
            issuedEditGeneration = editGeneration
        }
        return action
    }
    mutating func completed(_ ticket: Ticket, status: Int) -> CompletionAction {
        guard !closed else { return CompletionAction(disposition: .obsolete, cancel: nil) }
        if status == 403 || status == 429 {
            let cancelled = pending == ticket ? nil : pending
            stopped = true; sourceStatus = status
            _ = retire()
            return CompletionAction(disposition: .sourceStopped, cancel: cancelled)
        }
        let matches = ticket.kind == .lookup ? (!editing && selection == ticket.selection) :
            (editing && draftKind == ticket.kind && draftQuery == ticket.selection)
        guard !clockBroken, pending == ticket, ticket.generation == generation, matches else {
            return CompletionAction(disposition: .obsolete, cancel: nil)
        }
        pending = nil
        return CompletionAction(disposition: .accepted, cancel: nil)
    }
    mutating func close() -> Ticket? {
        let old = retire(); closed = true
        return old
    }
}

// Native adapter for the policy's injectable millisecond input. ContinuousClock
// includes sleep; C++ steady_clock is not assumed to have the same semantics.
struct MacContinuousMilliseconds {
    private let began = ContinuousClock.now
    func now() -> Int64? {
        let value = began.duration(to: ContinuousClock.now).components
        guard value.seconds >= 0 else { return nil }
        let whole = value.seconds.multipliedReportingOverflow(by: 1000)
        guard !whole.overflow else { return nil }
        let result = whole.partialValue.addingReportingOverflow(value.attoseconds / 1_000_000_000_000_000)
        return result.overflow ? nil : result.partialValue
    }
}
