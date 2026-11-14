import Foundation

func runSessionPolicyTests() throws {
    typealias Policy = MacSessionPolicy
    let day = "2026-11-12", next = "2026-11-13"
    func started(_ key: String = "A", now: Int64 = 0) throws -> (Policy, Policy.Ticket) {
        var p = Policy(); _ = p.selectAddress(key)
        guard let ticket = p.tick(nowMS: now, kyivDay: day).start else {
            throw NSError(domain: "SessionPolicyTests", code: 1)
        }
        return (p,ticket)
    }
    let cases: [(String, () throws -> Bool)] = [
        ("no saved address issues no work", { var p=Policy(); return p.tick(nowMS:0,kyivDay:day).start == nil }),
        ("empty address is incomplete", { var p=Policy(); _=p.selectAddress(""); return p.tick(nowMS:0,kyivDay:day).start == nil }),
        ("saved address starts one lookup", { let seed=try started(); var p=seed.0; return seed.1.kind == .lookup && seed.1.selection == "A" && p.tick(nowMS:1,kyivDay:day).start == nil }),
        ("pending lookup remains single flight", { let seed=try started(); var p=seed.0; return p.tick(nowMS:1_800_000,kyivDay:day).start == nil && p.pending == seed.1 }),
        ("popup presentation issues no work", { let seed=try started(); let p=seed.0; let a=p.popupOpened(); return a.start == nil && a.cancel == nil && p.pending == seed.1 }),
        ("completion retires only its lookup", { let seed=try started(); var p=seed.0; return p.completed(seed.1,status:200).disposition == .accepted && p.pending == nil }),
        ("before thirty minutes stays idle", { let seed=try started(); var p=seed.0; _=p.completed(seed.1,status:200); return p.tick(nowMS:1_799_999,kyivDay:day).start == nil }),
        ("thirty minute boundary refreshes", { let seed=try started(); var p=seed.0; _=p.completed(seed.1,status:200); return p.tick(nowMS:1_800_000,kyivDay:day).start?.kind == .lookup }),
        ("failed refresh does not reset interval", { let seed=try started(); var p=seed.0; _=p.completed(seed.1,status:500); return p.tick(nowMS:1000,kyivDay:day).start == nil && p.tick(nowMS:1_800_000,kyivDay:day).start != nil }),
        ("minute countdown ticks issue no refresh", { let seed=try started(); var p=seed.0; _=p.completed(seed.1,status:200); return (1...60).allSatisfy { p.tick(nowMS:Int64($0)*1000,kyivDay:day).start == nil } }),
        ("new Kyiv day refreshes immediately", { let seed=try started(); var p=seed.0; _=p.completed(seed.1,status:200); return p.tick(nowMS:1,kyivDay:next).start != nil }),
        ("new day cancels obsolete pending lookup", { let seed=try started(); var p=seed.0; let a=p.tick(nowMS:1,kyivDay:next); return a.cancel == seed.1 && a.start != nil && a.start != seed.1 }),
        ("missing Kyiv date cancels pending", { let seed=try started(); var p=seed.0; let a=p.tick(nowMS:1,kyivDay:nil); return a.cancel == seed.1 && a.start == nil }),
        ("missing Kyiv date does not start", { var p=Policy(); _=p.selectAddress("A"); return p.tick(nowMS:0,kyivDay:nil).start == nil }),
        ("long same-day sleep starts at most one due refresh", { let seed=try started(); var p=seed.0; let a=p.tick(nowMS:14_400_000,kyivDay:day,attemptExpired:true); return a.cancel == seed.1 && a.start != nil && p.tick(nowMS:14_400_001,kyivDay:day).start == nil }),
        ("short sleep cancels expired attempt without early retry", { let seed=try started(); var p=seed.0; let a=p.tick(nowMS:60_000,kyivDay:day,attemptExpired:true); return a.cancel == seed.1 && a.start == nil && p.pending == nil }),
        ("multiple missed periods do not catch up", { let seed=try started(); var p=seed.0; _=p.completed(seed.1,status:200); guard let t=p.tick(nowMS:14_400_000,kyivDay:day).start else { return false }; _=p.completed(t,status:200); return p.tick(nowMS:14_400_001,kyivDay:day).start == nil }),
        ("editing cancels lookup and hides prior display", { let seed=try started(); var p=seed.0; return p.editStreetQuery("те",nowMS:1) == seed.1 && !p.displayAllowed && p.pending == nil }),
        ("one UTF16 unit has no suggestions", { var p=Policy(); _=p.editStreetQuery("т",nowMS:0); return p.tick(nowMS:450,kyivDay:day).start == nil }),
        ("two UTF16 units allow suggestions", { var p=Policy(); _=p.editStreetQuery("те",nowMS:0); return p.tick(nowMS:450,kyivDay:day).start?.kind == .suggestions }),
        ("supplementary scalar is two UTF16 units", { var p=Policy(); _=p.editStreetQuery("😀",nowMS:0); return p.tick(nowMS:450,kyivDay:day).start?.kind == .suggestions }),
        ("449ms is before debounce", { var p=Policy(); _=p.editStreetQuery("те",nowMS:0); return p.tick(nowMS:449,kyivDay:day).start == nil }),
        ("450ms is debounce boundary", { var p=Policy(); _=p.editStreetQuery("те",nowMS:0); return p.tick(nowMS:450,kyivDay:day).start?.selection == "те" }),
        ("new typing restarts debounce", { var p=Policy(); _=p.editStreetQuery("те",nowMS:0); _=p.editStreetQuery("тес",nowMS:400); return p.tick(nowMS:450,kyivDay:day).start == nil && p.tick(nowMS:850,kyivDay:day).start?.selection == "тес" }),
        ("unchanged query is requested only once", { var p=Policy(); _=p.editStreetQuery("те",nowMS:0); guard let t=p.tick(nowMS:450,kyivDay:day).start else { return false }; _=p.completed(t,status:200); return p.tick(nowMS:1000,kyivDay:day).start == nil }),
        ("house edits debounce and retire obsolete searches", { var p=Policy(); _=p.editHouseQuery("вул. Тестова\n2",nowMS:0); guard p.tick(nowMS:449,kyivDay:day).start == nil, let t=p.tick(nowMS:450,kyivDay:day).start, t.kind == .houseSuggestions else { return false }; _=p.editHouseQuery("вул. Тестова\n3",nowMS:500); return p.completed(t,status:200).disposition == .obsolete && p.tick(nowMS:950,kyivDay:day).start?.kind == .houseSuggestions }),
        ("edit retirement rejects stale suggestions", { var p=Policy(); _=p.editStreetQuery("те",nowMS:0); guard let t=p.tick(nowMS:450,kyivDay:day).start else { return false }; _=p.editStreetQuery("тес",nowMS:500); return p.completed(t,status:200).disposition == .obsolete }),
        ("cancel editing restores confirmed selection display", { let seed=try started(); var p=seed.0; _=p.editStreetQuery("те",nowMS:1); _=p.cancelEditing(); return p.displayAllowed && p.selection == "A" && p.pending == nil }),
        ("Save selects a complete address immediately", { var p=Policy(); _=p.editStreetQuery("те",nowMS:0); _=p.selectAddress("confirmed-A"); return p.tick(nowMS:1,kyivDay:day).start?.selection == "confirmed-A" }),
        ("address change cancels pending work", { let seed=try started(); var p=seed.0; return p.selectAddress("B") == seed.1 && p.selection == "B" && p.pending == nil }),
        ("A B A rejects the first A result", { let seed=try started(); var p=seed.0; _=p.selectAddress("B"); _=p.selectAddress("A"); let current=p.tick(nowMS:1,kyivDay:day).start; return current != seed.1 && p.completed(seed.1,status:200).disposition == .obsolete && p.pending == current }),
        ("stale failure cannot clear current pending work", { let seed=try started(); var p=seed.0; _=p.selectAddress("B"); let current=p.tick(nowMS:1,kyivDay:day).start; return p.completed(seed.1,status:500).disposition == .obsolete && p.pending == current }),
        ("duplicate completion is obsolete", { let seed=try started(); var p=seed.0; _=p.completed(seed.1,status:200); return p.completed(seed.1,status:200).disposition == .obsolete }),
        ("403 stops automatic refresh", { let seed=try started(); var p=seed.0; return p.completed(seed.1,status:403).disposition == .sourceStopped && p.tick(nowMS:1_800_000,kyivDay:day).start == nil }),
        ("429 stops automatic refresh", { let seed=try started(); var p=seed.0; return p.completed(seed.1,status:429).disposition == .sourceStopped && p.sourceStatus == 429 && p.pending == nil }),
        ("source and cleanup stops survive address changes", { let seed=try started(); var p=seed.0; _=p.completed(seed.1,status:403); _=p.selectAddress("B"); var cleanup=Policy(); _=cleanup.selectAddress("A"); let old=cleanup.tick(nowMS:0,kyivDay:day).start; _=cleanup.selectAddress("B"); let newer=cleanup.tick(nowMS:1,kyivDay:day).start; let cancelled=cleanup.stopForCleanup(); return p.tick(nowMS:1,kyivDay:day).start == nil && p.stopped && old != nil && cancelled == newer && cleanup.cleanupStopped && cleanup.tick(nowMS:2000,kyivDay:day).start == nil }),
        ("source stop survives midnight and wake", { let seed=try started(); var p=seed.0; _=p.completed(seed.1,status:429); return p.tick(nowMS:86_400_000,kyivDay:next,attemptExpired:true).start == nil && p.stopped }),
        ("source stop suppresses suggestions", { let seed=try started(); var p=seed.0; _=p.completed(seed.1,status:403); _=p.editStreetQuery("те",nowMS:1); return p.tick(nowMS:1000,kyivDay:day).start == nil }),
        ("late source stop cancels current work", { let seed=try started(); var p=seed.0; _=p.selectAddress("B"); let current=p.tick(nowMS:1,kyivDay:day).start; let a=p.completed(seed.1,status:429); return a.disposition == .sourceStopped && a.cancel == current && p.pending == nil }),
        ("close cancels owned pending ticket", { let seed=try started(); var p=seed.0; return p.close() == seed.1 && p.closed && p.pending == nil }),
        ("closed owner starts no more work", { let seed=try started(); var p=seed.0; _=p.close(); _=p.selectAddress("B"); return p.tick(nowMS:1,kyivDay:day).start == nil && !p.displayAllowed }),
        ("late completion after close is ignored", { let seed=try started(); var p=seed.0; _=p.close(); return p.completed(seed.1,status:403).disposition == .obsolete }),
        ("monotonic rollback cancels and fails closed", { let seed=try started(now:10); var p=seed.0; let a=p.tick(nowMS:9,kyivDay:day); return a.cancel == seed.1 && a.start == nil && p.clockBroken }),
        ("clock rollback cannot revive requests", { let seed=try started(now:10); var p=seed.0; _=p.tick(nowMS:9,kyivDay:day); _=p.selectAddress("B"); return p.tick(nowMS:1000,kyivDay:day).start == nil }),
        ("negative clock input fails closed", { var p=Policy(); _=p.selectAddress("A"); return p.tick(nowMS:-1,kyivDay:day).start == nil && p.clockBroken }),
        ("generation counter never wraps to zero", { var p=Policy(initialGeneration:UInt64.max); _=p.selectAddress("A"); return p.closed && p.generation == UInt64.max && p.tick(nowMS:0,kyivDay:day).start == nil }),
        ("generation exhaustion fails before a new request", { var p=Policy(initialGeneration:UInt64.max-1); _=p.selectAddress("A"); return p.tick(nowMS:0,kyivDay:day).start == nil && p.closed && p.pending == nil }),
        ("maximum clock value does not overflow interval math", { let seed=try started(now:Int64.max); var p=seed.0; _=p.completed(seed.1,status:200); return p.tick(nowMS:Int64.max,kyivDay:day).start == nil }),
        ("native ContinuousClock adapter returns nonnegative milliseconds", { let clock=MacContinuousMilliseconds(); return clock.now().map { $0 >= 0 } ?? false })
    ]
    for (name,evaluate) in cases {
        guard try evaluate() else { throw NSError(domain:"SessionPolicyTests",code:1,userInfo:[NSLocalizedDescriptionKey:name]) }
    }
    print("RESULT \(cases.count)/\(cases.count) lifecycle policy checks passed")
}
