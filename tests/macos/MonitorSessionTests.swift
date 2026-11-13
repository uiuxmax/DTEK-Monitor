import Foundation

#if !DTEKMONITOR_MAC_TEST_BUILD
#error("Synthetic session integration requires the protected test build")
#endif

private final class SnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: MonitorSnapshot?
    func store(_ item: MonitorSnapshot) { lock.lock(); value=item; lock.unlock() }
    func load() -> MonitorSnapshot? { lock.lock(); defer { lock.unlock() }; return value }
}

private final class LookupBox: @unchecked Sendable {
    private let lock=NSLock()
    private var value: MonitorReplyBox?
    func store(_ item: MonitorReplyBox) { lock.lock(); value=item; lock.unlock() }
    func load() -> MonitorReplyBox? { lock.lock(); defer { lock.unlock() }; return value }
}

func runMonitorSessionTests(port: UInt16, anchor: Data) async -> Bool {
    guard TestEnvelope.isValid(ProcessInfo.processInfo.environment),
          let root = ProcessInfo.processInfo.environment["DTEKMONITOR_TEST_PROFILE"] else { return false }
    var checks = 0, failures = 0
    func check(_ name: String, _ passed: Bool) {
        checks += 1; if !passed { failures += 1 }
        print("\(passed ? "PASS" : "FAIL") session: \(name)")
    }
    func profile() -> String {
        let path = root + "/" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath:path,withIntermediateDirectories:false)
        return path
    }
    func wait(_ box: SnapshotBox, _ predicate: (MonitorSnapshot) -> Bool) async -> MonitorSnapshot? {
        for _ in 0..<300 {
            if let value=box.load(), predicate(value) { return value }
            try? await Task.sleep(for:.milliseconds(20))
        }
        return nil
    }
    let box=SnapshotBox(), path=profile()
    let session=MonitorSession(profile:path,clock:MonitorClock(),mode:.loopback(port,anchor),publish:{ box.store($0) })
    await session.start()
    check("empty profile does not request",box.load()?.requestCount == 0 && box.load()?.forecast == false)
    await session.applyAddress(street:"  вул. Тестова  ",house:" 2-А ")
    let ready=await wait(box) { !$0.loading && $0.forecast }
    check("four real TLS GETs reach the receipt",ready?.requestCount == 4 && ready?.rows.count == 3)
    check("address normalizes before immutable selection",ready?.street == "вул. Тестова" && ready?.house == "2-А")
    check("actual receipt timestamp survives the bridge",ready?.received != nil)
    check("forecast retains daily duration and countdown",ready?.totalOutageMinutes == 210 && ready?.countdown.isEmpty == false)
    await session.popupOpened(); await session.popupOpened(); await session.tick()
    check("popup and countdown ticks issue no extra GET",box.load()?.requestCount == 4)
    await session.selectTomorrow(true)
    check("verified tomorrow is selectable with no today countdown",box.load()?.tomorrow == true && box.load()?.countdown == "")
    await session.popupOpened()
    check("reopening selects today without refresh",box.load()?.tomorrow == false && box.load()?.requestCount == 4)
    await session.setTheme("dark")
    check("theme saves through the actor",box.load()?.theme == "dark")
    await session.editStreet("те")
    check("editing hides retained graph immediately",box.load()?.editing == true && box.load()?.forecast == false && box.load()?.rows.isEmpty == true)
    try? await Task.sleep(for:.milliseconds(480)); await session.tick()
    let suggested=await wait(box) { !$0.loading && !$0.suggestions.isEmpty }
    let houseBox=SnapshotBox()
    let houseSession=MonitorSession(profile:profile(),clock:MonitorClock(),mode:.synthetic("ready"),publish:{ houseBox.store($0) })
    await houseSession.start(); await houseSession.editHouse(street:"вул. Тестова",house:"2")
    try? await Task.sleep(for:.milliseconds(480)); await houseSession.tick()
    let houseSuggested=await wait(houseBox) { !$0.loading && $0.suggestionResult != nil }
    check("debounced street and house suggestions",suggested?.suggestions == ["вул. Тестова"] && suggested?.suggestionResult == "ready" && suggested?.requestCount == 5 && houseSuggested?.suggestions == ["2"] && houseSuggested?.requestCount == 2)
    await houseSession.close()
    await session.cancelEditing()
    check("cancel restores confirmed graph without lookup",box.load()?.forecast == true && box.load()?.requestCount == 5 && box.load()?.suggestions.isEmpty == true)
    await session.close()
    check("closed session cannot display or start new work",box.load()?.forecast == false)
    let restoredBox=SnapshotBox()
    let restored=MonitorSession(profile:path,clock:MonitorClock(),mode:.synthetic("unavailable"),publish:{ restoredBox.store($0) })
    await restored.start()
    let retained=await wait(restoredBox) { !$0.loading && $0.requestCount == 1 }
    await restored.editStreet("те")
    try? await Task.sleep(for:.milliseconds(480)); await restored.tick()
    let failedSuggestion=await wait(restoredBox) { !$0.loading && $0.suggestionResult != nil }
    check("restart retains receipt and reports suggestion transport failure",retained?.forecast == true && retained?.received == ready?.received && retained?.theme == "dark" && failedSuggestion?.suggestionResult == "transport")
    await restored.close()
    let stoppedBox=SnapshotBox()
    let stopped=MonitorSession(profile:profile(),clock:MonitorClock(),mode:.synthetic("429"),publish:{ stoppedBox.store($0) })
    await stopped.start(); await stopped.applyAddress(street:"вул. Тестова",house:"2-А")
    let blocked=await wait(stoppedBox) { $0.stopped && !$0.loading }
    check("429 stops at the first resource",blocked?.requestCount == 1 && blocked?.failure == "source_stopped")
    await stopped.applyAddress(street:"вул. Інша",house:"3"); await stopped.tick(wake:true)
    check("address change and wake cannot bypass session stop",stoppedBox.load()?.stopped == true && stoppedBox.load()?.requestCount == 1)
    await stopped.close()
    func marker(_ leaf: String) async -> Bool {
        for _ in 0..<300 {
            if FileManager.default.fileExists(atPath:root+"/"+leaf) { return true }
            try? await Task.sleep(for:.milliseconds(20))
        }
        return false
    }
    let abaBox=SnapshotBox()
    let aba=MonitorSession(profile:profile(),clock:MonitorClock(),mode:.loopback(port,anchor),publish:{ abaBox.store($0) })
    try? Data("aba".utf8).write(to:URL(fileURLWithPath:root+"/phase"),options:.atomic)
    await aba.start(); await aba.applyAddress(street:"вул. Тестова",house:"2-А")
    check("cancel test reaches a real delayed planned-body read",await marker("delayed-ready"))
    await aba.applyAddress(street:"вул. Тестова",house:"3")
    await aba.applyAddress(street:"вул. Тестова",house:"2-А")
    let latest=await wait(abaBox) { $0.forecast && !$0.loading }
    check("A B A accepts only the latest confirmed selection",latest?.house == "2-А" && latest?.rows.count == 3)
    check("superseded B stays bounded and cannot overwrite final A",(8...12).contains(latest?.requestCount ?? 0))
    await aba.close()
    let closingBox=SnapshotBox(), closingPath=profile()
    let closing=MonitorSession(profile:closingPath,clock:MonitorClock(),mode:.loopback(port,anchor),publish:{ closingBox.store($0) })
    try? Data("close".utf8).write(to:URL(fileURLWithPath:root+"/phase"),options:.atomic)
    await closing.start(); await closing.applyAddress(street:"вул. Тестова",house:"2-А")
    check("close test reaches a real delayed planned-body read",await marker("closing-ready"))
    await closing.close()
    try? await Task.sleep(for:.milliseconds(600))
    check("late native completion cannot restore a closed graph",closingBox.load()?.forecast == false && closingBox.load()?.received == nil)
    check("close before completion cannot persist a receipt",!FileManager.default.fileExists(atPath:closingPath+"/receipt.json"))
    let worker=NativeLookupWorker(), first=LookupBox(), replacement=LookupBox()
    let firstTicket=MacSessionPolicy.Ticket(generation:1,kind:.lookup,selection:"A")
    let firstWork=worker.start(ticket:firstTicket,street:"вул. Тестова",house:"2-А",mode:.synthetic("403"),epoch:{ 0 },completed:{ first.store($0) })
    for _ in 0..<300 { if first.load() != nil { break }; try? await Task.sleep(for:.milliseconds(20)) }
    check("worker observes its first source-wide forbidden response",first.load()?.requests == 1 && first.load()?.value.metadata["failure"] as? String == "forbidden")
    let nextTicket=MacSessionPolicy.Ticket(generation:2,kind:.lookup,selection:"B")
    let nextWork=worker.start(ticket:nextTicket,street:"вул. Інша",house:"3",mode:.synthetic("tomorrow"),epoch:{ 0 },completed:{ replacement.store($0) })
    for _ in 0..<300 { if replacement.load() != nil { break }; try? await Task.sleep(for:.milliseconds(20)) }
    check("worker blocks replacement independently of actor notification",replacement.load()?.requests == 0 && replacement.load()?.value.metadata["failure"] as? String == "forbidden")
    withExtendedLifetime(firstWork) {}; withExtendedLifetime(nextWork) {}
    print("RESULT \(checks-failures)/\(checks) connected session checks passed")
    return checks == 24 && failures == 0
}
