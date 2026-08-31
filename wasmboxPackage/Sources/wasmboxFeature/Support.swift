import Foundation
import Security

public enum SecretStoreError: Error, LocalizedError, Sendable {
  case unavailable(String)
  case operationFailed(String)

  public var errorDescription: String? {
    switch self {
    case .unavailable(let message): "Keychain unavailable: \(message)"
    case .operationFailed(let message): "Keychain operation failed: \(message)"
    }
  }
}

public protocol SecretStore: Sendable {
  func read(reference: String) async throws -> String?
  func write(value: String, reference: String) async throws
  func delete(reference: String) async throws
}

public actor InMemorySecretStore: SecretStore {
  private var values: [String: String] = [:]

  public init(values: [String: String] = [:]) { self.values = values }

  public func read(reference: String) async throws -> String? { values[reference] }
  public func write(value: String, reference: String) async throws { values[reference] = value }
  public func delete(reference: String) async throws { values.removeValue(forKey: reference) }
}

public actor KeychainSecretStore: SecretStore {
  private let service: String

  public init(service: String = "com.wasmbox.secrets") { self.service = service }

  public func read(reference: String) async throws -> String? {
    var query = baseQuery(reference: reference)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    switch status {
    case errSecSuccess:
      guard let data = result as? Data else {
        throw SecretStoreError.operationFailed("invalid keychain data")
      }
      return String(data: data, encoding: .utf8)
    case errSecItemNotFound: return nil
    default: throw SecretStoreError.operationFailed("OSStatus \(status)")
    }
  }

  public func write(value: String, reference: String) async throws {
    guard let data = value.data(using: .utf8) else {
      throw SecretStoreError.operationFailed("invalid UTF-8")
    }
    let query = baseQuery(reference: reference)
    let attributes: [String: Any] = [kSecValueData as String: data]
    let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if updateStatus == errSecItemNotFound {
      var item = query
      item[kSecValueData as String] = data
      let addStatus = SecItemAdd(item as CFDictionary, nil)
      guard addStatus == errSecSuccess else {
        throw SecretStoreError.operationFailed("OSStatus \(addStatus)")
      }
    } else if updateStatus != errSecSuccess {
      throw SecretStoreError.operationFailed("OSStatus \(updateStatus)")
    }
  }

  public func delete(reference: String) async throws {
    let status = SecItemDelete(baseQuery(reference: reference) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw SecretStoreError.operationFailed("OSStatus \(status)")
    }
  }

  private func baseQuery(reference: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: reference,
    ]
  }
}

public enum EnvironmentResolutionError: Error, LocalizedError, Sendable {
  case missingSecret(String)

  public var errorDescription: String? {
    switch self {
    case .missingSecret(let reference): "Secret is not configured: \(reference)"
    }
  }
}

public struct EnvironmentResolver: Sendable {
  public let secretStore: any SecretStore

  public init(secretStore: any SecretStore) { self.secretStore = secretStore }

  public func resolve(_ variables: [EnvironmentVariable]) async throws -> [String: String] {
    var result: [String: String] = [:]
    for variable in variables {
      switch variable.value {
      case .plain(let value): result[variable.key] = value
      case .secret(let reference):
        guard let value = try await secretStore.read(reference: reference) else {
          throw EnvironmentResolutionError.missingSecret(reference)
        }
        result[variable.key] = value
      }
    }
    return result
  }
}

public enum LogChannel: String, CaseIterable, Sendable {
  case stdout
  case stderr
}

public enum LogViewMode: String, CaseIterable, Sendable {
  case stdout
  case stderr
  case merged
}

public struct LogChunk: Hashable, Sendable {
  public let channel: LogChannel
  public let text: String

  public init(channel: LogChannel, text: String) {
    self.channel = channel
    self.text = text
  }
}

public protocol LogStore: Sendable {
  func append(runID: UUID, channel: LogChannel, text: String, secrets: [String]) async throws
  func read(runID: UUID, mode: LogViewMode, lastLines: Int) async throws -> String
  func search(runID: UUID, query: String, mode: LogViewMode) async throws -> [String]
  func remove(runID: UUID) async throws
  func retain(runIDs: Set<UUID>) async throws
}

