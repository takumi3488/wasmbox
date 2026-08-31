import Foundation

public enum RuntimeKind: String, Codable, CaseIterable, Sendable {
  case appleContainer = "container"
  case wasmtime = "wasm"

  public var displayName: String {
    switch self {
    case .appleContainer: "Container"
    case .wasmtime: "Wasm"
    }
  }
}

public enum ExecutionMode: String, Codable, CaseIterable, Sendable {
  case once
  case scheduled
  case alwaysOn
}

public enum DesiredState: String, Codable, CaseIterable, Sendable {
  case running
  case stopped
}

public enum ArtifactUpdatePolicy: String, Codable, CaseIterable, Sendable {
  case pinned
  case refreshOnStart
}

public enum AccessMode: String, Codable, CaseIterable, Sendable {
  case readOnly
  case readWrite
}

public struct Mount: Codable, Hashable, Sendable, Identifiable {
  public let id: UUID
  public var hostPath: String
  public var guestPath: String
  public var accessMode: AccessMode

  public init(
    id: UUID = UUID(),
    hostPath: String,
    guestPath: String,
    accessMode: AccessMode = .readOnly
  ) {
    self.id = id
    self.hostPath = hostPath
    self.guestPath = guestPath
    self.accessMode = accessMode
  }
}

public struct PortMapping: Codable, Hashable, Sendable, Identifiable {
  public let id: UUID
  public var guestPort: Int
  public var hostPort: Int?

  public init(id: UUID = UUID(), guestPort: Int, hostPort: Int? = nil) {
    self.id = id
    self.guestPort = guestPort
    self.hostPort = hostPort
  }

  public var isAutomatic: Bool { hostPort == nil }
}

public enum EnvironmentVariableValue: Codable, Hashable, Sendable {
  case plain(String)
  case secret(reference: String)

  private enum CodingKeys: String, CodingKey { case kind, value, reference }
  private enum Kind: String, Codable { case plain, secret }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .plain(let value):
      try container.encode(Kind.plain, forKey: .kind)
      try container.encode(value, forKey: .value)
    case .secret(let reference):
      try container.encode(Kind.secret, forKey: .kind)
      try container.encode(reference, forKey: .reference)
    }
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .plain:
      self = .plain(try container.decode(String.self, forKey: .value))
    case .secret:
      self = .secret(reference: try container.decode(String.self, forKey: .reference))
    }
  }

  public var secretReference: String? {
    if case .secret(let reference) = self { return reference }
    return nil
  }
}

public struct EnvironmentVariable: Codable, Hashable, Sendable, Identifiable {
  public let id: UUID
  public var key: String
  public var value: EnvironmentVariableValue

  public init(id: UUID = UUID(), key: String, value: EnvironmentVariableValue) {
    self.id = id
    self.key = key
    self.value = value
  }
}

public enum WorkloadSpec: Codable, Hashable, Sendable {
  case container(ContainerSpec)
  case wasm(WasmSpec)

  public var kind: RuntimeKind {
    switch self {
    case .container: .appleContainer
    case .wasm: .wasmtime
    }
  }
}

public struct ContainerSpec: Codable, Hashable, Sendable {
  public var imageReference: String
  public var entrypointOverride: [String]?
  public var mounts: [Mount]

  public init(
    imageReference: String,
    entrypointOverride: [String]? = nil,
    mounts: [Mount] = []
  ) {
    self.imageReference = imageReference
    self.entrypointOverride = entrypointOverride
    self.mounts = mounts
  }
}

public enum WasmSource: Codable, Hashable, Sendable {
  case localPath(String)
  case httpsURL(String)

  public var rawValue: String {
    switch self {
    case .localPath(let path): path
    case .httpsURL(let url): url
    }
  }
}

public struct WasmSpec: Codable, Hashable, Sendable {
  public var source: WasmSource
  public var preopens: [Mount]
  public var socketPermission: Bool
  public var expectedSHA256: String?
  public var allowInsecureTLS: Bool

  public init(
    source: WasmSource,
    preopens: [Mount] = [],
    socketPermission: Bool = false,
    expectedSHA256: String? = nil,
    allowInsecureTLS: Bool = false
  ) {
    self.source = source
    self.preopens = preopens
    self.socketPermission = socketPermission
    self.expectedSHA256 = expectedSHA256
    self.allowInsecureTLS = allowInsecureTLS
  }
}

public enum HealthCheckKind: Codable, Hashable, Sendable {
  case command([String])
  case http(url: String)
  case tcp(host: String, port: Int)

  private enum CodingKeys: String, CodingKey { case kind, command, url, host, port }
  private enum Kind: String, Codable { case command, http, tcp }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .command(let command):
      try container.encode(Kind.command, forKey: .kind)
      try container.encode(command, forKey: .command)
    case .http(let url):
      try container.encode(Kind.http, forKey: .kind)
      try container.encode(url, forKey: .url)
    case .tcp(let host, let port):
      try container.encode(Kind.tcp, forKey: .kind)
      try container.encode(host, forKey: .host)
      try container.encode(port, forKey: .port)
    }
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .command:
      self = .command(try container.decode([String].self, forKey: .command))
    case .http:
      self = .http(url: try container.decode(String.self, forKey: .url))
    case .tcp:
      self = .tcp(
        host: try container.decode(String.self, forKey: .host),
        port: try container.decode(Int.self, forKey: .port)
      )
    }
  }
}

public struct HealthCheck: Codable, Hashable, Sendable {
  public var kind: HealthCheckKind
  public var failureThreshold: Int
  public var successThreshold: Int
  public var startPeriod: TimeInterval
  public var unhealthyGracePeriod: TimeInterval

