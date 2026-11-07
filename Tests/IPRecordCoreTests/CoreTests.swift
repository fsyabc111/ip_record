import CSQLite
import Foundation
import Testing

@testable import IPRecordCore

func temporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(
    "IPRecord-tests-" + UUID().uuidString)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}
func sample(
  at seconds: Double = 1000, ip: String = "8.8.8.8", status: String = "confirmed",
  error: String? = nil, network: NetworkSnapshot = .init(path: "satisfied"),
  context: String = "test"
) -> Observation {
  let date = Date(timeIntervalSince1970: seconds)
  let v4 = ProbeResult(
    family: .v4, status: status, address: status == "confirmed" ? IPAddress(ip) : nil, error: error,
    startedAt: date, completedAt: date)
  let v6 = ProbeResult(
    family: .v6, status: "failed", error: "timeout", startedAt: date, completedAt: date)
  return .init(
    contextID: context, epoch: 0, startedAt: date, completedAt: date, triggers: ["test"],
    network: network, v4: v4, v6: v6)
}
@Test func addressNormalizationAndScopes() throws {
  #expect(IPAddress("2001:4860:0000:0::8888") == IPAddress("2001:4860::8888"))
  #expect(IPAddress("::ffff:8.8.8.8") == IPAddress("8.8.8.8"))
  #expect(IPAddress("fe80::1%en0") != IPAddress("fe80::1%en1"))
  #expect(IPAddress("fe80::1%en0")?.text == "fe80::1%en0")
  for text in [
    "192.168.0.1", "10.0.0.1", "100.64.0.1", "127.0.0.1", "0.0.0.0", "224.0.0.1", "192.0.2.1",
    "198.51.100.1", "203.0.113.1", "198.18.0.1", "::", "::1", "fe80::1", "fd00::1", "ff02::1",
    "2001:db8::1", "3fff::1",
  ] { #expect(IPAddress(text)?.isPublic == false, "\(text)") }
  #expect(IPAddress("8.8.8.8")?.isPublic == true)
  #expect(IPAddress("2606:4700:4700::1111")?.isPublic == true)
  #expect(IPAddress("garbage") == nil)
  #expect(IPAddress("1.2.3.4%en0") == nil)
  #expect(NetworkSnapshotter.prefixLength([255, 255, 255, 0]) == 24)
  #expect(NetworkSnapshotter.prefixLength([255, 0, 255, 0]) == nil)
}
@Test func responseValidation() {
  for text in ["<html>", "{\"ip\":\"8.8.8.8\"}", "8.8.8.8 1.1.1.1", "127.0.0.1", "8.8.8.8\u{00a0}"]
  { #expect(PublicIPProbe.validate(Data(text.utf8), family: .v4).0 == nil) }
  #expect(PublicIPProbe.validate(Data(" \n8.8.8.8\r\n".utf8), family: .v4).0?.text == "8.8.8.8")
  #expect(PublicIPProbe.validate(Data("2606:4700::1111".utf8), family: .v4).1 == "familyMismatch")
  #expect(PublicIPProbe.validate(Data(repeating: 65, count: 1025), family: .v4).1 == "oversized")
}
@Test func safeProxyProjection() throws {
  let projection = NetworkSnapshotter.safeProxy([
    "ProxyAutoConfigURLString": "https://user:secret@example.com:8443/token/path?k=secret#secret",
    "HTTPUser": "private", "HTTPPassword": "private", "HTTPEnable": 1,
    "ExceptionsList": ["*.local"],
  ])
  let encoded = String(decoding: try jsonEncoder().encode(projection), as: UTF8.self)
  #expect(projection.values["PACOrigin"] == ["https://example.com:8443"])
  #expect(!encoded.contains("secret"))
  #expect(!encoded.contains("private"))
  #expect(!encoded.contains("/token"))
}
@Test func addressOrderAndDNSPriority() {
  let a = LocalAddress(interface: "en0", type: "Wi-Fi", ip: IPAddress("192.168.1.2")!)
  let b = LocalAddress(interface: "utun0", type: "虚拟／其他", ip: IPAddress("10.0.0.1")!)
  #expect(
    NetworkSnapshot(addresses: [a, b, a]).fingerprint
      == NetworkSnapshot(addresses: [b, a]).fingerprint)
  let dns1 = ConfigurationGroup(
    source: "service", status: .available, values: ["ServerAddresses": ["1.1.1.1", "8.8.8.8"]])
  let dns2 = ConfigurationGroup(
    source: "service", status: .available, values: ["ServerAddresses": ["8.8.8.8", "1.1.1.1"]])
  #expect(NetworkSnapshot(dns: [dns1]).fingerprint != NetworkSnapshot(dns: [dns2]).fingerprint)
}
@Test func thousandIdenticalChecksAndImmutableSnapshot() async throws {
  let dir = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }
  let store = HistoryStore(url: dir.appendingPathComponent("history.sqlite"))
  _ = try await store.beginSession()
  for index in 0..<1000 { _ = try await store.applyCheck(sample(at: Double(index + 1000))) }
  let reader = HistoryReader(url: dir.appendingPathComponent("history.sqlite"))
  #expect(try await reader.count(filter: .init(category: "state")) == 1)
  let first = try #require(try await reader.page(filter: .init(category: "state")).first)
  #expect(first.firstObservation?.v4.completedAt == Date(timeIntervalSince1970: 1000))
  #expect(first.confirmationSummary.lastConfirmedV4At == Date(timeIntervalSince1970: 1999))
  #expect(first.confirmationSummary.lastConfirmedV6At == nil)
  try await store.finish()
}
@Test func failureLastKnownUsesLatestSummaryAndRecoveryChanges() async throws {
  let dir = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }
  let store = HistoryStore(url: dir.appendingPathComponent("history.sqlite"))
  _ = try await store.beginSession()
  _ = try await store.applyCheck(sample(at: 1000))
  _ = try await store.applyCheck(sample(at: 1100))
  let failed = try await store.applyCheck(sample(at: 1200, status: "failed", error: "timeout"))
  #expect(failed.observation.v4.address == nil)
  #expect(failed.observation.v4.lastKnown?.confirmedAt == Date(timeIntervalSince1970: 1100))
  for t in 1201...1210 {
    _ = try await store.applyCheck(sample(at: Double(t), status: "failed", error: "timeout"))
  }
  let reader = HistoryReader(url: dir.appendingPathComponent("history.sqlite"))
  #expect(try await reader.count(filter: .init(category: "state")) == 2)
  _ = try await store.applyCheck(sample(at: 1300))
  #expect(try await reader.count(filter: .init(category: "state")) == 3)
  let rows = try await reader.page(filter: .init(category: "state"))
  #expect(rows[1].confirmationSummary.lastConfirmedV4At == Date(timeIntervalSince1970: 1100))
  try await store.finish()
}
@Test func configChangeWithUnchangedIPCreatesHistory() async throws {
  let dir = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }
  let url = dir.appendingPathComponent("history.sqlite")
  let store = HistoryStore(url: dir.appendingPathComponent("history.sqlite"))
  _ = try await store.beginSession()
  _ = try await store.applyCheck(sample())
  let dns = ConfigurationGroup(
    source: "service", status: .available, values: ["ServerAddresses": ["1.1.1.1"]])
  _ = try await store.applyCheck(sample(at: 1100, network: .init(path: "satisfied", dns: [dns])))
  let rows = try await HistoryReader(url: url).page(filter: .init(category: "state"))
  #expect(rows.count == 2)
  #expect(rows[0].tags == ["DNS"])
  try await store.finish()
}
@Test func clearPreservesCurrentAndSequenceUntilChange() async throws {
  let dir = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }
  let url = dir.appendingPathComponent("history.sqlite")
  let store = HistoryStore(url: dir.appendingPathComponent("history.sqlite"))
  _ = try await store.beginSession()
  let first = try await store.applyCheck(sample())
  try await store.clearHistory()
  let current = await store.savedState()
  #expect(current?.observation.v4.address?.text == "8.8.8.8")
  #expect(current?.activeRecordID == nil)
  _ = try await store.applyCheck(sample(at: 1100))
  let reader = HistoryReader(url: url)
  #expect(try await reader.count(filter: .init()) == 0)
  let changed = try await store.applyCheck(sample(at: 1200, ip: "1.1.1.1"))
  #expect(changed.activeRecordID! > first.activeRecordID!)
  try await store.finish()
}
@Test func markersHaveNoAddressesAndCloseObservations() async throws {
  let dir = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }
  let url = dir.appendingPathComponent("history.sqlite")
  let store = HistoryStore(url: dir.appendingPathComponent("history.sqlite"))
  _ = try await store.beginSession()
  _ = try await store.applyCheck(sample())
  try await store.marker("pause")
  try await store.marker("resume")
  _ = try await store.applyCheck(sample(at: 1100))
  let reader = HistoryReader(url: url)
  let rows = try await reader.page(filter: .init())
  #expect(rows.filter { $0.kind == "state" }.count == 2)
  #expect(
    rows.filter { $0.kind != "state" }.allSatisfy {
      $0.firstObservation == nil && $0.confirmationSummary.lastConfirmedV4At == nil
    })
  #expect(rows.last { $0.kind == "state" }?.confirmationSummary.closeReason == "pause")
  try await store.finish()
}
@Test func exportIsParseableAndFormulaSafe() async throws {
  let dir = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }
  let url = dir.appendingPathComponent("history.sqlite")
  let store = HistoryStore(url: dir.appendingPathComponent("history.sqlite"))
  _ = try await store.beginSession()
  var o = sample()
  o.v4.geo = .init(status: "found", country: "=formula", city: "A,\"B\" 中文")
  _ = try await store.applyCheck(o)
  let reader = HistoryReader(url: url)
  let json = dir.appendingPathComponent("out.json")
  let csv = dir.appendingPathComponent("out.csv")
  let n = try await reader.export(to: json, format: "json", filter: .init())
  #expect(n == 2)
  let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [String: Any]
  #expect((parsed?["records"] as? [Any])?.count == 2)
  _ = try await reader.export(to: csv, format: "csv", filter: .init())
  let data = try Data(contentsOf: csv)
  #expect(data.prefix(3) == Data([0xEF, 0xBB, 0xBF]))
  let text = String(decoding: data, as: UTF8.self)
  #expect(text.contains("'=formula"))
  #expect(text.contains("A,\"\"B\"\" 中文"))
  #expect(HistoryReader.csvCell(" \t=1") == "\"' \t=1\"")
  try await store.finish()
}
@Test func corruptAndFutureDatabasesArePreserved() async throws {
  let dir = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }
  let url = dir.appendingPathComponent("bad.sqlite")
  let original = Data("not a database".utf8)
  try original.write(to: url)
  await #expect(throws: (any Error).self) { try await HistoryStore(url: url).open() }
  #expect(try Data(contentsOf: url) == original)
  let future = dir.appendingPathComponent("future.sqlite")
  var db: OpaquePointer?
  sqlite3_open(future.path, &db)
  sqlite3_exec(db, "PRAGMA user_version=99", nil, nil, nil)
  sqlite3_close(db)
  await #expect(throws: (any Error).self) { try await HistoryStore(url: future).open() }
}
@Test func realBundledCReaderAndMissingDatabase() async throws {
  let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()
  let geo = GeoResolver(directory: root.appendingPathComponent("data/ip2region"))
  #expect(await geo.lookup(IPAddress("113.118.113.77")!).status == "found")
  #expect(await geo.lookup(IPAddress("2604:a840:3::a04d")!).status == "found")
  #expect(await geo.lookup(IPAddress("192.168.1.1")!).status == "non_public")
  let dir = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }
  #expect(await GeoResolver(directory: dir).lookup(IPAddress("8.8.8.8")!).status == "unavailable")
  let truncated = dir.appendingPathComponent("truncated.xdb")
  try Data(repeating: 0, count: 256).write(to: truncated)
  #expect(throws: (any Error).self) {
    try GeoResolver.validateFile(truncated, identity: DatabaseIdentity.bundled[0])
  }
  var header = Data(repeating: 0, count: 256)
  header[0] = 3
  header[16] = 4
  header[18] = 255
  #expect(throws: (any Error).self) {
    try GeoResolver.validateHeader(header, length: 11_122_036, family: .v4)
  }
}

