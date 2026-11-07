import Foundation
import CSQLite

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
private enum SQLValue { case text(String), number(Double), integer(Int64), null }
// Connection and statements stay in the owning actor (or export's single task).
private final class SQLiteConnection: @unchecked Sendable {
    var db: OpaquePointer?
    init(url: URL, readOnly: Bool = false) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX : SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK else { let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开历史文件"; if db != nil { sqlite3_close(db) }; db = nil; throw RecordError.message(message) }
        sqlite3_busy_timeout(db, 1000)
        try execute("PRAGMA foreign_keys=ON")
        if readOnly { try execute("PRAGMA query_only=ON") }
    }
    deinit { sqlite3_close(db) }
    func execute(_ sql: String, _ values: [SQLValue] = []) throws { let stmt = try prepare(sql, values); defer { sqlite3_finalize(stmt) }; let rc = sqlite3_step(stmt); guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw error() } }
    func prepare(_ sql: String, _ values: [SQLValue] = []) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw error() }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1); let rc: Int32
            switch value {
            case .text(let text): rc = sqlite3_bind_text(stmt, index, text, -1, transient)
            case .number(let n): rc = sqlite3_bind_double(stmt, index, n)
            case .integer(let n): rc = sqlite3_bind_int64(stmt, index, n)
            case .null: rc = sqlite3_bind_null(stmt, index)
            }
            if rc != SQLITE_OK { sqlite3_finalize(stmt); throw error() }
        }
        return stmt
    }
    func error() -> RecordError { .message(db.map { String(cString: sqlite3_errmsg($0)) } ?? "历史文件已关闭") }
    func rows(_ sql: String, _ values: [SQLValue] = []) throws -> [[String: String]] {
        let stmt = try prepare(sql, values); defer { sqlite3_finalize(stmt) }
        var rows: [[String: String]] = []
        while true {
            let rc = sqlite3_step(stmt); if rc == SQLITE_DONE { return rows }; guard rc == SQLITE_ROW else { throw error() }
            var row: [String: String] = [:]
            for col in 0..<sqlite3_column_count(stmt) {
                if let value = sqlite3_column_text(stmt, col) { row[String(cString: sqlite3_column_name(stmt, col))] = String(cString: value) }
            }
            rows.append(row)
        }
    }
    func transaction<T>(_ block: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let result = try block(); try execute("COMMIT"); return result }
        catch { try? execute("ROLLBACK"); throw error }
    }
    func backup(to url: URL) throws {
        let target = try SQLiteConnection(url: url)
        guard let backup = sqlite3_backup_init(target.db, "main", db, "main") else { throw target.error() }
        let rc = sqlite3_backup_step(backup, -1); let finish = sqlite3_backup_finish(backup)
        guard rc == SQLITE_DONE, finish == SQLITE_OK else { throw target.error() }
    }
}
private func milliseconds(_ date: Date) -> SQLValue { .number((date.timeIntervalSince1970 * 1000).rounded()) }
private func optionalDate(_ date: Date?) -> SQLValue { date.map(milliseconds) ?? .null }
private func dateValue(_ value: String?) -> Date? { value.flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) } }
private func encodeString<T: Encodable>(_ value: T) throws -> String { String(decoding: try jsonEncoder().encode(value), as: UTF8.self) }
public struct ConfirmationSummary: Codable, Equatable, Sendable {
    public var lastCheckedAt: Date?; public var lastConfirmedV4At: Date?; public var lastConfirmedV6At: Date?; public var closedAt: Date?; public var closeReason: String?
}
public struct HistoryRecord: Codable, Sendable, Identifiable {
    public var id: Int64; public var sessionID: String; public var kind: String; public var observedAt: Date; public var timezoneOffset: Int
    public var tags: [String]; public var firstObservation: Observation?; public var confirmationSummary: ConfirmationSummary; public var previousStateRecordID: Int64?
    public var title: String { kind == "state" ? tags.joined(separator: "、") : Self.markerTitle(kind) }
    public static func markerTitle(_ kind: String) -> String {
        ["appStart": "应用启动", "appExit": "应用退出", "pause": "暂停记录", "resume": "恢复记录", "sleep": "机器睡眠", "wake": "机器唤醒", "uncleanGap": "异常中断空档", "storageGap": "存储故障空档"][kind] ?? kind
    }
    fileprivate init(row: [String: String]) throws {
        guard let id = row["id"].flatMap(Int64.init), let observed = dateValue(row["observed_at"]) else { throw RecordError.message("历史行损坏") }
        self.id = id; sessionID = row["session_id"] ?? ""; kind = row["kind"] ?? "state"; observedAt = observed; timezoneOffset = row["timezone_offset"].flatMap(Int.init) ?? 0
        tags = (row["tags"] ?? "").components(separatedBy: "|").filter { !$0.isEmpty }
        firstObservation = try row["snapshot_json"].map { try jsonDecoder().decode(Observation.self, from: Data($0.utf8)) }
        confirmationSummary = .init(lastCheckedAt: dateValue(row["last_checked_at"]), lastConfirmedV4At: dateValue(row["confirmed_v4_at"]), lastConfirmedV6At: dateValue(row["confirmed_v6_at"]), closedAt: dateValue(row["closed_at"]), closeReason: row["close_reason"])
        previousStateRecordID = row["previous_state_record_id"].flatMap(Int64.init)
    }
}
public struct HistoryFilter: Codable, Equatable, Sendable {
    public var since: Date?; public var until: Date?; public var category: String; public var search: String
    public init(since: Date? = nil, until: Date? = nil, category: String = "all", search: String = "") { self.since = since; self.until = until; self.category = category; self.search = search }
    fileprivate func clause(before: Int64? = nil) -> (String, [SQLValue]) {
        var clauses = ["1=1"], values: [SQLValue] = []
        if let since { clauses.append("observed_at>=?"); values.append(milliseconds(since)) }
        if let until { clauses.append("observed_at<=?"); values.append(milliseconds(until)) }
        if let before { clauses.append("id<?"); values.append(.integer(before)) }
        if category == "state" { clauses.append("kind='state'") }
        else if category == "gaps" { clauses.append("kind!='state'") }
        else if category != "all" { clauses.append("kind='state' AND instr('|'||tags||'|',?)>0"); values.append(.text("|" + category + "|")) }
        if !search.isEmpty { clauses.append("instr(lower(search_text),lower(?))>0"); values.append(.text(search)) }
        return (clauses.joined(separator: " AND "), values)
    }
}
public struct SavedState: Sendable { public var observation: Observation; public var activeRecordID: Int64?; public var savedAt: Date }
public actor HistoryStore {
    public let url: URL
    private var connection: SQLiteConnection?
    private var sessionID: String?
    private var current: SavedState?
    private var baseline = true
    private var suppressed = false
    public init(url: URL) { self.url = url }
    public func open() throws {
        if connection != nil { return }
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.deletingLastPathComponent().path)
        let db = try SQLiteConnection(url: url)
        let version = Int(try db.rows("PRAGMA user_version").first?["user_version"] ?? "0") ?? 0
        guard version <= 1 else { throw RecordError.message("历史来自更新版本，已停止写入以保留原文件") }
        let check = try db.rows("PRAGMA quick_check").first?.values.first
        guard check == "ok" else { throw RecordError.message("历史文件校验失败，已保留原文件") }
        if version == 0 {
            let tables = try db.rows("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")
            guard tables.isEmpty else { throw RecordError.message("无法识别已有历史结构，已保留原文件") }
            // Every future migration must run backup before changing an existing schema.
            try db.transaction {
                try db.execute("CREATE TABLE schema_migrations(version INTEGER PRIMARY KEY, app_version TEXT NOT NULL, executed_at REAL NOT NULL)")
                try db.execute("CREATE TABLE app_sessions(id TEXT PRIMARY KEY, started_at REAL NOT NULL, last_checkpoint_at REAL NOT NULL, ended_at REAL, clean_exit INTEGER NOT NULL DEFAULT 0, timezone_offset INTEGER NOT NULL)")
                try db.execute("""
                CREATE TABLE history_records(
                    id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL REFERENCES app_sessions(id),
                    kind TEXT NOT NULL, observed_at REAL NOT NULL, timezone_offset INTEGER NOT NULL, uptime REAL NOT NULL,
                    triggers TEXT NOT NULL, context_id TEXT, signature TEXT, snapshot_json TEXT, schema_version INTEGER NOT NULL DEFAULT 1,
                    tags TEXT NOT NULL, search_text TEXT NOT NULL, v4 TEXT, v6 TEXT,
                    last_checked_at REAL, confirmed_v4_at REAL, confirmed_v6_at REAL, closed_at REAL, close_reason TEXT,
                    previous_state_record_id INTEGER REFERENCES history_records(id) ON DELETE SET NULL)
                """)
                try db.execute("CREATE TABLE current_state(id INTEGER PRIMARY KEY CHECK(id=1), active_state_record_id INTEGER REFERENCES history_records(id) ON DELETE SET NULL, payload_json TEXT NOT NULL, signature TEXT NOT NULL, saved_at REAL NOT NULL)")
                for column in ["observed_at", "kind", "v4", "v6"] { try db.execute("CREATE INDEX history_\(column) ON history_records(\(column))") }
                try db.execute("INSERT INTO schema_migrations VALUES(1,'1.0.0',?)", [milliseconds(Date())]); try db.execute("PRAGMA user_version=1")
            }
        }
        try db.execute("PRAGMA journal_mode=WAL"); try db.execute("PRAGMA synchronous=FULL"); try db.execute("PRAGMA wal_autocheckpoint=256")
        if let row = try db.rows("SELECT * FROM current_state WHERE id=1").first, let payload = row["payload_json"] {
            current = .init(observation: try jsonDecoder().decode(Observation.self, from: Data(payload.utf8)), activeRecordID: row["active_state_record_id"].flatMap(Int64.init), savedAt: dateValue(row["saved_at"]) ?? Date())
        }
        connection = db
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public func beginSession(now: Date = Date()) throws -> SavedState? {
        try open(); guard sessionID == nil, let db = connection else { return current }
        let id = UUID().uuidString
        try db.transaction {
            let old = try db.rows("SELECT * FROM app_sessions ORDER BY rowid DESC LIMIT 1").first
            try db.execute("INSERT INTO app_sessions(id,started_at,last_checkpoint_at,timezone_offset) VALUES(?,?,?,?)", [.text(id), milliseconds(now), milliseconds(now), .integer(Int64(TimeZone.current.secondsFromGMT(for: now)))])
            if old?["clean_exit"] == "0" { try insertMarker(db, kind: "uncleanGap", session: id, now: now) }
            try insertMarker(db, kind: "appStart", session: id, now: now)
        }
        sessionID = id; baseline = true; current?.activeRecordID = nil
        return current
    }
    private func insertMarker(_ db: SQLiteConnection, kind: String, session: String, now: Date) throws {
        let previous = current?.activeRecordID.map(SQLValue.integer) ?? .null
        try db.execute("UPDATE history_records SET closed_at=?,close_reason=? WHERE id=(SELECT active_state_record_id FROM current_state WHERE id=1) AND closed_at IS NULL", [milliseconds(now), .text(kind)])
        try db.execute("UPDATE current_state SET active_state_record_id=NULL WHERE id=1")
        try db.execute("INSERT INTO history_records(session_id,kind,observed_at,timezone_offset,uptime,triggers,tags,search_text,previous_state_record_id) VALUES(?,?,?,?,?,?,?,?,?)", [.text(session),.text(kind),milliseconds(now),.integer(Int64(TimeZone.current.secondsFromGMT(for: now))),.number(ProcessInfo.processInfo.systemUptime),.text(kind),.text("记录空档"),.text(HistoryRecord.markerTitle(kind)),previous])
    }
    public func marker(_ kind: String, now: Date = Date()) throws {
        guard let db = connection, let sessionID else { throw RecordError.message("历史尚未就绪") }
        try db.transaction { try insertMarker(db, kind: kind, session: sessionID, now: now); try db.execute("UPDATE app_sessions SET last_checkpoint_at=? WHERE id=?", [milliseconds(now),.text(sessionID)]) }
        baseline = true; suppressed = false; current?.activeRecordID = nil
    }
    public func applyCheck(_ incoming: Observation, isValid: @Sendable () -> Bool = { true }) throws -> SavedState {
        guard isValid() else { throw CancellationError() }
        guard let db = connection, let sessionID else { throw RecordError.message("历史尚未就绪") }
        var observation = incoming
        // Last-known always comes from the newest committed summary, never an immutable first snapshot.
        if let old = current?.observation { observation.v4.lastKnown = old.known(.v4); observation.v6.lastKnown = old.known(.v6) }
        let signature = observation.fingerprint
        var active = current?.activeRecordID
        let changed = current?.observation.fingerprint != signature
        let create = changed || (baseline && !suppressed)
        let tags = observation.changes(from: baseline ? nil : current?.observation)
        let savedAt = Date()
        try db.transaction {
            guard isValid() else { throw CancellationError() }
            let c4 = observation.known(.v4)?.confirmedAt, c6 = observation.known(.v6)?.confirmedAt
            if create {
                try db.execute("UPDATE history_records SET closed_at=?,close_reason='stateChange' WHERE id=? AND closed_at IS NULL", [milliseconds(observation.completedAt), active.map(SQLValue.integer) ?? .null])
                try db.execute("""
                INSERT INTO history_records(session_id,kind,observed_at,timezone_offset,uptime,triggers,context_id,signature,snapshot_json,tags,search_text,v4,v6,last_checked_at,confirmed_v4_at,confirmed_v6_at,previous_state_record_id)
                VALUES(?,'state',?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, [.text(sessionID),milliseconds(observation.startedAt),.integer(Int64(observation.timezoneOffset)),.number(observation.uptime),.text(observation.triggers.joined(separator: ",")),.text(observation.contextID),.text(signature),.text(try encodeString(observation)),.text(tags.joined(separator: "|")),.text(observation.searchText),observation.v4.address.map { .text($0.text) } ?? .null,observation.v6.address.map { .text($0.text) } ?? .null,milliseconds(observation.completedAt),optionalDate(c4),optionalDate(c6),active.map(SQLValue.integer) ?? .null])
                active = sqlite3_last_insert_rowid(db.db)
            } else if let active {
                try db.execute("UPDATE history_records SET last_checked_at=?,confirmed_v4_at=?,confirmed_v6_at=? WHERE id=? AND closed_at IS NULL AND kind='state'", [milliseconds(observation.completedAt),optionalDate(c4),optionalDate(c6),.integer(active)])
            }
            try db.execute("INSERT INTO current_state(id,active_state_record_id,payload_json,signature,saved_at) VALUES(1,?,?,?,?) ON CONFLICT(id) DO UPDATE SET active_state_record_id=excluded.active_state_record_id,payload_json=excluded.payload_json,signature=excluded.signature,saved_at=excluded.saved_at", [active.map(SQLValue.integer) ?? .null,.text(try encodeString(observation)),.text(signature),milliseconds(savedAt)])
            try db.execute("UPDATE app_sessions SET last_checkpoint_at=? WHERE id=?", [milliseconds(observation.completedAt),.text(sessionID)])
            guard isValid() else { throw CancellationError() }
        }
        baseline = false; if create { suppressed = false }
        let state = SavedState(observation: observation, activeRecordID: active, savedAt: savedAt); current = state
        return state
    }
    public func clearHistory() throws {
        guard let db = connection else { throw RecordError.message("历史尚未就绪") }
        try db.transaction { try db.execute("UPDATE current_state SET active_state_record_id=NULL WHERE id=1"); try db.execute("DELETE FROM history_records") }
        current?.activeRecordID = nil; suppressed = true; baseline = false
        try? db.execute("PRAGMA wal_checkpoint(PASSIVE)")
    }
    public func retry() throws {
        try open()
        if sessionID == nil { _ = try beginSession() }
        try marker("storageGap")
    }
    public func finish(now: Date = Date()) throws {
        guard let db = connection, let sessionID else { return }
        try db.transaction {
            try insertMarker(db, kind: "appExit", session: sessionID, now: now)
            try db.execute("UPDATE app_sessions SET ended_at=?,last_checkpoint_at=?,clean_exit=1 WHERE id=?", [milliseconds(now),milliseconds(now),.text(sessionID)])
        }
        self.sessionID = nil; try? db.execute("PRAGMA wal_checkpoint(PASSIVE)"); connection = nil
    }
    public func savedState() -> SavedState? { current }
}
public actor HistoryReader {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func page(filter: HistoryFilter, before: Int64? = nil, limit: Int = 100) throws -> [HistoryRecord] {
        let db = try SQLiteConnection(url: url, readOnly: true); let (clause, values) = filter.clause(before: before)
        return try db.rows("SELECT * FROM history_records WHERE \(clause) ORDER BY id DESC LIMIT ?", values + [.integer(Int64(min(max(limit, 1), 500)))]).map(HistoryRecord.init)
    }
    public func count(filter: HistoryFilter) throws -> Int {
        let db = try SQLiteConnection(url: url, readOnly: true); let (clause, values) = filter.clause()
        return Int(try db.rows("SELECT count(*) AS n FROM history_records WHERE \(clause)", values).first?["n"] ?? "0") ?? 0
    }
    public func previousState(before id: Int64) throws -> HistoryRecord? {
        let db = try SQLiteConnection(url: url, readOnly: true)
        return try db.rows("SELECT * FROM history_records WHERE id<? AND kind='state' ORDER BY id DESC LIMIT 1", [.integer(id)]).first.map(HistoryRecord.init)
    }
    public func export(to destination: URL, format: String, filter: HistoryFilter, progress: @Sendable (Int, Int) -> Void = { _, _ in }) throws -> Int {
        let db = try SQLiteConnection(url: url, readOnly: true)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".iprecord-export-" + UUID().uuidString)
        let fm = FileManager.default; let started = ProcessInfo.processInfo.systemUptime
        guard fm.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw RecordError.message("无法创建导出文件") }
        let file = try FileHandle(forWritingTo: temporary)
        defer { try? file.close(); try? fm.removeItem(at: temporary); try? db.execute("ROLLBACK") }
        try db.execute("BEGIN")
        let (clause, values) = filter.clause()
        let count = Int(try db.rows("SELECT count(*) AS n FROM history_records WHERE \(clause)", values).first?["n"] ?? "0") ?? 0
        func check() throws { try Task.checkCancellation(); if ProcessInfo.processInfo.systemUptime - started > 120 { throw RecordError.message("导出超过两分钟，请缩小日期范围重试") } }
        func write(_ text: String) throws { try file.write(contentsOf: Data(text.utf8)) }
        if format == "json" { try write("{\"schemaVersion\":1,\"exportedAt\":\(Int(Date().timeIntervalSince1970*1000)),\"filter\":\(try encodeString(filter)),\"recordCount\":\(count),\"records\":[\n") }
        else { try file.write(contentsOf: Data([0xEF,0xBB,0xBF])); try write(Self.csvHeader.joined(separator: ",") + "\r\n") }
        var cursor: Int64?, written = 0
        while true {
            try check()
            let (pageClause, pageValues) = filter.clause(before: cursor)
            let rows = try db.rows("SELECT * FROM history_records WHERE \(pageClause) ORDER BY id DESC LIMIT 500", pageValues)
            if rows.isEmpty { break }
            for row in rows {
                try check(); let record = try HistoryRecord(row: row)
                if format == "json" { if written > 0 { try write(",\n") }; try write(try encodeString(record)) }
                else { try write(Self.csvRow(record).map(Self.csvCell).joined(separator: ",") + "\r\n") }
                written += 1; cursor = record.id
            }
            progress(written, count)
        }
        if format == "json" { try write("\n]}\n") }
        try check(); try file.synchronize(); try file.close(); try db.execute("COMMIT")
        // rename on the same volume is atomic and preserves an existing destination on failure.
        guard Darwin.rename(temporary.path, destination.path) == 0 else { throw RecordError.message("无法完成导出文件替换") }
        return written
    }
    public static func csvCell(_ raw: String) -> String {
        let first = raw.drop(while: { $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\n" }).first
        let safe = first.map { "=+-@".contains($0) } == true ? "'" + raw : raw
        return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    private static let csvHeader = ["record_id","session_id","kind","tags","first_observed_utc","timezone_offset_seconds","last_checked_utc"] + ["v4","v6"].flatMap { f in ["address","status","last_confirmed_utc","country","province","city","organization","endpoint","database_hash"].map { f + "_" + $0 } } + ["local_addresses","gateways","dns_partial","proxy_configuration","triggers"]
    private static func csvRow(_ record: HistoryRecord) -> [String] {
        let iso = ISO8601DateFormatter(); func time(_ date: Date?) -> String { date.map(iso.string) ?? "" }
        let o = record.firstObservation
        var fields = [String(record.id),record.sessionID,record.kind,record.tags.joined(separator: ";"),time(record.observedAt),String(record.timezoneOffset),time(record.confirmationSummary.lastCheckedAt)]
        for (p, confirmed) in [(o?.v4,record.confirmationSummary.lastConfirmedV4At),(o?.v6,record.confirmationSummary.lastConfirmedV6At)] {
            fields += [p?.address?.text ?? "",p?.status ?? "",time(confirmed),p?.geo?.country ?? "",p?.geo?.province ?? "",p?.geo?.city ?? "",p?.geo?.isp ?? "",p?.endpoint ?? "",p?.geo?.databaseHash ?? ""]
        }
        fields += [o?.network.addresses.map { $0.interface + " " + $0.ip.text }.joined(separator: ";") ?? "", (try? encodeString(o?.network.gateways)) ?? "", (try? encodeString(o?.network.dns)) ?? "", (try? encodeString(o?.network.proxy)) ?? "", o?.triggers.joined(separator: ";") ?? ""]
        return fields
    }
}