  public init(
    kind: HealthCheckKind,
    failureThreshold: Int = 3,
    successThreshold: Int = 1,
    startPeriod: TimeInterval = 10,
    unhealthyGracePeriod: TimeInterval = 0
  ) {
    self.kind = kind
    self.failureThreshold = failureThreshold
    self.successThreshold = successThreshold
    self.startPeriod = startPeriod
    self.unhealthyGracePeriod = unhealthyGracePeriod
  }
}

public struct RestartPolicy: Codable, Hashable, Sendable {
  public var maxRestartAttempts: Int
  public var stableFor: TimeInterval
  public var backoff: TimeInterval

  public init(
    maxRestartAttempts: Int = 3,
    stableFor: TimeInterval = 5 * 60,
    backoff: TimeInterval = 1
  ) {
    self.maxRestartAttempts = maxRestartAttempts
    self.stableFor = stableFor
    self.backoff = backoff
  }
}

public struct RetentionPolicy: Codable, Hashable, Sendable {
  public var maxRuns: Int
  public var logDays: Int

  public init(maxRuns: Int = 100, logDays: Int = 7) {
    self.maxRuns = maxRuns
    self.logDays = logDays
  }
}

public struct ConcurrencyPolicy: Codable, Hashable, Sendable {
  public var maxConcurrentRuns: Int

  public init(maxConcurrentRuns: Int = 1) {
    self.maxConcurrentRuns = maxConcurrentRuns
  }
}

public enum StopSignal: String, Codable, CaseIterable, Sendable {
  case sigterm = "SIGTERM"
  case sigint = "SIGINT"
  case sigquit = "SIGQUIT"

  public var number: Int32 {
    switch self {
    case .sigterm: 15
    case .sigint: 2
    case .sigquit: 3
    }
  }
}

public struct StopPolicy: Codable, Hashable, Sendable {
  public var signal: StopSignal
  public var timeout: TimeInterval

  public init(signal: StopSignal = .sigterm, timeout: TimeInterval = 10) {
    self.signal = signal
    self.timeout = timeout
  }
}

public struct WorkloadRevision: Codable, Hashable, Sendable, Identifiable {
  public let id: UUID
  public var spec: WorkloadSpec
  public var executionMode: ExecutionMode
  public var environment: [EnvironmentVariable]
  public var arguments: [String]
  public var ports: [PortMapping]
  public var healthCheck: HealthCheck?
  public var restartPolicy: RestartPolicy
  public var retentionPolicy: RetentionPolicy
  public var concurrencyPolicy: ConcurrencyPolicy
  public var stopPolicy: StopPolicy
  public var artifactUpdatePolicy: ArtifactUpdatePolicy
  public var pinnedArtifactID: String?
  public var schedule: Schedule?
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    spec: WorkloadSpec,
    executionMode: ExecutionMode = .once,
    environment: [EnvironmentVariable] = [],
    arguments: [String] = [],
    ports: [PortMapping] = [],
    healthCheck: HealthCheck? = nil,
    restartPolicy: RestartPolicy = RestartPolicy(),
    retentionPolicy: RetentionPolicy = RetentionPolicy(),
    concurrencyPolicy: ConcurrencyPolicy = ConcurrencyPolicy(),
    stopPolicy: StopPolicy = StopPolicy(),
    artifactUpdatePolicy: ArtifactUpdatePolicy = .refreshOnStart,
    pinnedArtifactID: String? = nil,
    schedule: Schedule? = nil,
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.spec = spec
    self.executionMode = executionMode
    self.environment = environment
    self.arguments = arguments
    self.ports = ports
    self.healthCheck = healthCheck
    self.restartPolicy = restartPolicy
    self.retentionPolicy = retentionPolicy
    self.concurrencyPolicy = concurrencyPolicy
    self.stopPolicy = stopPolicy
    self.artifactUpdatePolicy = artifactUpdatePolicy
    self.pinnedArtifactID = pinnedArtifactID
    self.schedule = schedule
    self.updatedAt = updatedAt
  }

  public var kind: RuntimeKind { spec.kind }
}

public struct Workload: Codable, Hashable, Sendable, Identifiable {
  public let id: UUID
  public var name: String
  public var tags: [String]
  public var desiredState: DesiredState
  public var activeRevision: WorkloadRevision
  public var draftRevision: WorkloadRevision
  public let createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    name: String,
    tags: [String] = [],
    desiredState: DesiredState = .stopped,
    activeRevision: WorkloadRevision,
    draftRevision: WorkloadRevision? = nil,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.name = name
    self.tags = Array(Set(tags)).sorted()
    self.desiredState = desiredState
    self.activeRevision = activeRevision
    self.draftRevision = draftRevision ?? activeRevision
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public var kind: RuntimeKind { activeRevision.kind }
  public var hasDraftChanges: Bool { activeRevision != draftRevision }

  public mutating func updateDraft(_ revision: WorkloadRevision, at date: Date = Date()) {
    draftRevision = revision
    draftRevision.updatedAt = date
    updatedAt = date
  }

  public mutating func discardDraft(at date: Date = Date()) {
    draftRevision = activeRevision
    updatedAt = date
  }