actor CountingProbe: IPProbing {
  var calls = 0
  var active = 0
  var maximum = 0
  let delay: Double
  init(delay: Double = 0.05) { self.delay = delay }
  func probe(_ family: Family) async -> ProbeResult {
    calls += 1
    active += 1
    maximum = max(maximum, active)
    await withCheckedContinuation { c in
      DispatchQueue.global().asyncAfter(deadline: .now() + delay) { c.resume() }
    }
    active -= 1
    return .init(
      family: family, status: "confirmed",
      address: IPAddress(family == .v4 ? "8.8.8.8" : "2606:4700:4700::1111"))
  }
}
func waitUntil(_ predicate: () async -> Bool) async throws {
  for _ in 0..<300 {
    if await predicate() { return }
    try await Task.sleep(for: .milliseconds(10))
  }
  throw RecordError.message("Timed out waiting for test state")
}
@Test func staleEpochAndPausedCallbacksNeverCommit() async throws {
  let dir = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }
  let url = dir.appendingPathComponent("history.sqlite")
  let store = HistoryStore(url: dir.appendingPathComponent("history.sqlite"))
  let probe = CountingProbe(delay: 0.15)
  let epoch = EventEpoch()
  let engine = RecordingEngine(
    store: store, geo: GeoResolver(directory: dir), probe: probe, epoch: epoch, systemEvents: false,
    snapshot: { _ in .init(path: "satisfied") })
  await engine.start(paused: false)
  try await waitUntil { await probe.calls == 2 }
  epoch.bump()
  epoch.bump()  // A→B→A: content can be identical; event version is not.
  await engine.pause()
  try await Task.sleep(for: .milliseconds(200))
  #expect(try await HistoryReader(url: url).count(filter: .init(category: "state")) == 0)
  #expect(await engine.status().paused)
  await engine.sleep()
  await engine.wake()
  await engine.checkNow()
  #expect(await probe.calls == 2)
  #expect(await engine.status().paused)
  await engine.stop()
}
@Test func overlappingManualTriggersShareOneRound() async throws {
  let dir = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }
  let probe = CountingProbe(delay: 0.1)
  let store = HistoryStore(url: dir.appendingPathComponent("history.sqlite"))
  let engine = RecordingEngine(
    store: store, geo: GeoResolver(directory: dir), probe: probe, systemEvents: false,
    snapshot: { _ in .init(path: "satisfied") })
  await engine.start(paused: false)
  for _ in 0..<30 { await engine.checkNow() }
  try await waitUntil { await engine.status().rounds == 1 }
  await engine.checkNow()
  #expect(await probe.calls == 2)
  #expect(await probe.maximum == 2)
  #expect(await engine.status().saved?.observation.v4.status == "confirmed")
  await engine.stop()
}
@Test func commitEpochGuardRollsBack() async throws {
  let dir = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }
  let url = dir.appendingPathComponent("history.sqlite")
  let store = HistoryStore(url: dir.appendingPathComponent("history.sqlite"))
  _ = try await store.beginSession()
  await #expect(throws: CancellationError.self) {
    _ = try await store.applyCheck(sample(), isValid: { false })
  }
  #expect(try await HistoryReader(url: url).count(filter: .init(category: "state")) == 0)
  try await store.finish()
}
@Test func storageFaultStopsRequestsAndRecoveryPreservesPause() async throws {
  let dir = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }
  let url = dir.appendingPathComponent("history.sqlite")
  let store = HistoryStore(url: dir.appendingPathComponent("history.sqlite"))
  let probe = CountingProbe(delay: 0.1)
  let engine = RecordingEngine(
    store: store, geo: GeoResolver(directory: dir), probe: probe, systemEvents: false,
    snapshot: { _ in .init(path: "satisfied") })
  await engine.start(paused: false)
  try await waitUntil { await probe.calls == 2 }
  var db: OpaquePointer?
  sqlite3_open(url.path, &db)
  sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil)
  try await waitUntil { await engine.status().storageError != nil }
  #expect(await engine.status().saved == nil)
  #expect(await engine.status().unsaved != nil)
  await engine.checkNow()
  #expect(await probe.calls == 2)
  await engine.pause()
  sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
  sqlite3_close(db)
  await engine.retryStorage()
  await engine.sleep()
  await engine.wake()
  #expect(await engine.status().storageError == nil)
  #expect(await engine.status().paused)
  #expect(await probe.calls == 2)
  await engine.stop()
}

