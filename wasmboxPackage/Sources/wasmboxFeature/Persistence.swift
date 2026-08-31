import Foundation
import SQLite3

public enum PersistenceError: Error, LocalizedError, Sendable {
  case openFailed(String)
  case queryFailed(String)
  case encodingFailed
  case decodingFailed
  case migrationFailed(String)
  case readOnly(String)

  public var errorDescription: String? {
    switch self {
    case .openFailed(let message): "Database open failed: \(message)"
    case .queryFailed(let message): "Database query failed: \(message)"
    case .encodingFailed: "Database encoding failed"
    case .decodingFailed: "Database decoding failed"
    case .migrationFailed(let message): "Database migration failed: \(message)"
    case .readOnly(let message): "Database is read-only: \(message)"
    }
  }
}

public enum StoreMutation: Sendable {
  case saveWorkload(Workload)
  case deleteWorkload(UUID)
  case saveRun(Run)
  case deleteRun(UUID)
  case appendEvent(DomainEvent)
  case saveMetrics(MetricsSample)
  case pruneMetrics(before: Date)
  case saveMissedWindow(SchedulerMissedWindow)
  case saveSchedulerCheckpoint(SchedulerCheckpoint)
}

public protocol WasmboxStore: Sendable {
  func listWorkloads() async throws -> [Workload]
  func loadWorkload(id: UUID) async throws -> Workload?
  func saveWorkload(_ workload: Workload) async throws
  func deleteWorkload(id: UUID) async throws
  func listRuns(workloadID: UUID) async throws -> [Run]
  func loadRun(id: UUID) async throws -> Run?
  func saveRun(_ run: Run) async throws
  func deleteRuns(workloadID: UUID) async throws
  func deleteRun(id: UUID) async throws
  func appendEvent(_ event: DomainEvent) async throws
  func listEvents(workloadID: UUID, runID: UUID?) async throws -> [DomainEvent]
  func saveMetrics(_ sample: MetricsSample) async throws
  func listMetrics(runID: UUID, since: Date?) async throws -> [MetricsSample]
  func saveMissedWindow(_ window: SchedulerMissedWindow) async throws
  func listMissedWindows(workloadID: UUID) async throws -> [SchedulerMissedWindow]
  func loadSchedulerCheckpoint(workloadID: UUID) async throws -> SchedulerCheckpoint?
  func saveSchedulerCheckpoint(_ checkpoint: SchedulerCheckpoint) async throws
  func apply(_ mutations: [StoreMutation]) async throws
}