  public var draftChangedFields: [String] {
    var fields: [String] = []
    if activeRevision.spec != draftRevision.spec { fields.append("Source / runtime settings") }
    if activeRevision.executionMode != draftRevision.executionMode {
      fields.append("Execution mode")
    }
    if activeRevision.environment != draftRevision.environment { fields.append("Environment") }
    if activeRevision.arguments != draftRevision.arguments { fields.append("Arguments") }
    if activeRevision.ports != draftRevision.ports { fields.append("Ports") }
    if activeRevision.healthCheck != draftRevision.healthCheck { fields.append("Health check") }
    if activeRevision.restartPolicy != draftRevision.restartPolicy {
      fields.append("Restart policy")
    }
    if activeRevision.retentionPolicy != draftRevision.retentionPolicy {
      fields.append("Retention")
    }
    if activeRevision.concurrencyPolicy != draftRevision.concurrencyPolicy {
      fields.append("Concurrency")
    }
    if activeRevision.stopPolicy != draftRevision.stopPolicy { fields.append("Stop policy") }
    if activeRevision.artifactUpdatePolicy != draftRevision.artifactUpdatePolicy
      || activeRevision.pinnedArtifactID != draftRevision.pinnedArtifactID
    {
      fields.append("Artifact policy")
    }
    if activeRevision.schedule != draftRevision.schedule { fields.append("Schedule") }
    return fields
  }
  @discardableResult
  public mutating func applyDraft(at date: Date = Date()) -> WorkloadRevision {
    activeRevision = draftRevision
    activeRevision.updatedAt = date
    draftRevision = activeRevision
    updatedAt = date
    return activeRevision
  }

  public static func runtimeName(workloadID: UUID, runID: UUID) -> String {
    "wasmbox-\(workloadID.uuidString)-\(runID.uuidString)"
  }

  public static func parseRuntimeName(_ value: String) -> (workloadID: UUID, runID: UUID)? {
    guard value.hasPrefix("wasmbox-") else { return nil }
    let suffix = String(value.dropFirst("wasmbox-".count))
    guard suffix.count == 73 else { return nil }
    let separator = suffix.index(suffix.startIndex, offsetBy: 36)
    guard suffix[separator] == "-",
      let workloadID = UUID(uuidString: String(suffix[..<separator])),
      let runID = UUID(uuidString: String(suffix[suffix.index(after: separator)...]))
    else { return nil }
    return (workloadID, runID)
  }
}

public struct Schedule: Codable, Hashable, Sendable, Identifiable {
  public let id: UUID
  public var cron: CronExpression
  public var enabled: Bool

  public init(id: UUID = UUID(), cron: CronExpression, enabled: Bool = true) {
    self.id = id
    self.cron = cron
    self.enabled = enabled
  }

  public func nextRun(after date: Date, calendar: Calendar = .current) -> Date? {
    guard enabled else { return nil }
    return cron.next(after: date, calendar: calendar)
  }
}

public enum RuntimeState: String, Codable, CaseIterable, Sendable {
  case loading = "Loading"
  case stopped = "Stopped"
  case starting = "Starting"
  case running = "Running"
  case unhealthy = "Unhealthy"
  case restarting = "Restarting"
  case failed = "Failed"
  case blocked = "Blocked"
  case invalidConfig = "InvalidConfig"
  case runtimeUnavailable = "RuntimeUnavailable"
  case updateRequiresRestart = "UpdateRequiresRestart"
  case updating = "Updating"
  case updateFailed = "UpdateFailed"
  case orphaned = "Orphaned"
}

public enum HealthStatus: String, Codable, CaseIterable, Sendable {
  case unknown = "Unknown"
  case healthy = "Healthy"
  case unhealthy = "Unhealthy"
  case notConfigured = "NotConfigured"
}

public enum RunTrigger: String, Codable, CaseIterable, Sendable {
  case manual = "Manual"
  case scheduled = "Scheduled"
  case restart = "Restart"
  case rollingUpdate = "RollingUpdate"
  case resume = "Resume"
}

public enum RunState: String, Codable, CaseIterable, Sendable {
  case pending = "Pending"
  case starting = "Starting"
  case running = "Running"
  case succeeded = "Succeeded"
  case failed = "Failed"
  case skipped = "Skipped"
  case terminating = "Terminating"
  case terminated = "Terminated"

  public var isTerminal: Bool {
    switch self {
    case .succeeded, .failed, .skipped, .terminated: true
    default: false
    }
  }
}

public enum TerminationReason: String, Codable, CaseIterable, Sendable {
  case stoppedByUser = "StoppedByUser"
  case terminatedByAppQuit = "TerminatedByAppQuit"
  case abnormalKill = "AbnormalKill"
}

public struct Run: Codable, Hashable, Sendable, Identifiable {
  public let id: UUID
  public let workloadID: UUID
  public let trigger: RunTrigger
  public var state: RunState
  public let scheduledTime: Date?
  public var startedTime: Date?
  public var finishedTime: Date?
  public var exitCode: Int32?
  public var terminationReason: TerminationReason?
  public let resolvedArtifactID: String?
  public let resolvedSource: String
  public let restartChainID: UUID
  public let attemptIndex: Int
  public let runtimeName: String
  public var runtimeProcessID: String?
  public let createdAt: Date?
  public var skipReason: String?
  public var resolvedFinalURL: String?
  public var assignedHostPorts: [Int]?
  public var runningRevisionID: UUID?

  public init(
    id: UUID = UUID(),
    workloadID: UUID,
    trigger: RunTrigger,
    scheduledTime: Date? = nil,
    resolvedArtifactID: String? = nil,
    resolvedSource: String,
    restartChainID: UUID = UUID(),
    attemptIndex: Int = 0,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.workloadID = workloadID
    self.trigger = trigger
    self.state = .pending
    self.scheduledTime = scheduledTime
    self.startedTime = nil
    self.finishedTime = nil
    self.exitCode = nil
    self.terminationReason = nil
    self.resolvedArtifactID = resolvedArtifactID
    self.resolvedSource = resolvedSource
    self.restartChainID = restartChainID
    self.attemptIndex = attemptIndex
    self.runtimeName = Workload.runtimeName(workloadID: workloadID, runID: id)
    self.runtimeProcessID = nil
    self.createdAt = createdAt
    self.skipReason = nil
    self.resolvedFinalURL = nil
    self.assignedHostPorts = nil
    self.runningRevisionID = nil
  }