@Test func exportCancellationPreservesDestinationAndRemovesTemporaryFiles() async throws {
  let dir = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }
  let url = dir.appendingPathComponent("history.sqlite")
  let store = HistoryStore(url: dir.appendingPathComponent("history.sqlite"))
  _ = try await store.beginSession()
  _ = try await store.applyCheck(sample())
  let target = dir.appendingPathComponent("export.json")
  try Data("keep".utf8).write(to: target)
  let reader = HistoryReader(url: url)
  let task = Task { try await reader.export(to: target, format: "json", filter: .init()) }
  task.cancel()
  await #expect(throws: CancellationError.self) { _ = try await task.value }
  #expect(try Data(contentsOf: target) == Data("keep".utf8))
  #expect(
    try FileManager.default.contentsOfDirectory(atPath: dir.path).allSatisfy {
      !$0.hasPrefix(".iprecord-export-")
    })
  try await store.finish()
}
@Test func keysetPaginationWithHundredThousandSyntheticRecords() async throws {
  let dir = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }
  let url = dir.appendingPathComponent("history.sqlite")
  let store = HistoryStore(url: dir.appendingPathComponent("history.sqlite"))
  _ = try await store.beginSession()
  _ = try await store.applyCheck(sample())
  var db: OpaquePointer?
  sqlite3_open(url.path, &db)
  defer { sqlite3_close(db) }
  let columns =
    "session_id,kind,observed_at,timezone_offset,uptime,triggers,context_id,signature,snapshot_json,tags,search_text,v4,v6,last_checked_at,confirmed_v4_at,confirmed_v6_at"
  sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil)
  for _ in 0..<17 {
    #expect(
      sqlite3_exec(
        db,
        "INSERT INTO history_records(\(columns)) SELECT \(columns) FROM history_records WHERE kind='state'",
        nil, nil, nil) == SQLITE_OK)
  }
  sqlite3_exec(db, "DELETE FROM history_records WHERE id>100001", nil, nil, nil)
  sqlite3_exec(db, "COMMIT", nil, nil, nil)
  let reader = HistoryReader(url: url)
  let start = ProcessInfo.processInfo.systemUptime
  let page = try await reader.page(filter: .init(category: "state"))
  let elapsed = ProcessInfo.processInfo.systemUptime - start
  #expect(page.count == 100)
  #expect(elapsed < 0.5)
  let second = try await reader.page(filter: .init(category: "state"), before: page.last?.id)
  #expect(second.count == 100)
  #expect(second.first!.id < page.last!.id)
  #expect(try await reader.count(filter: .init(category: "state")) == 100000)
  #expect(try await reader.count(filter: .init(search: "' OR 1=1 --")) == 0)
  print("SYNTHETIC_100K_PAGE_MS=\(Int(elapsed*1000))")
  try await store.finish()
}