public actor FileLogStore: LogStore {
  public let rootURL: URL
  private let fileManager: FileManager

  public init(rootURL: URL? = nil, fileManager: FileManager = .default) {
    self.fileManager = fileManager
    self.rootURL =
      rootURL
      ?? (fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.temporaryDirectory).appendingPathComponent("wasmbox/logs", isDirectory: true)
  }

  public func append(runID: UUID, channel: LogChannel, text: String, secrets: [String]) async throws
  {
    let directory = rootURL.appendingPathComponent(runID.uuidString, isDirectory: true)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    try append(
      text, to: directory.appendingPathComponent("\(channel.rawValue).log"), secrets: secrets)
    try append(text, to: directory.appendingPathComponent("merged.log"), secrets: secrets)
  }

  private func append(_ text: String, to url: URL, secrets: [String]) throws {
    if !fileManager.fileExists(atPath: url.path) {
      fileManager.createFile(atPath: url.path, contents: nil)
    }
    let handle = try FileHandle(forUpdating: url)
    defer { try? handle.close() }
    let end = try handle.seekToEnd()
    let overlap = max(0, (secrets.map { $0.utf8.count }.max() ?? 1) - 1)
    let candidateStart = end > UInt64(overlap + 3) ? end - UInt64(overlap + 3) : 0
    try handle.seek(toOffset: candidateStart)
    let tail = [UInt8](try handle.readToEnd() ?? Data())
    var dropped = 0
    while dropped < min(4, tail.count),
      String(bytes: tail.dropFirst(dropped), encoding: .utf8) == nil
    {
      dropped += 1
    }
    let prior = String(decoding: tail.dropFirst(dropped), as: UTF8.self)
    let rewriteStart = candidateStart + UInt64(dropped)
    try handle.truncate(atOffset: rewriteStart)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(Self.mask(prior + text, secrets: secrets).utf8))
  }

  public func read(runID: UUID, mode: LogViewMode, lastLines: Int = 1_000) async throws -> String {
    let chunks = try load(runID: runID, mode: mode)
    let merged = chunks.map(\.text).joined()
    guard lastLines > 0 else { return "" }
    let lines = merged.split(separator: "\n", omittingEmptySubsequences: true)
    return lines.suffix(lastLines).joined(separator: "\n")
  }

  public func search(runID: UUID, query: String, mode: LogViewMode) async throws -> [String] {
    let chunks = try load(runID: runID, mode: mode)
    return chunks.flatMap {
      $0.text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }.filter {
      query.isEmpty || $0.localizedCaseInsensitiveContains(query)
    }
  }

  public func remove(runID: UUID) async throws {
    let directory = rootURL.appendingPathComponent(runID.uuidString, isDirectory: true)
    if fileManager.fileExists(atPath: directory.path) { try fileManager.removeItem(at: directory) }
  }

  public func retain(runIDs: Set<UUID>) async throws {
    guard fileManager.fileExists(atPath: rootURL.path) else { return }
    for directory in try fileManager.contentsOfDirectory(
      at: rootURL, includingPropertiesForKeys: nil)
    {
      guard let id = UUID(uuidString: directory.lastPathComponent), !runIDs.contains(id) else {
        continue
      }
      try fileManager.removeItem(at: directory)
    }
  }

  public static func mask(_ text: String, secrets: [String]) -> String {
    secrets.filter { !$0.isEmpty }.reduce(text) { value, secret in
      value.replacingOccurrences(of: secret, with: "••••")
    }
  }

  private func load(runID: UUID, mode: LogViewMode) throws -> [LogChunk] {
    switch mode {
    case .stdout: return [try chunk(runID: runID, channel: .stdout)]
    case .stderr: return [try chunk(runID: runID, channel: .stderr)]
    case .merged:
      let merged = try chunk(runID: runID, fileName: "merged.log", channel: .stdout)
      return merged.text.isEmpty
        ? [try chunk(runID: runID, channel: .stdout), try chunk(runID: runID, channel: .stderr)]
        : [merged]
    }
  }

  private func chunk(runID: UUID, channel: LogChannel) throws -> LogChunk {
    try chunk(runID: runID, fileName: "\(channel.rawValue).log", channel: channel)
  }

  private func chunk(runID: UUID, fileName: String, channel: LogChannel) throws -> LogChunk {
    let url = rootURL.appendingPathComponent(runID.uuidString).appendingPathComponent(fileName)
    guard let data = fileManager.contents(atPath: url.path) else {
      return LogChunk(channel: channel, text: "")
    }
    return LogChunk(channel: channel, text: String(data: data, encoding: .utf8) ?? "")
  }
}

public struct MetricAggregate: Hashable, Sendable {
  public let minute: Date
  public let averageCPUPercent: Double
  public let peakMemoryBytes: Int64

  public init(minute: Date, averageCPUPercent: Double, peakMemoryBytes: Int64) {
    self.minute = minute
    self.averageCPUPercent = averageCPUPercent
    self.peakMemoryBytes = peakMemoryBytes
  }
}

public actor MetricsCollector {
  private let store: any WasmboxStore
  private var lastCollection: [UUID: Date] = [:]

  public init(store: any WasmboxStore) { self.store = store }

  public func collect(
    runID: UUID, process: RuntimeProcess, adapter: any RuntimeAdapter, now: Date = Date()
  ) async throws -> MetricsSample? {
    if let last = lastCollection[runID], now.timeIntervalSince(last) < 5 { return nil }
    guard let sample = try await adapter.metrics(process) else { return nil }
    lastCollection[runID] = now
    try await store.saveMetrics(sample)
    return sample
  }

  public func aggregate(runID: UUID, since: Date? = nil) async throws -> [MetricAggregate] {
    let samples = try await store.listMetrics(runID: runID, since: since)
    let calendar = Calendar(identifier: .gregorian)
    let grouped = Dictionary(grouping: samples) {
      calendar.dateComponents([.year, .month, .day, .hour, .minute], from: $0.timestamp)
    }
    return grouped.compactMap { components, values in
      guard let minute = calendar.date(from: components) else { return nil }
      return MetricAggregate(
        minute: minute,
        averageCPUPercent: values.map(\.cpuPercent).reduce(0, +) / Double(values.count),
        peakMemoryBytes: values.map(\.memoryBytes).max() ?? 0
      )
    }.sorted { $0.minute < $1.minute }
  }
}