  public var isSuccessful: Bool { state == .succeeded && exitCode == 0 }

  public mutating func transition(to next: RunState, at date: Date = Date()) throws {
    guard canTransition(from: state, to: next) else {
      throw RunTransitionError.invalid(from: state, to: next)
    }
    state = next
    if next == .starting || next == .running { startedTime = startedTime ?? date }
    if next.isTerminal { finishedTime = finishedTime ?? date }
  }

  public mutating func finish(
    exitCode: Int32?,
    terminationReason: TerminationReason? = nil,
    at date: Date = Date()
  ) throws {
    self.exitCode = exitCode
    self.terminationReason = terminationReason
    if terminationReason != nil {
      if state != .terminating { try transition(to: .terminating, at: date) }
      try transition(to: .terminated, at: date)
    } else {
      try transition(to: exitCode == 0 ? .succeeded : .failed, at: date)
    }
  }

  public mutating func adopt(processID: String, at date: Date = Date()) {
    state = .running
    startedTime = startedTime ?? date
    finishedTime = nil
    exitCode = nil
    terminationReason = nil
    runtimeProcessID = processID
  }

  public mutating func attach(
    processID: String,
    hostPorts: [Int],
    revisionID: UUID,
    finalURL: String? = nil
  ) {
    runtimeProcessID = processID
    assignedHostPorts = hostPorts
    runningRevisionID = revisionID
    resolvedFinalURL = finalURL
  }

  public mutating func skip(reason: String, at date: Date = Date()) throws {
    skipReason = reason
    try transition(to: .skipped, at: date)
  }

  private func canTransition(from: RunState, to: RunState) -> Bool {
    switch (from, to) {
    case (.pending, .starting), (.pending, .failed), (.pending, .skipped),
      (.pending, .terminating):
      true
    case (.starting, .running), (.starting, .failed), (.starting, .terminating): true
    case (.running, .succeeded), (.running, .failed), (.running, .terminating): true
    case (.terminating, .terminated), (.terminating, .failed): true
    default: false
    }
  }
}

public enum RunTransitionError: Error, Equatable, LocalizedError, Sendable {
  case invalid(from: RunState, to: RunState)

  public var errorDescription: String? {
    switch self {
    case .invalid(let from, let to): "Invalid run transition: \(from.rawValue) -> \(to.rawValue)"
    }
  }
}

public struct ResolvedArtifact: Codable, Hashable, Sendable, Identifiable {
  public let id: String
  public let source: String
  public let contentHash: String
  public let localPath: String
  public let resolvedAt: Date
  public let finalURL: String?

  public init(
    id: String,
    source: String,
    contentHash: String,
    localPath: String,
    resolvedAt: Date = Date(),
    finalURL: String? = nil
  ) {
    self.id = id
    self.source = source
    self.contentHash = contentHash
    self.localPath = localPath
    self.resolvedAt = resolvedAt
    self.finalURL = finalURL
  }
}

public struct RuntimeProcess: Codable, Hashable, Sendable, Identifiable {
  public let id: String
  public let runID: UUID?
  public let runtimeName: String
  public let hostPorts: [Int]

  public init(id: String, runID: UUID? = nil, runtimeName: String, hostPorts: [Int] = []) {
    self.id = id
    self.runID = runID
    self.runtimeName = runtimeName
    self.hostPorts = hostPorts
  }
}

public enum RuntimeProcessState: String, Codable, Sendable {
  case running
  case stopped
  case unknown
  case orphaned
}

public struct RuntimeInspection: Codable, Hashable, Sendable {
  public let runtimeName: String
  public let state: RuntimeProcessState
  public let exitCode: Int32?
  public let health: HealthStatus?

  public init(
    runtimeName: String,
    state: RuntimeProcessState,
    exitCode: Int32? = nil,
    health: HealthStatus? = nil
  ) {
    self.runtimeName = runtimeName
    self.state = state
    self.exitCode = exitCode
    self.health = health
  }
}

public enum RuntimeAvailability: Codable, Equatable, Sendable {
  case available(version: String)
  case unavailable(reason: String)

  private enum CodingKeys: String, CodingKey { case kind, version, reason }
  private enum Kind: String, Codable { case available, unavailable }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .available(let version):
      try c.encode(Kind.available, forKey: .kind)
      try c.encode(version, forKey: .version)
    case .unavailable(let reason):
      try c.encode(Kind.unavailable, forKey: .kind)
      try c.encode(reason, forKey: .reason)
    }
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    switch try c.decode(Kind.self, forKey: .kind) {
    case .available: self = .available(version: try c.decode(String.self, forKey: .version))
    case .unavailable: self = .unavailable(reason: try c.decode(String.self, forKey: .reason))
    }
  }
}

public enum RuntimeError: Error, Codable, Equatable, LocalizedError, Sendable {
  case unavailable(String)
  case invalid(String)
  case notFound(String)
  case conflict(String)
  case timeout(String)
  case unknown(String)

  private enum CodingKeys: String, CodingKey { case kind, cause }
  private enum Kind: String, Codable {
    case unavailable, invalid, notFound, conflict, timeout, unknown
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(kind, forKey: .kind)
    try c.encode(cause, forKey: .cause)
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let cause = try c.decode(String.self, forKey: .cause)
    switch try c.decode(Kind.self, forKey: .kind) {
    case .unavailable: self = .unavailable(cause)
    case .invalid: self = .invalid(cause)
    case .notFound: self = .notFound(cause)
    case .conflict: self = .conflict(cause)
    case .timeout: self = .timeout(cause)
    case .unknown: self = .unknown(cause)
    }
  }

