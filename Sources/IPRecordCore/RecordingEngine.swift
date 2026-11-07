import Foundation

public struct EngineState: Sendable {
    public var paused = false; public var sleeping = false; public var stopping = false
    public var storageError: String?; public var checking = false; public var currentConfirmed = false
    public var saved: SavedState?; public var pendingNetwork: NetworkSnapshot?; public var unsaved: Observation?
    public var message: String?; public var rounds = 0; public var requests = 0
    public init() {}
    public var title: String {
        if stopping { return "停止中" }; if storageError != nil { return "无法保存记录" }; if paused { return "已暂停" }; if sleeping { return "睡眠中" }; return "记录中"
    }
}
public actor RecordingEngine {
    private let store: HistoryStore; private let geo: GeoResolver; private let probe: any IPProbing
    public nonisolated let epoch: EventEpoch
    private let snapshot: @Sendable (String) -> NetworkSnapshot
    private let update: @Sendable (EngineState) -> Void
    private let systemEvents: Bool
    private var events: NetworkEvents?
    private var state = EngineState()
    private var contextID = UUID().uuidString; private var contextFingerprint: String?
    private var interval: TimeInterval
    private var timer: Task<Void, Never>?; private var debounce: Task<Void, Never>?; private var round: Task<Void, Never>?
    private var pending = Set<String>()
    private var firstEvent: TimeInterval?; private var lastEvent: TimeInterval = 0
    private var lastProbe: TimeInterval = -.infinity; private var lastFinished: TimeInterval = -.infinity
    private var initialized = false
    public init(store: HistoryStore, geo: GeoResolver, probe: any IPProbing = PublicIPProbe(), epoch: EventEpoch = EventEpoch(), interval: TimeInterval = 300, systemEvents: Bool = true, snapshot: @escaping @Sendable (String) -> NetworkSnapshot = { NetworkSnapshotter().readSnapshot(path: $0) }, update: @escaping @Sendable (EngineState) -> Void = { _ in }) {
        self.store = store; self.geo = geo; self.probe = probe; self.epoch = epoch; self.interval = interval; self.systemEvents = systemEvents; self.snapshot = snapshot; self.update = update
    }
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private var canCheck: Bool { initialized && !state.paused && !state.sleeping && !state.stopping && state.storageError == nil }
    private func publish() { update(state) }
    public func status() -> EngineState { state }
    public func start(paused: Bool) async {
        guard !initialized else { return }; initialized = true; state.paused = paused
        do { state.saved = try await store.beginSession() }
        catch { blockStorage(error); return }
        await geo.prepare()
        if !paused { subscribe(); trigger("start") }
        publish()
    }
    private func subscribe() {
        guard systemEvents, events == nil else { return }
        let events = NetworkEvents(epoch: epoch) { [weak self] reason in Task { await self?.networkEvent(reason) } }
        self.events = events; events.start()
    }
    private func unsubscribe() { events?.stop(); events = nil }
    private func blockStorage(_ error: any Error) {
        state.storageError = error.localizedDescription; state.checking = false; state.currentConfirmed = false
        epoch.bump(); round?.cancel(); timer?.cancel(); debounce?.cancel(); unsubscribe(); publish()
        schedule(after: 300, reason: "storageRetry")
    }
    public func networkEvent(_ reason: String) {
        guard canCheck else { return }
        state.currentConfirmed = false; round?.cancel(); pending.insert(reason)
        if firstEvent == nil { firstEvent = now }; lastEvent = now
        let delay = min(2, max(0, 10 - (now - (firstEvent ?? now))))
        debounce?.cancel(); debounce = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay), tolerance: .milliseconds(100)); await self?.flushEvents() } catch {}
        }
        publish()
    }
    private func flushEvents() {
        guard canCheck else { return }
        let unstable = now - lastEvent < 1.9
        firstEvent = nil
        let reasons = pending; pending.removeAll(); launch(reasons.isEmpty ? ["network"] : reasons, unstable: unstable)
    }
    public func checkNow() {
        guard canCheck else { return }
        if round != nil { state.message = "正在检查，已合并本次操作"; publish(); return }
        if now - lastFinished < 10 { state.message = "已显示刚完成的检查结果"; publish(); return }
        trigger("manual")
    }
    public func setInterval(_ seconds: TimeInterval) { interval = [300.0,900.0,1800.0].contains(seconds) ? seconds : 300; if canCheck && round == nil { schedule(after: interval, reason: "timer") } }
    private func trigger(_ reason: String) { launch([reason]) }
    private func launch(_ reasons: Set<String>, unstable: Bool = false) {
        guard canCheck else { return }
        guard round == nil else { pending.formUnion(reasons); return }
        timer?.cancel(); debounce?.cancel()
        round = Task { [weak self] in await self?.performRound(reasons, unstable: unstable) }
    }
    private func performRound(_ reasons: Set<String>, unstable: Bool) async {
        let stamp = epoch.value, started = Date()
        guard canCheck, !Task.isCancelled else { finishRound(stale: true); return }
        let network = snapshot(events?.pathStatus ?? "satisfied")
        guard stamp == epoch.value, !Task.isCancelled else { finishRound(stale: true); return }
        let changed = contextFingerprint != network.fingerprint
        if changed { contextID = UUID().uuidString; contextFingerprint = network.fingerprint; state.currentConfirmed = false }
        let roundContext = contextID
        state.pendingNetwork = network; state.checking = true; state.message = nil; publish()
        let cooled = now - lastProbe >= 30 || reasons.contains("manual")
        // Duplicate notifications do not create a deferred/confirmed history oscillation.
        if !changed && !cooled && !unstable && network.path != "unsatisfied" {
            finishRound(stale: false, next: max(0.1, 30 - (now - lastProbe)), reason: "cooldown"); return
        }
        let results: (ProbeResult, ProbeResult)
        let pendingStatus = unstable ? "notYetChecked" : "deferredCooldown"
        if network.path == "unsatisfied" || unstable || !cooled {
            let status = network.path == "unsatisfied" ? "skippedNoPath" : pendingStatus
            results = (.init(family:.v4,status:status,startedAt:started),.init(family:.v6,status:status,startedAt:started))
        } else {
            lastProbe = now; state.requests += 2
            async let a = probe.probe(.v4); async let b = probe.probe(.v6)
            results = await (a,b)
        }
        guard canCheck, stamp == epoch.value, !Task.isCancelled else { finishRound(stale:true); return }
        let after = snapshot(events?.pathStatus ?? "satisfied")
        guard stamp == epoch.value, after.fingerprint == network.fingerprint else {
            epoch.bump(); state.currentConfirmed = false; pending.insert("network"); finishRound(stale:true); return
        }
        var observation = Observation(contextID:roundContext,epoch:stamp,startedAt:started,completedAt:Date(),triggers:Array(reasons),consistency:unstable ? "unstable" : "stable",network:network,v4:results.0,v6:results.1)
        if let address = observation.v4.address { observation.v4.geo = await geo.lookup(address) }
        if let address = observation.v6.address { observation.v6.geo = await geo.lookup(address) }
        guard canCheck, stamp == epoch.value, !Task.isCancelled else { finishRound(stale:true); return }
        do {
            let counter = epoch
            let saved = try await store.applyCheck(observation, isValid: { counter.value == stamp })
            state.saved = saved; state.unsaved = nil; state.rounds += 1
            state.currentConfirmed = canCheck && counter.value == stamp && !Task.isCancelled && !unstable
            if !state.currentConfirmed && canCheck { pending.insert("network") }
        } catch is CancellationError { finishRound(stale:true); return }
        catch { state.unsaved = observation; round = nil; blockStorage(error); return }
        let delay = unstable ? 2 : (!cooled ? max(0.1, 30 - (now-lastProbe)) : interval)
        finishRound(stale:false,next:delay,reason:unstable || !cooled ? "cooldown" : "timer")
    }
    private func finishRound(stale: Bool, next: TimeInterval? = nil, reason: String = "timer") {
        round = nil; state.checking = false
        if !stale { lastFinished = now }
        publish()
        guard canCheck else { return }
        if !pending.isEmpty {
            // Do not race a scheduled quiet-period debounce with another immediate round.
            if firstEvent == nil { debounce?.cancel(); debounce = Task { [weak self] in do { try await Task.sleep(for:.seconds(2)); await self?.flushEvents() } catch {} } }
        } else { schedule(after:next ?? interval,reason:reason) }
    }
    private func schedule(after seconds: TimeInterval, reason: String) {
        timer?.cancel()
        timer = Task { [weak self] in
            do {
                try await Task.sleep(for:.seconds(max(seconds,0.05)),tolerance:.seconds(reason == "timer" ? 30 : 0.1))
                if reason == "storageRetry" { await self?.retryStorage() } else { await self?.trigger(reason) }
            } catch {}
        }
    }
    private func invalidate() {
        epoch.bump(); round?.cancel(); timer?.cancel(); debounce?.cancel(); pending.removeAll(); firstEvent = nil
        state.currentConfirmed = false; state.checking = false; state.pendingNetwork = nil
        contextFingerprint = nil; contextID = UUID().uuidString
    }
    public func pause() async {
        guard !state.paused else { return }; state.paused = true; invalidate(); unsubscribe(); publish()
        do { try await store.marker("pause") } catch { blockStorage(error) }
    }
    public func resume() async {
        guard state.paused else { return }; state.paused = false; invalidate()
        do { try await store.marker("resume") } catch { blockStorage(error); return }
        if canCheck { subscribe(); trigger("resume") }; publish()
    }
    public func sleep() async {
        guard !state.sleeping else { return }; state.sleeping = true; invalidate(); unsubscribe(); publish()
        do { try await store.marker("sleep") } catch { blockStorage(error) }
    }
    public func wake() async {
        guard state.sleeping else { return }; state.sleeping = false; invalidate()
        do { try await store.marker("wake") } catch { blockStorage(error); return }
        if canCheck { subscribe(); pending.insert("wake"); networkEvent("wake") }; publish()
    }
    public func retryStorage() async {
        guard state.storageError != nil, !state.stopping else { return }
        do { try await store.retry(); state.storageError = nil; state.unsaved = nil; invalidate(); if canCheck { subscribe(); trigger("storageRecovery") }; publish() }
        catch { blockStorage(error) }
    }
    public func clearHistory() async throws {
        do { try await store.clearHistory(); state.saved = await store.savedState(); publish() }
        catch { blockStorage(error); throw error }
    }
    public func stop() async {
        guard !state.stopping else { return }; state.stopping = true; invalidate(); unsubscribe(); publish()
        if let round { await round.value }; self.round = nil
        do { try await store.finish() } catch { state.storageError = error.localizedDescription; publish() }
    }
}