public enum SchedulerDecision: Equatable, Sendable {
  case run
  case skipped(reason: String)
  case none
}

public struct Scheduler: Sendable {
  public init() {}

  public func decision(
    schedule: Schedule?,
    configurationIssues: [ValidationIssue],
    runtimeAvailability: RuntimeAvailability,
    activeRunCount: Int,
    maxConcurrentRuns: Int
  ) -> SchedulerDecision {
    guard schedule?.enabled == true else { return .none }
    if !configurationIssues.isEmpty { return .skipped(reason: "InvalidConfig") }
    if case .unavailable = runtimeAvailability { return .skipped(reason: "RuntimeUnavailable") }
    if activeRunCount >= maxConcurrentRuns { return .skipped(reason: "MaxConcurrentRuns") }
    return .run
  }

  public func missedWindow(
    workloadID: UUID, from: Date, to: Date, schedule: Schedule, calendar: Calendar = .current
  ) -> SchedulerMissedWindow {
    var count = 0
    var cursor = from
    while let next = schedule.nextRun(after: cursor, calendar: calendar), next <= to {
      count += 1
      cursor = next
    }
    return SchedulerMissedWindow(workloadID: workloadID, from: from, to: to, scheduledCount: count)
  }
}

public enum ImportConflictStrategy: String, CaseIterable, Sendable {
  case overwrite
  case rename
  case skip
}

public struct ExportDocument: Codable, Sendable {
  public let version: Int
  public let workloads: [Workload]

  public init(version: Int = 1, workloads: [Workload]) {
    self.version = version
    self.workloads = workloads
  }
}

public struct ImportResult: Sendable {
  public let imported: [Workload]
  public let skipped: [String]
  public let renamed: [String: String]
  public let missingSecretReferences: [String]

  public init(
    imported: [Workload],
    skipped: [String],
    renamed: [String: String],
    missingSecretReferences: [String] = []
  ) {
    self.imported = imported
    self.skipped = skipped
    self.renamed = renamed
    self.missingSecretReferences = missingSecretReferences
  }
}

public struct WorkloadTransfer: Sendable {
  public init() {}

  public func exportJSON(_ workloads: [Workload]) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(ExportDocument(workloads: workloads))
  }

  public func importJSON(
    _ data: Data,
    into existing: [Workload],
    conflict: ImportConflictStrategy = .skip
  ) throws -> ImportResult {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let document = try decoder.decode(ExportDocument.self, from: data)
    guard document.version == 1 else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: [], debugDescription: "Unsupported export version \(document.version)"))
    }
    var names = Set(existing.map { $0.name.lowercased() })
    var identifiers = Set(existing.map(\.id))
    var imported: [Workload] = []
    var skipped: [String] = []
    var renamed: [String: String] = [:]
    for original in document.workloads {
      let key = original.name.lowercased()
      let collision = existing.first {
        $0.name.caseInsensitiveCompare(original.name) == .orderedSame
      }
      if !names.contains(key) {
        let id = identifiers.insert(original.id).inserted ? original.id : UUID()
        identifiers.insert(id)
        names.insert(key)
        imported.append(importedCopy(original, id: id, name: original.name))
        continue
      }
      switch conflict {
      case .skip:
        skipped.append(original.name)
      case .overwrite:
        guard let collision else {
          skipped.append(original.name)
          continue
        }
        imported.append(importedCopy(original, id: collision.id, name: collision.name))
      case .rename:
        var suffix = 2
        var candidate = "\(original.name) (\(suffix))"
        while names.contains(candidate.lowercased()) {
          suffix += 1
          candidate = "\(original.name) (\(suffix))"
        }
        names.insert(candidate.lowercased())
        let id = UUID()
        identifiers.insert(id)
        imported.append(importedCopy(original, id: id, name: candidate))
        renamed[original.name] = candidate
      }
    }
    let secretReferences = Set(
      imported.flatMap {
        ($0.activeRevision.environment + $0.draftRevision.environment).compactMap {
          $0.value.secretReference
        }
      }
    ).sorted()
    return ImportResult(
      imported: imported,
      skipped: skipped,
      renamed: renamed,
      missingSecretReferences: secretReferences)
  }

  private func importedCopy(_ source: Workload, id: UUID, name: String) -> Workload {
    Workload(
      id: id,
      name: name,
      tags: source.tags,
      desiredState: .stopped,
      activeRevision: source.activeRevision,
      draftRevision: source.draftRevision,
      createdAt: Date(),
      updatedAt: Date())
  }
}