  private var kind: Kind {
    switch self {
    case .unavailable: .unavailable
    case .invalid: .invalid
    case .notFound: .notFound
    case .conflict: .conflict
    case .timeout: .timeout
    case .unknown: .unknown
    }
  }

  private var cause: String {
    switch self {
    case .unavailable(let value), .invalid(let value), .notFound(let value), .conflict(let value),
      .timeout(let value), .unknown(let value):
      value
    }
  }

  public var errorDescription: String? { "\(kind.rawValue): \(cause)" }
}

public enum DomainEventKind: String, Codable, CaseIterable, Sendable {
  case runCreated = "RunCreated"
  case started = "Started"
  case exited = "Exited"
  case failed = "Failed"
  case healthChanged = "HealthChanged"
  case restartScheduled = "RestartScheduled"
  case skipped = "Skipped"
  case orphaned = "Orphaned"
}

public struct DomainEvent: Codable, Hashable, Sendable, Identifiable {
  public let id: UUID
  public let kind: DomainEventKind
  public let workloadID: UUID
  public let runID: UUID?
  public let occurredAt: Date
  public let message: String?

  public init(
    id: UUID = UUID(),
    kind: DomainEventKind,
    workloadID: UUID,
    runID: UUID? = nil,
    occurredAt: Date = Date(),
    message: String? = nil
  ) {
    self.id = id
    self.kind = kind
    self.workloadID = workloadID
    self.runID = runID
    self.occurredAt = occurredAt
    self.message = message
  }
}

public struct SchedulerCheckpoint: Codable, Hashable, Sendable {
  public let workloadID: UUID
  public var lastEvaluatedAt: Date

  public init(workloadID: UUID, lastEvaluatedAt: Date) {
    self.workloadID = workloadID
    self.lastEvaluatedAt = lastEvaluatedAt
  }
}

public struct SchedulerMissedWindow: Codable, Hashable, Sendable, Identifiable {
  public let id: UUID
  public let workloadID: UUID
  public let from: Date
  public let to: Date
  public let scheduledCount: Int

  public init(id: UUID = UUID(), workloadID: UUID, from: Date, to: Date, scheduledCount: Int) {
    self.id = id
    self.workloadID = workloadID
    self.from = from
    self.to = to
    self.scheduledCount = scheduledCount
  }
}

public struct MetricsSample: Codable, Hashable, Sendable, Identifiable {
  public let id: UUID
  public let runID: UUID
  public let timestamp: Date
  public let cpuPercent: Double
  public let memoryBytes: Int64

  public init(
    id: UUID = UUID(),
    runID: UUID,
    timestamp: Date = Date(),
    cpuPercent: Double,
    memoryBytes: Int64
  ) {
    self.id = id
    self.runID = runID
    self.timestamp = timestamp
    self.cpuPercent = cpuPercent
    self.memoryBytes = memoryBytes
  }
}

public enum ValidationError: Error, Equatable, LocalizedError, Sendable {
  case emptyName
  case duplicateName(String)
  case missingSource
  case invalidSource
  case invalidPort(Int)
  case duplicateGuestPort(Int)
  case duplicateHostPort(Int)
  case fixedPortRequiresSingleConcurrency
  case invalidConcurrency
  case invalidHash
  case pathNotFound(String)
  case invalidSchedule(String)
  case unsupportedHealthCheck
  case invalidEnvironmentKey(String)
  case duplicateEnvironmentKey(String)
  case invalidArgument

  public var errorDescription: String? {
    switch self {
    case .emptyName: "Name is required"
    case .duplicateName(let name): "Workload name already exists: \(name)"
    case .missingSource: "Runtime source is required"
    case .invalidSource: "Wasm source must be a local path or HTTPS URL"
    case .invalidPort(let port): "Port must be between 1 and 65535: \(port)"
    case .duplicateGuestPort(let port): "Duplicate guest port: \(port)"
    case .duplicateHostPort(let port): "Duplicate host port: \(port)"
    case .fixedPortRequiresSingleConcurrency: "Fixed host ports require maxConcurrentRuns = 1"
    case .invalidConcurrency: "maxConcurrentRuns must be at least 1"
    case .invalidHash: "SHA-256 must be 64 hexadecimal characters"
    case .pathNotFound(let path): "Path does not exist: \(path)"
    case .invalidSchedule(let value): "Invalid five-field cron: \(value)"
    case .unsupportedHealthCheck: "This health check is not supported by the selected runtime"
    case .invalidEnvironmentKey(let key): "Invalid environment variable key: \(key)"
    case .duplicateEnvironmentKey(let key): "Duplicate environment variable key: \(key)"
    case .invalidArgument: "Arguments cannot contain a null character"
    }
  }
}

public struct ValidationIssue: Equatable, Sendable, Identifiable {
  public let id = UUID()
  public let field: String
  public let message: String

  public init(field: String, message: String) {
    self.field = field
    self.message = message
  }
}

public enum ConfigurationValidator {
  public static func validate(
    workload: Workload,
    existing: [Workload] = [],
    fileManager: FileManager = .default
  ) -> [ValidationIssue] {
    var issues: [ValidationIssue] = []
    if workload.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      issues.append(.init(field: "name", message: ValidationError.emptyName.localizedDescription))
    }
    if existing.contains(where: {
      $0.id != workload.id && $0.name.caseInsensitiveCompare(workload.name) == .orderedSame
    }) {
      issues.append(
        .init(
          field: "name", message: ValidationError.duplicateName(workload.name).localizedDescription)
      )
    }
    issues += validate(revision: workload.draftRevision, fileManager: fileManager)