public actor InMemoryStore: WasmboxStore {
  private var workloadsByID: [UUID: Workload] = [:]
  private var runsByID: [UUID: Run] = [:]
  private var events: [DomainEvent] = []
  private var metricSamples: [MetricsSample] = []
  private var missedWindows: [SchedulerMissedWindow] = []
  private var schedulerCheckpoints: [UUID: SchedulerCheckpoint] = [:]

  public init() {}

  public func apply(_ mutations: [StoreMutation]) async throws {
    let oldWorkloads = workloadsByID
    let oldRuns = runsByID
    let oldEvents = events
    let oldMetrics = metricSamples
    let oldWindows = missedWindows
    let oldCheckpoints = schedulerCheckpoints
    do {
      for mutation in mutations { try applyMutation(mutation) }
    } catch {
      workloadsByID = oldWorkloads
      runsByID = oldRuns
      events = oldEvents
      metricSamples = oldMetrics
      missedWindows = oldWindows
      schedulerCheckpoints = oldCheckpoints
      throw error
    }
  }

  public func listWorkloads() async throws -> [Workload] {
    workloadsByID.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  public func loadWorkload(id: UUID) async throws -> Workload? { workloadsByID[id] }

  public func saveWorkload(_ workload: Workload) async throws {
    if workloadsByID.values.contains(where: {
      $0.id != workload.id && $0.name.caseInsensitiveCompare(workload.name) == .orderedSame
    }) {
      throw ValidationError.duplicateName(workload.name)
    }
    workloadsByID[workload.id] = workload
  }

  public func deleteWorkload(id: UUID) async throws {
    let runIDs = Set(runsByID.values.filter { $0.workloadID == id }.map(\.id))
    workloadsByID.removeValue(forKey: id)
    runsByID = runsByID.filter { $0.value.workloadID != id }
    events.removeAll { $0.workloadID == id }
    metricSamples.removeAll { runIDs.contains($0.runID) }
    missedWindows.removeAll { $0.workloadID == id }
    schedulerCheckpoints.removeValue(forKey: id)
  }
  public func listRuns(workloadID: UUID) async throws -> [Run] {
    runsByID.values.filter { $0.workloadID == workloadID }.sorted {
      ($0.finishedTime ?? $0.startedTime ?? $0.createdAt ?? .distantPast)
        > ($1.finishedTime ?? $1.startedTime ?? $1.createdAt ?? .distantPast)
    }
  }

  public func loadRun(id: UUID) async throws -> Run? { runsByID[id] }

  public func saveRun(_ run: Run) async throws { runsByID[run.id] = run }

  public func deleteRuns(workloadID: UUID) async throws {
    let ids = Set(runsByID.values.filter { $0.workloadID == workloadID }.map(\.id))
    runsByID = runsByID.filter { $0.value.workloadID != workloadID }
    events.removeAll { $0.workloadID == workloadID }
    metricSamples.removeAll { ids.contains($0.runID) }
  }
  public func deleteRun(id: UUID) async throws {
    runsByID.removeValue(forKey: id)
    events.removeAll { $0.runID == id }
    metricSamples.removeAll { $0.runID == id }
  }

  public func appendEvent(_ event: DomainEvent) async throws { events.append(event) }

  public func listEvents(workloadID: UUID, runID: UUID? = nil) async throws -> [DomainEvent] {
    events.filter { $0.workloadID == workloadID && (runID == nil || $0.runID == runID) }.sorted {
      $0.occurredAt < $1.occurredAt
    }
  }

  public func saveMetrics(_ sample: MetricsSample) async throws {
    metricSamples.removeAll { $0.id == sample.id }
    metricSamples.append(sample)
  }

  public func listMetrics(runID: UUID, since: Date? = nil) async throws -> [MetricsSample] {
    metricSamples.filter { $0.runID == runID && (since == nil || $0.timestamp >= since!) }.sorted {
      $0.timestamp < $1.timestamp
    }
  }

  public func saveMissedWindow(_ window: SchedulerMissedWindow) async throws {
    missedWindows.append(window)
  }

  public func listMissedWindows(workloadID: UUID) async throws -> [SchedulerMissedWindow] {
    missedWindows.filter { $0.workloadID == workloadID }.sorted { $0.from < $1.from }
  }

  public func loadSchedulerCheckpoint(workloadID: UUID) async throws -> SchedulerCheckpoint? {
    schedulerCheckpoints[workloadID]
  }

  public func saveSchedulerCheckpoint(_ checkpoint: SchedulerCheckpoint) async throws {
    schedulerCheckpoints[checkpoint.workloadID] = checkpoint
  }

  private func applyMutation(_ mutation: StoreMutation) throws {
    switch mutation {
    case .saveWorkload(let workload):
      if workloadsByID.values.contains(where: {
        $0.id != workload.id && $0.name.caseInsensitiveCompare(workload.name) == .orderedSame
      }) {
        throw ValidationError.duplicateName(workload.name)
      }
      workloadsByID[workload.id] = workload
    case .deleteWorkload(let id):
      let runIDs = Set(runsByID.values.filter { $0.workloadID == id }.map(\.id))
      workloadsByID.removeValue(forKey: id)
      runsByID = runsByID.filter { $0.value.workloadID != id }
      events.removeAll { $0.workloadID == id }
      metricSamples.removeAll { runIDs.contains($0.runID) }
      missedWindows.removeAll { $0.workloadID == id }
      schedulerCheckpoints.removeValue(forKey: id)
    case .saveRun(let run):
      runsByID[run.id] = run
    case .deleteRun(let id):
      runsByID.removeValue(forKey: id)
      events.removeAll { $0.runID == id }
      metricSamples.removeAll { $0.runID == id }
    case .appendEvent(let event):
      events.append(event)
    case .saveMetrics(let sample):
      metricSamples.removeAll { $0.id == sample.id }
      metricSamples.append(sample)
      metricSamples.removeAll { $0.timestamp < Date().addingTimeInterval(-86_400) }
    case .pruneMetrics(let cutoff):
      metricSamples.removeAll { $0.timestamp < cutoff }
    case .saveMissedWindow(let window):
      missedWindows.removeAll { $0.id == window.id }
      missedWindows.append(window)
    case .saveSchedulerCheckpoint(let checkpoint):
      schedulerCheckpoints[checkpoint.workloadID] = checkpoint
    }
  }
}

public actor SQLiteStore: WasmboxStore {
  private let database: SQLiteDatabase
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder
  public nonisolated let migrationWarning: String?
  public nonisolated let isReadOnly: Bool

  public init(url: URL) throws {
    self.database = try SQLiteDatabase(url: url)
    self.encoder = Self.makeEncoder()
    self.decoder = Self.makeDecoder()
    database.migrate()
    self.migrationWarning = database.migrationWarning
    self.isReadOnly = database.isReadOnly
  }

  public init() throws {
    let root = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    ).appendingPathComponent("wasmbox", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    self.database = try SQLiteDatabase(url: root.appendingPathComponent("wasmbox.sqlite"))
    self.encoder = Self.makeEncoder()
    self.decoder = Self.makeDecoder()
    database.migrate()
    self.migrationWarning = database.migrationWarning
    self.isReadOnly = database.isReadOnly
  }

  private nonisolated static func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .custom { date, encoder in
      var container = encoder.singleValueContainer()
      try container.encode(date.timeIntervalSinceReferenceDate.bitPattern)
    }
    return encoder
  }

  private nonisolated static func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      if let bits = try? container.decode(UInt64.self), bits > 10_000_000_000 {
        return Date(timeIntervalSinceReferenceDate: Double(bitPattern: bits))
      }
      return Date(timeIntervalSince1970: try container.decode(Double.self))
    }
    return decoder
  }

  public func apply(_ mutations: [StoreMutation]) async throws {
    try database.transaction {
      for mutation in mutations { try applyMutation(mutation) }
    }
  }

  public func listWorkloads() async throws -> [Workload] {
    try database.query("SELECT payload FROM workloads ORDER BY name COLLATE NOCASE") { statement in
      try decode(Workload.self, from: statement, column: 0)
    }
  }

  public func loadWorkload(id: UUID) async throws -> Workload? {
    try database.query("SELECT payload FROM workloads WHERE id = ?", bindings: [id.uuidString]) {
      statement in
      try decode(Workload.self, from: statement, column: 0)
    }.first
  }

  public func saveWorkload(_ workload: Workload) async throws {
    let payload = try encode(workload)
    try database.execute(
      "INSERT INTO workloads(id, name, payload, updated_at) VALUES(?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET name=excluded.name, payload=excluded.payload, updated_at=excluded.updated_at",
      bindings: [
        workload.id.uuidString, workload.name, payload, workload.updatedAt.timeIntervalSince1970,
      ]
    )
  }

  public func deleteWorkload(id: UUID) async throws {
    try database.transaction {
      try database.execute(
        "DELETE FROM metrics WHERE run_id IN (SELECT id FROM runs WHERE workload_id = ?)",
        bindings: [id.uuidString])
      try database.execute("DELETE FROM workloads WHERE id = ?", bindings: [id.uuidString])
      try database.execute("DELETE FROM runs WHERE workload_id = ?", bindings: [id.uuidString])
      try database.execute("DELETE FROM events WHERE workload_id = ?", bindings: [id.uuidString])
      try database.execute(
        "DELETE FROM missed_windows WHERE workload_id = ?", bindings: [id.uuidString])
      try database.execute(
        "DELETE FROM scheduler_checkpoints WHERE workload_id = ?", bindings: [id.uuidString])
    }
  }

  public func listRuns(workloadID: UUID) async throws -> [Run] {
    try database.query(
      "SELECT payload FROM runs WHERE workload_id = ?", bindings: [workloadID.uuidString]
    ) { statement in
      try decode(Run.self, from: statement, column: 0)
    }.sorted {
      ($0.finishedTime ?? $0.startedTime ?? $0.createdAt ?? .distantPast)
        > ($1.finishedTime ?? $1.startedTime ?? $1.createdAt ?? .distantPast)
    }
  }

  public func loadRun(id: UUID) async throws -> Run? {
    try database.query("SELECT payload FROM runs WHERE id = ?", bindings: [id.uuidString]) {
      statement in
      try decode(Run.self, from: statement, column: 0)
    }.first
  }

  public func saveRun(_ run: Run) async throws {
    let payload = try encode(run)
    try database.execute(
      "INSERT INTO runs(id, workload_id, state, started_at, payload) VALUES(?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET state=excluded.state, started_at=excluded.started_at, payload=excluded.payload",
      bindings: [
        run.id.uuidString, run.workloadID.uuidString, run.state.rawValue,
        run.startedTime?.timeIntervalSince1970 ?? NSNull(), payload,
      ]
    )
  }

  public func deleteRuns(workloadID: UUID) async throws {
    try database.transaction {
      try database.execute(
        "DELETE FROM metrics WHERE run_id IN (SELECT id FROM runs WHERE workload_id = ?)",
        bindings: [workloadID.uuidString])
      try database.execute(
        "DELETE FROM runs WHERE workload_id = ?", bindings: [workloadID.uuidString])
      try database.execute(
        "DELETE FROM events WHERE workload_id = ?", bindings: [workloadID.uuidString])
    }
  }
  public func deleteRun(id: UUID) async throws {
    try database.transaction {
      try database.execute("DELETE FROM metrics WHERE run_id = ?", bindings: [id.uuidString])
      try database.execute("DELETE FROM events WHERE run_id = ?", bindings: [id.uuidString])
      try database.execute("DELETE FROM runs WHERE id = ?", bindings: [id.uuidString])
    }
  }

  public func appendEvent(_ event: DomainEvent) async throws {
    let payload = try encode(event)
    try database.execute(
      "INSERT INTO events(id, workload_id, run_id, occurred_at, payload) VALUES(?, ?, ?, ?, ?)",
      bindings: [
        event.id.uuidString, event.workloadID.uuidString, event.runID?.uuidString ?? NSNull(),
        event.occurredAt.timeIntervalSince1970, payload,
      ]
    )
  }

  public func listEvents(workloadID: UUID, runID: UUID? = nil) async throws -> [DomainEvent] {
    let sql =
      runID == nil
      ? "SELECT payload FROM events WHERE workload_id = ? ORDER BY occurred_at ASC"
      : "SELECT payload FROM events WHERE workload_id = ? AND run_id = ? ORDER BY occurred_at ASC"
    let bindings: [Any] =
      runID == nil ? [workloadID.uuidString] : [workloadID.uuidString, runID!.uuidString]
    return try database.query(sql, bindings: bindings) { statement in
      try decode(DomainEvent.self, from: statement, column: 0)
    }
  }

  public func saveMetrics(_ sample: MetricsSample) async throws {
    let payload = try encode(sample)
    try database.execute(
      "INSERT OR REPLACE INTO metrics(id, run_id, timestamp, payload) VALUES(?, ?, ?, ?)",
      bindings: [
        sample.id.uuidString, sample.runID.uuidString, sample.timestamp.timeIntervalSince1970,
        payload,
      ]
    )
    try database.execute(
      "DELETE FROM metrics WHERE timestamp < ?",
      bindings: [Date().addingTimeInterval(-24 * 60 * 60).timeIntervalSince1970])
  }

  public func listMetrics(runID: UUID, since: Date? = nil) async throws -> [MetricsSample] {
    let sql =
      since == nil
      ? "SELECT payload FROM metrics WHERE run_id = ? ORDER BY timestamp ASC"
      : "SELECT payload FROM metrics WHERE run_id = ? AND timestamp >= ? ORDER BY timestamp ASC"
    let bindings: [Any] =
      since == nil ? [runID.uuidString] : [runID.uuidString, since!.timeIntervalSince1970]
    return try database.query(sql, bindings: bindings) { statement in
      try decode(MetricsSample.self, from: statement, column: 0)
    }
  }

  public func saveMissedWindow(_ window: SchedulerMissedWindow) async throws {
    let payload = try encode(window)
    try database.execute(
      "INSERT OR REPLACE INTO missed_windows(id, workload_id, from_time, to_time, payload) VALUES(?, ?, ?, ?, ?)",
      bindings: [
        window.id.uuidString, window.workloadID.uuidString, window.from.timeIntervalSince1970,
        window.to.timeIntervalSince1970, payload,
      ]
    )
  }

  public func listMissedWindows(workloadID: UUID) async throws -> [SchedulerMissedWindow] {
    try database.query(
      "SELECT payload FROM missed_windows WHERE workload_id = ? ORDER BY from_time ASC",
      bindings: [workloadID.uuidString]
    ) { statement in
      try decode(SchedulerMissedWindow.self, from: statement, column: 0)
    }
  }

  public func loadSchedulerCheckpoint(workloadID: UUID) async throws -> SchedulerCheckpoint? {
    try database.query(
      "SELECT payload FROM scheduler_checkpoints WHERE workload_id = ?",
      bindings: [workloadID.uuidString]
    ) { try decode(SchedulerCheckpoint.self, from: $0, column: 0) }.first
  }

  public func saveSchedulerCheckpoint(_ checkpoint: SchedulerCheckpoint) async throws {
    try database.execute(
      "INSERT OR REPLACE INTO scheduler_checkpoints(workload_id, payload) VALUES(?, ?)",
      bindings: [checkpoint.workloadID.uuidString, try encode(checkpoint)])
  }

  private func applyMutation(_ mutation: StoreMutation) throws {
    switch mutation {
    case .saveWorkload(let workload):
      try database.execute(
        "INSERT INTO workloads(id, name, payload, updated_at) VALUES(?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET name=excluded.name, payload=excluded.payload, updated_at=excluded.updated_at",
        bindings: [
          workload.id.uuidString, workload.name, try encode(workload),
          workload.updatedAt.timeIntervalSince1970,
        ])
    case .deleteWorkload(let id):
      try database.execute(
        "DELETE FROM metrics WHERE run_id IN (SELECT id FROM runs WHERE workload_id = ?)",
        bindings: [id.uuidString])
      try database.execute("DELETE FROM events WHERE workload_id = ?", bindings: [id.uuidString])
      try database.execute("DELETE FROM runs WHERE workload_id = ?", bindings: [id.uuidString])
      try database.execute(
        "DELETE FROM missed_windows WHERE workload_id = ?", bindings: [id.uuidString])
      try database.execute(
        "DELETE FROM scheduler_checkpoints WHERE workload_id = ?", bindings: [id.uuidString])
      try database.execute("DELETE FROM workloads WHERE id = ?", bindings: [id.uuidString])
    case .saveRun(let run):
      try database.execute(
        "INSERT INTO runs(id, workload_id, state, started_at, payload) VALUES(?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET state=excluded.state, started_at=excluded.started_at, payload=excluded.payload",
        bindings: [
          run.id.uuidString, run.workloadID.uuidString, run.state.rawValue,
          run.startedTime?.timeIntervalSince1970 ?? NSNull(), try encode(run),
        ])
    case .deleteRun(let id):
      try database.execute("DELETE FROM metrics WHERE run_id = ?", bindings: [id.uuidString])
      try database.execute("DELETE FROM events WHERE run_id = ?", bindings: [id.uuidString])
      try database.execute("DELETE FROM runs WHERE id = ?", bindings: [id.uuidString])
    case .appendEvent(let event):
      try database.execute(
        "INSERT INTO events(id, workload_id, run_id, occurred_at, payload) VALUES(?, ?, ?, ?, ?)",
        bindings: [
          event.id.uuidString, event.workloadID.uuidString, event.runID?.uuidString ?? NSNull(),
          event.occurredAt.timeIntervalSince1970, try encode(event),
        ])
    case .saveMetrics(let sample):
      try database.execute(
        "INSERT OR REPLACE INTO metrics(id, run_id, timestamp, payload) VALUES(?, ?, ?, ?)",
        bindings: [
          sample.id.uuidString, sample.runID.uuidString, sample.timestamp.timeIntervalSince1970,
          try encode(sample),
        ])
      try database.execute(
        "DELETE FROM metrics WHERE timestamp < ?",
        bindings: [Date().addingTimeInterval(-86_400).timeIntervalSince1970])
    case .pruneMetrics(let cutoff):
      try database.execute(
        "DELETE FROM metrics WHERE timestamp < ?", bindings: [cutoff.timeIntervalSince1970])
    case .saveMissedWindow(let window):
      try database.execute(
        "INSERT OR REPLACE INTO missed_windows(id, workload_id, from_time, to_time, payload) VALUES(?, ?, ?, ?, ?)",
        bindings: [
          window.id.uuidString, window.workloadID.uuidString, window.from.timeIntervalSince1970,
          window.to.timeIntervalSince1970, try encode(window),
        ])
    case .saveSchedulerCheckpoint(let checkpoint):
      try database.execute(
        "INSERT OR REPLACE INTO scheduler_checkpoints(workload_id, payload) VALUES(?, ?)",
        bindings: [checkpoint.workloadID.uuidString, try encode(checkpoint)])
    }
  }

  private func encode<T: Encodable>(_ value: T) throws -> String {
    guard let string = String(data: try encoder.encode(value), encoding: .utf8) else {
      throw PersistenceError.encodingFailed
    }
    return string
  }

  private func decode<T: Decodable>(_ type: T.Type, from statement: OpaquePointer, column: Int32)
    throws -> T
  {
    guard let raw = sqlite3_column_text(statement, column) else {
      throw PersistenceError.decodingFailed
    }
    let string = String(cString: raw)
    guard let data = string.data(using: .utf8) else { throw PersistenceError.decodingFailed }
    return try decoder.decode(type, from: data)
  }
}