final class SimulationInputs: @unchecked Sendable {
  private let lock = NSLock()
  private var time: TimeInterval = 0
  private var network = NetworkSnapshot(path: "satisfied")
  func clock() -> TimeInterval {
    lock.lock()
    defer { lock.unlock() }
    return time
  }
  func snapshot() -> NetworkSnapshot {
    lock.lock()
    defer { lock.unlock() }
    return network
  }
  func set(time: TimeInterval, network: NetworkSnapshot? = nil) {
    lock.lock()
    defer { lock.unlock() }
    self.time = time
    if let network { self.network = network }
  }
}
@Test func eventStormDefersPublicRequestsButSavesLocalChanges() async throws {
  let dir = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }
  let input = SimulationInputs()
  let probe = CountingProbe(delay: 0.001)
  let epoch = EventEpoch()
  let engine = RecordingEngine(
    store: HistoryStore(url: dir.appendingPathComponent("history.sqlite")),
    geo: GeoResolver(directory: dir), probe: probe, epoch: epoch, systemEvents: false,
    clock: { input.clock() }, snapshot: { _ in input.snapshot() })
  await engine.start(paused: false)
  try await waitUntil { await engine.status().rounds == 1 }
  for i in 1...20 {
    input.set(
      time: Double(i * 3),
      network: .init(
        path: "satisfied",
        dns: [
          .init(
            source: "simulation", status: .available,
            values: ["ServerAddresses": ["192.168.1.\(i)"]])
        ]))
    epoch.bump()
    await engine.networkEvent("configuration")
    input.set(time: Double(i * 3 + 2))
    await engine.flushEvents()
    try await waitUntil { await engine.status().rounds == i + 1 }
  }
  #expect(await probe.calls == 6)
  #expect(await probe.maximum <= 2)
  let rows = try await HistoryReader(url: dir.appendingPathComponent("history.sqlite")).page(
    filter: .init(category: "state"))
  #expect(rows.count == 21)
  #expect(
    rows.filter { $0.firstObservation?.v4.status == "deferredCooldown" }.allSatisfy {
      $0.firstObservation?.v4.address == nil
    })
  await engine.stop()
}
@Test func unannouncedSnapshotChangeDiscardsInFlightResults() async throws {
  let dir = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }
  let input = SimulationInputs()
  let probe = CountingProbe(delay: 0.1)
  let engine = RecordingEngine(
    store: HistoryStore(url: dir.appendingPathComponent("history.sqlite")),
    geo: GeoResolver(directory: dir), probe: probe, systemEvents: false,
    snapshot: { _ in input.snapshot() })
  await engine.start(paused: false)
  try await waitUntil { await probe.calls == 2 }
  input.set(time: 1, network: .init(path: "unsatisfied"))
  try await Task.sleep(for: .milliseconds(160))
  #expect(await engine.status().saved == nil)
  #expect(
    try await HistoryReader(url: dir.appendingPathComponent("history.sqlite")).count(
      filter: .init(category: "state")) == 0)
  await engine.stop()
}
@Test func noPathRetainsLocalAddressesWithoutPublicRequests() async throws {
  let dir = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }
  let probe = CountingProbe()
  let network = NetworkSnapshot(
    path: "unsatisfied",
    addresses: [.init(interface: "en0", type: "Wi-Fi", ip: IPAddress("192.168.1.2")!)])
  let engine = RecordingEngine(
    store: HistoryStore(url: dir.appendingPathComponent("history.sqlite")),
    geo: GeoResolver(directory: dir), probe: probe, systemEvents: false, snapshot: { _ in network })
  await engine.start(paused: false)
  try await waitUntil { await engine.status().rounds == 1 }
  #expect(await probe.calls == 0)
  #expect(await engine.status().saved?.observation.v4.status == "skippedNoPath")
  #expect(await engine.status().saved?.observation.network.addresses.count == 1)
  await engine.stop()
}
@Test func backwardsWallClockDoesNotReorderIDs() async throws {
  let dir = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }
  let url = dir.appendingPathComponent("history.sqlite")
  let store = HistoryStore(url: dir.appendingPathComponent("history.sqlite"))
  _ = try await store.beginSession()
  _ = try await store.applyCheck(sample(at: 2000))
  var earlier = sample(at: 1000, ip: "1.1.1.1")
  earlier.timezoneOffset = -18000
  _ = try await store.applyCheck(earlier)
  let rows = try await HistoryReader(url: url).page(filter: .init(category: "state"))
  #expect(rows[0].id > rows[1].id)
  #expect(rows[0].observedAt < rows[1].observedAt)
  #expect(rows[0].timezoneOffset == -18000)
  try await store.finish()
}
@Test func exportDeadlinePreservesExistingFile() async throws {
  let dir = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }
  let url = dir.appendingPathComponent("history.sqlite")
  let store = HistoryStore(url: dir.appendingPathComponent("history.sqlite"))
  _ = try await store.beginSession()
  _ = try await store.applyCheck(sample())
  let target = dir.appendingPathComponent("out.json")
  try Data("keep".utf8).write(to: target)
  await #expect(throws: (any Error).self) {
    _ = try await HistoryReader(url: url).export(
      to: target, format: "json", filter: .init(), maximumDuration: 0)
  }
  #expect(try Data(contentsOf: target) == Data("keep".utf8))
  #expect(
    try FileManager.default.contentsOfDirectory(atPath: dir.path).allSatisfy {
      !$0.hasPrefix(".iprecord-export-")
    })
  try await store.finish()
}