    let fixedPorts = workload.draftRevision.ports.compactMap(\.hostPort)
    for port in fixedPorts
    where existing.contains(where: { other in
      guard other.id != workload.id else { return false }
      return [other.activeRevision, other.draftRevision].contains { revision in
        revision.ports.contains { $0.hostPort == port }
      }
    }) {
      issues.append(
        .init(field: "ports", message: ValidationError.duplicateHostPort(port).localizedDescription)
      )
    }
    return deduplicate(issues)
  }

  public static func validate(
    revision: WorkloadRevision,
    fileManager: FileManager = .default
  ) -> [ValidationIssue] {
    var issues: [ValidationIssue] = []
    switch revision.spec {
    case .container(let spec):
      if spec.imageReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        issues.append(
          .init(
            field: "imageReference", message: ValidationError.missingSource.localizedDescription))
      }
      issues += validateMounts(spec.mounts, field: "mounts", fileManager: fileManager)
    case .wasm(let spec):
      let source = spec.source.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
      if source.isEmpty {
        issues.append(
          .init(field: "source", message: ValidationError.missingSource.localizedDescription))
      } else {
        switch spec.source {
        case .localPath(let path) where !fileManager.fileExists(atPath: path):
          issues.append(
            .init(
              field: "source", message: ValidationError.pathNotFound(path).localizedDescription))
        case .httpsURL(let rawURL):
          if URL(string: rawURL)?.scheme?.lowercased() != "https"
            || URL(string: rawURL)?.host?.isEmpty != false
          {
            issues.append(
              .init(field: "source", message: ValidationError.invalidSource.localizedDescription))
          }
        default:
          break
        }
      }
      if let expected = spec.expectedSHA256, !isSHA256(expected) {
        issues.append(
          .init(field: "expectedSHA256", message: ValidationError.invalidHash.localizedDescription))
      }
      issues += validateMounts(spec.preopens, field: "preopens", fileManager: fileManager)
      if !revision.ports.isEmpty && !spec.socketPermission {
        issues.append(
          .init(field: "ports", message: "Wasm port mappings require WASI socket access"))
      }
    }
    if let pinned = revision.pinnedArtifactID {
      let normalized =
        pinned.lowercased().hasPrefix("sha256:") ? String(pinned.dropFirst(7)) : pinned
      if !isSHA256(normalized) {
        issues.append(
          .init(
            field: "pinnedArtifactID", message: ValidationError.invalidHash.localizedDescription))
      }
    }

    var guestPorts = Set<Int>()
    var fixedHostPorts = Set<Int>()
    for mapping in revision.ports {
      if !(1...65_535).contains(mapping.guestPort) {
        issues.append(
          .init(
            field: "ports",
            message: ValidationError.invalidPort(mapping.guestPort).localizedDescription))
      }
      if !guestPorts.insert(mapping.guestPort).inserted {
        issues.append(
          .init(
            field: "ports",
            message: ValidationError.duplicateGuestPort(mapping.guestPort).localizedDescription))
      }
      if let hostPort = mapping.hostPort {
        if !(1...65_535).contains(hostPort) {
          issues.append(
            .init(
              field: "ports", message: ValidationError.invalidPort(hostPort).localizedDescription))
        }
        if !fixedHostPorts.insert(hostPort).inserted {
          issues.append(
            .init(
              field: "ports",
              message: ValidationError.duplicateHostPort(hostPort).localizedDescription))
        }
      }
    }
    if revision.concurrencyPolicy.maxConcurrentRuns < 1 {
      issues.append(
        .init(
          field: "maxConcurrentRuns",
          message: ValidationError.invalidConcurrency.localizedDescription))
    }
    if !fixedHostPorts.isEmpty && revision.concurrencyPolicy.maxConcurrentRuns > 1 {
      issues.append(
        .init(
          field: "maxConcurrentRuns",
          message: ValidationError.fixedPortRequiresSingleConcurrency.localizedDescription))
    }
    if revision.restartPolicy.maxRestartAttempts < 0 || revision.restartPolicy.stableFor < 0
      || revision.restartPolicy.backoff < 0
    {
      issues.append(
        .init(field: "restartPolicy", message: "Restart policy values must be non-negative"))
    }
    if revision.retentionPolicy.maxRuns < 0 || revision.retentionPolicy.logDays < 0 {
      issues.append(
        .init(field: "retentionPolicy", message: "Retention values must be non-negative"))
    }
    if revision.stopPolicy.timeout < 0 {
      issues.append(.init(field: "stopPolicy", message: "Stop timeout must be non-negative"))
    }
    if let health = revision.healthCheck {
      if health.failureThreshold < 1 || health.successThreshold < 1 || health.startPeriod < 0
        || health.unhealthyGracePeriod < 0
      {
        issues.append(
          .init(
            field: "healthCheck",
            message:
              "Health thresholds and timing must be non-negative; thresholds must be at least 1"))
      }
      issues += validateHealthCheck(
        health,
        supportsCommand: revision.kind == .appleContainer
      )
    }
    if revision.executionMode == .scheduled, revision.schedule == nil {
      issues.append(
        .init(field: "schedule", message: "Scheduled workloads require a cron schedule"))
    }
    var environmentKeys = Set<String>()
    for variable in revision.environment {
      if !isEnvironmentKey(variable.key) {
        issues.append(
          .init(
            field: "environment",
            message: ValidationError.invalidEnvironmentKey(variable.key).localizedDescription))
      }
      if !environmentKeys.insert(variable.key).inserted {
        issues.append(
          .init(
            field: "environment",
            message: ValidationError.duplicateEnvironmentKey(variable.key).localizedDescription))
      }
      if case .secret(let reference) = variable.value,
        reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        issues.append(.init(field: "environment", message: "Secret reference is required"))
      }
    }
    if revision.arguments.contains(where: { $0.utf8.contains(0) }) {
      issues.append(
        .init(field: "arguments", message: ValidationError.invalidArgument.localizedDescription))
    }
    return deduplicate(issues)
  }

  public static func isSHA256(_ value: String) -> Bool {
    value.count == 64 && value.allSatisfy { $0.isHexDigit }
  }
  private static func validateHealthCheck(
    _ health: HealthCheck, supportsCommand: Bool
  ) -> [ValidationIssue] {
    switch health.kind {
    case .command(let command):
      if !supportsCommand {
        return [
          .init(
            field: "healthCheck",
            message: ValidationError.unsupportedHealthCheck.localizedDescription)
        ]
      }
      guard !command.isEmpty, command.allSatisfy({ !$0.isEmpty && !$0.utf8.contains(0) }) else {
        return [
          .init(field: "healthCheck", message: "Command health check requires a valid command")
        ]
      }
    case .http(let rawURL):
      guard let url = URL(string: rawURL), let scheme = url.scheme?.lowercased(),
        scheme == "http" || scheme == "https", url.host?.isEmpty == false
      else {
        return [.init(field: "healthCheck", message: "HTTP health check requires a valid URL")]
      }
    case .tcp(let host, let port):
      var issues: [ValidationIssue] = []
      if host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        issues.append(.init(field: "healthCheck", message: "TCP health check requires a host"))
      }
      if !(1...65_535).contains(port) {
        issues.append(
          .init(
            field: "healthCheck", message: ValidationError.invalidPort(port).localizedDescription))
      }
      return issues
    }
    return []
  }

  private static func validateMounts(_ mounts: [Mount], field: String, fileManager: FileManager)
    -> [ValidationIssue]
  {
    mounts.flatMap { mount -> [ValidationIssue] in
      var issues: [ValidationIssue] = []
      if !fileManager.fileExists(atPath: mount.hostPath) {
        issues.append(
          .init(
            field: field, message: ValidationError.pathNotFound(mount.hostPath).localizedDescription
          ))
      }
      if mount.guestPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        issues.append(.init(field: field, message: "Guest path is required"))
      }
      return issues
    }
  }

  private static func isEnvironmentKey(_ key: String) -> Bool {
    guard let first = key.first, first.isLetter || first == "_" else { return false }
    return key.dropFirst().allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
  }

  private static func deduplicate(_ issues: [ValidationIssue]) -> [ValidationIssue] {
    var seen = Set<String>()
    return issues.filter { seen.insert("\($0.field):\($0.message)").inserted }
  }
}