private final class SQLiteDatabase: @unchecked Sendable {
  private var handle: OpaquePointer?
  private let url: URL
  private(set) var migrationWarning: String?
  var isReadOnly: Bool { readOnly }
  private var readOnly = false

  init(url: URL) throws {
    self.url = url
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var opened: OpaquePointer?
    let result = sqlite3_open_v2(
      url.path, &opened, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
    guard result == SQLITE_OK, let opened else {
      let message = opened.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
      if let opened { sqlite3_close(opened) }
      throw PersistenceError.openFailed(message)
    }
    handle = opened
    sqlite3_busy_timeout(opened, 10_000)
  }

  deinit { sqlite3_close(handle) }

  func migrate() {
    do {
      try execute("PRAGMA foreign_keys = ON")
      let version = try currentVersion()
      guard version <= 2 else {
        throw PersistenceError.migrationFailed(
          "Database version \(version) is newer than supported version 2")
      }
      guard version < 2 else { return }
      try createBackup()
      try transaction {
        if version < 1 {
          try execute(
            "CREATE TABLE IF NOT EXISTS workloads (id TEXT PRIMARY KEY, name TEXT NOT NULL UNIQUE COLLATE NOCASE, payload TEXT NOT NULL, updated_at REAL NOT NULL)"
          )
          try execute(
            "CREATE TABLE IF NOT EXISTS runs (id TEXT PRIMARY KEY, workload_id TEXT NOT NULL, state TEXT NOT NULL, started_at REAL, payload TEXT NOT NULL, FOREIGN KEY(workload_id) REFERENCES workloads(id) ON DELETE CASCADE)"
          )
          try execute(
            "CREATE TABLE IF NOT EXISTS events (id TEXT PRIMARY KEY, workload_id TEXT NOT NULL, run_id TEXT, occurred_at REAL NOT NULL, payload TEXT NOT NULL, FOREIGN KEY(workload_id) REFERENCES workloads(id) ON DELETE CASCADE)"
          )
          try execute(
            "CREATE TABLE IF NOT EXISTS metrics (id TEXT PRIMARY KEY, run_id TEXT NOT NULL, timestamp REAL NOT NULL, payload TEXT NOT NULL)"
          )
          try execute(
            "CREATE TABLE IF NOT EXISTS missed_windows (id TEXT PRIMARY KEY, workload_id TEXT NOT NULL, from_time REAL NOT NULL, to_time REAL NOT NULL, payload TEXT NOT NULL, FOREIGN KEY(workload_id) REFERENCES workloads(id) ON DELETE CASCADE)"
          )
        }
        try execute(
          "CREATE TABLE IF NOT EXISTS scheduler_checkpoints (workload_id TEXT PRIMARY KEY, payload TEXT NOT NULL, FOREIGN KEY(workload_id) REFERENCES workloads(id) ON DELETE CASCADE)"
        )
        try execute("PRAGMA user_version = 2")
      }
    } catch {
      migrationWarning =
        PersistenceError.migrationFailed(error.localizedDescription).localizedDescription
      readOnly = true
    }
  }

  private func currentVersion() throws -> Int {
    try query("PRAGMA user_version") { Int(sqlite3_column_int($0, 0)) }.first ?? 0
  }

  private func createBackup() throws {
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    let backupURL = url.deletingPathExtension().appendingPathExtension("sqlite.backup")
    let temporaryURL = backupURL.appendingPathExtension("tmp")
    try? FileManager.default.removeItem(at: temporaryURL)
    var destination: OpaquePointer?
    guard
      sqlite3_open_v2(
        temporaryURL.path, &destination, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil)
        == SQLITE_OK,
      let destination
    else { throw PersistenceError.openFailed("Database backup could not be opened") }
    defer { sqlite3_close(destination) }
    guard let backup = sqlite3_backup_init(destination, "main", handle, "main") else {
      throw PersistenceError.openFailed("Database backup could not start")
    }
    let result = sqlite3_backup_step(backup, -1)
    let finish = sqlite3_backup_finish(backup)
    guard result == SQLITE_DONE, finish == SQLITE_OK else {
      throw PersistenceError.openFailed("Database backup failed")
    }
    try? FileManager.default.removeItem(at: backupURL)
    try FileManager.default.moveItem(at: temporaryURL, to: backupURL)
  }

  func transaction(_ body: () throws -> Void) throws {
    try execute("BEGIN IMMEDIATE")
    do {
      try body()
      try execute("COMMIT")
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }

  func execute(_ sql: String, bindings: [Any] = []) throws {
    guard !readOnly else {
      throw PersistenceError.readOnly(migrationWarning ?? "migration failed")
    }
    guard let handle else { throw PersistenceError.openFailed("database is closed") }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw PersistenceError.queryFailed(String(cString: sqlite3_errmsg(handle)))
    }
    defer { sqlite3_finalize(statement) }
    try bind(bindings, to: statement)
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw PersistenceError.queryFailed(String(cString: sqlite3_errmsg(handle)))
    }
  }