public struct HealthTracker: Sendable {
  public private(set) var status: HealthStatus
  public private(set) var consecutiveFailures: Int
  public private(set) var consecutiveSuccesses: Int
  public private(set) var unhealthySince: Date?
  public private(set) var healthySince: Date?
  public private(set) var startedAt: Date?

  public init(status: HealthStatus = .unknown) {
    self.status = status
    self.consecutiveFailures = 0
    self.consecutiveSuccesses = 0
    self.unhealthySince = nil
    self.healthySince = nil
    self.startedAt = nil
  }

  public mutating func start(at date: Date) {
    startedAt = date
    status = .unknown
    consecutiveFailures = 0
    consecutiveSuccesses = 0
    unhealthySince = nil
    healthySince = nil
  }

  @discardableResult
  public mutating func record(success: Bool, check: HealthCheck, at date: Date = Date())
    -> HealthStatus
  {
    if let startedAt, date.timeIntervalSince(startedAt) < check.startPeriod {
      return status
    }
    if success {
      consecutiveFailures = 0
      consecutiveSuccesses += 1
      if consecutiveSuccesses >= check.successThreshold {
        status = .healthy
        healthySince = healthySince ?? date
        unhealthySince = nil
      }
    } else {
      consecutiveSuccesses = 0
      consecutiveFailures += 1
      healthySince = nil
      if consecutiveFailures >= check.failureThreshold {
        status = .unhealthy
        unhealthySince = unhealthySince ?? date
      }
    }
    return status
  }

  public func restartEligible(check: HealthCheck, at date: Date = Date()) -> Bool {
    guard status == .unhealthy, let unhealthySince else { return false }
    return date.timeIntervalSince(unhealthySince) >= check.unhealthyGracePeriod
  }
  public func isStable(for duration: TimeInterval, at date: Date = Date()) -> Bool {
    guard status == .healthy, let healthySince else { return false }
    return date.timeIntervalSince(healthySince) >= duration
  }
}

public enum RuntimeStateDeriver {
  public static func derive(
    workload: Workload,
    latestRun: Run?,
    health: HealthStatus,
    inspection: RuntimeInspection?,
    configurationIssues: [ValidationIssue] = [],
    runtimeAvailability: RuntimeAvailability? = nil,
    updateRequiresRestart: Bool = false,
    updateFailed: Bool = false,
    restartExhausted: Bool = false,
    updating: Bool = false,
    restarting: Bool = false
  ) -> RuntimeState {
    if !configurationIssues.isEmpty { return .invalidConfig }
    if case .unavailable = runtimeAvailability { return .runtimeUnavailable }
    if updateFailed { return .updateFailed }
    if updating { return .updating }
    if updateRequiresRestart { return .updateRequiresRestart }
    if restartExhausted { return .failed }
    if inspection?.state == .orphaned { return .orphaned }
    if restarting { return .restarting }
    if workload.desiredState == .running {
      if health == .unhealthy { return .unhealthy }
      if inspection?.state == .running || latestRun?.state == .running { return .running }
      if latestRun?.state == .starting || latestRun?.state == .pending { return .starting }
      if latestRun?.state == .failed { return .failed }
      return .starting
    }
    if inspection?.state == .running || latestRun?.state == .terminating { return .blocked }
    if latestRun?.state == .running || latestRun?.state == .starting { return .running }
    if latestRun?.state == .failed { return .failed }
    return .stopped
  }
}

public struct CronExpression: Codable, Hashable, Sendable {
  public let expression: String
  private let minutes: Set<Int>
  private let hours: Set<Int>
  private let daysOfMonth: Set<Int>
  private let months: Set<Int>
  private let daysOfWeek: Set<Int>
  private let dayOfMonthWildcard: Bool
  private let dayOfWeekWildcard: Bool

  public init(_ expression: String) throws {
    let fields = expression.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    guard fields.count == 5 else { throw ValidationError.invalidSchedule(expression) }
    self.expression = expression
    do {
      minutes = try Self.parseField(fields[0], range: 0...59, normalizeWeekday: false)
      hours = try Self.parseField(fields[1], range: 0...23, normalizeWeekday: false)
      daysOfMonth = try Self.parseField(fields[2], range: 1...31, normalizeWeekday: false)
      months = try Self.parseField(fields[3], range: 1...12, normalizeWeekday: false)
      daysOfWeek = try Self.parseField(fields[4], range: 0...7, normalizeWeekday: true)
      dayOfMonthWildcard = Self.isWildcard(fields[2])
      dayOfWeekWildcard = Self.isWildcard(fields[4])
    } catch {
      throw ValidationError.invalidSchedule(expression)
    }
  }

  public init(from decoder: Decoder) throws {
    try self.init(try decoder.singleValueContainer().decode(String.self))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(expression)
  }

  public func next(after date: Date, calendar: Calendar = .current) -> Date? {
    var calendar = calendar
    calendar.locale = Locale(identifier: "en_US_POSIX")
    var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    components.second = 0
    guard var candidate = calendar.date(from: components) else { return nil }
    if candidate <= date {
      candidate = calendar.date(byAdding: .minute, value: 1, to: candidate) ?? candidate
    }

    for _ in 0..<1_051_200 {
      let parts = calendar.dateComponents(
        [.year, .month, .day, .hour, .minute, .weekday], from: candidate)
      if matches(parts), !isRepeatedWallMinute(candidate, calendar: calendar), candidate > date {
        return candidate
      }
      guard let next = calendar.date(byAdding: .minute, value: 1, to: candidate) else {
        return nil
      }
      candidate = next
    }
    return nil
  }

  public func matches(_ date: Date, calendar: Calendar = .current) -> Bool {
    var calendar = calendar
    calendar.locale = Locale(identifier: "en_US_POSIX")
    return matches(
      calendar.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: date))
  }

  private func matches(_ components: DateComponents) -> Bool {
    guard let minute = components.minute, let hour = components.hour, let day = components.day,
      let month = components.month, let weekday = components.weekday
    else { return false }
    let cronWeekday = (weekday - 1) % 7
    let dayMatches = daysOfMonth.contains(day)
    let weekdayMatches = daysOfWeek.contains(cronWeekday)
    let dayAllowed =
      dayOfMonthWildcard && dayOfWeekWildcard
      ? true
      : dayOfMonthWildcard
        ? weekdayMatches
        : dayOfWeekWildcard
          ? dayMatches
          : dayMatches || weekdayMatches
    return minutes.contains(minute) && hours.contains(hour) && months.contains(month) && dayAllowed
  }

  private static func isWildcard(_ field: String) -> Bool {
    field == "*" || field == "*/1"
  }

  private func isRepeatedWallMinute(_ date: Date, calendar: Calendar) -> Bool {
    let current = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    guard let lookback = calendar.date(byAdding: .hour, value: -3, to: date),
      calendar.timeZone.secondsFromGMT(for: lookback)
        != calendar.timeZone.secondsFromGMT(for: date)
    else {
      return false
    }
    var previous = date
    for _ in 1...180 {
      guard let candidate = calendar.date(byAdding: .minute, value: -1, to: previous) else {
        return false
      }
      let prior = calendar.dateComponents(
        [.year, .month, .day, .hour, .minute], from: candidate)
      if current == prior { return true }
      previous = candidate
    }
    return false
  }

  private static func parseField(_ field: String, range: ClosedRange<Int>, normalizeWeekday: Bool)
    throws -> Set<Int>
  {
    guard !field.isEmpty else { throw ValidationError.invalidSchedule(field) }
    var result = Set<Int>()
    for component in field.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    {
      guard !component.isEmpty else { throw ValidationError.invalidSchedule(field) }
      let parts = component.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
      guard parts.count <= 2, !parts.contains(where: \.isEmpty) else {
        throw ValidationError.invalidSchedule(field)
      }
      let step = parts.count == 2 ? Int(parts[1]) : 1
      guard let step, step > 0 else { throw ValidationError.invalidSchedule(field) }
      let base = parts[0]
      let bounds: (Int, Int)
      if base == "*" {
        bounds = (range.lowerBound, range.upperBound)
      } else if base.contains("-") {
        let values = base.split(separator: "-", omittingEmptySubsequences: false).compactMap {
          Int($0)
        }
        guard values.count == 2, values[0] <= values[1] else {
          throw ValidationError.invalidSchedule(field)
        }
        bounds = (values[0], values[1])
      } else if let value = Int(base) {
        bounds = (value, value)
      } else {
        throw ValidationError.invalidSchedule(field)
      }
      guard range.contains(bounds.0), range.contains(bounds.1) else {
        throw ValidationError.invalidSchedule(field)
      }
      for value in stride(from: bounds.0, through: bounds.1, by: step) {
        result.insert(normalizeWeekday && value == 7 ? 0 : value)
      }
    }
    return result
  }
}

public struct HealthTransition: Equatable, Sendable {
  public let status: HealthStatus
  public let restartEligible: Bool

  public init(status: HealthStatus, restartEligible: Bool) {
    self.status = status
    self.restartEligible = restartEligible
  }
}