  func query<T>(_ sql: String, bindings: [Any] = [], row: (OpaquePointer) throws -> T) throws -> [T]
  {
    guard let handle else { throw PersistenceError.openFailed("database is closed") }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw PersistenceError.queryFailed(String(cString: sqlite3_errmsg(handle)))
    }
    defer { sqlite3_finalize(statement) }
    try bind(bindings, to: statement)
    var result: [T] = []
    while true {
      switch sqlite3_step(statement) {
      case SQLITE_ROW: result.append(try row(statement))
      case SQLITE_DONE: return result
      default: throw PersistenceError.queryFailed(String(cString: sqlite3_errmsg(handle)))
      }
    }
  }

  private func bind(_ bindings: [Any], to statement: OpaquePointer) throws {
    for (offset, value) in bindings.enumerated() {
      let index = Int32(offset + 1)
      let result: Int32
      switch value {
      case let string as String:
        result = sqlite3_bind_text(
          statement, index, string, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
      case let number as Int:
        result = sqlite3_bind_int64(statement, index, sqlite3_int64(number))
      case let number as Int32:
        result = sqlite3_bind_int(statement, index, number)
      case let number as Double:
        result = sqlite3_bind_double(statement, index, number)
      case let null as NSNull where null == NSNull():
        result = sqlite3_bind_null(statement, index)
      default:
        throw PersistenceError.queryFailed("unsupported binding")
      }
      guard result == SQLITE_OK else { throw PersistenceError.queryFailed("binding failed") }
    }
  }
}
