import Darwin
import Foundation

public enum WorkloadServiceError: Error, Equatable, LocalizedError, Sendable {
  case workloadNotFound(UUID)
  case invalidConfiguration([ValidationIssue])
  case runtimeUnavailable(String)
  case noRunningRun
  case restartChoiceRequired
  case updateRequiresRestart
  case updateFailed(String)
  case cannotDeleteRunningWorkload
  case concurrencyLimitReached(Int)

  public var errorDescription: String? {
    switch self {
    case .workloadNotFound(let id): "Workload not found: \(id.uuidString)"
    case .invalidConfiguration(let issues): issues.map(\.message).joined(separator: ", ")
    case .runtimeUnavailable(let reason): "Runtime unavailable: \(reason)"
    case .noRunningRun: "No running run"
    case .restartChoiceRequired: "Choose normal restart or rolling update"
    case .updateRequiresRestart: "The active revision requires a restart"
    case .updateFailed(let reason): "Update failed: \(reason)"
    case .cannotDeleteRunningWorkload: "Workload could not be stopped; deletion was not performed"
    case .concurrencyLimitReached(let limit): "Maximum concurrent runs reached: \(limit)"
    }
  }
}

public enum ApplyRestartStrategy: String, CaseIterable, Sendable {
  case none
  case normalRestart
  case rollingUpdate
}

public struct WorkloadStatusSnapshot: Sendable {
  public let workload: Workload
  public let runtimeState: RuntimeState
  public let health: HealthStatus
  public let latestRun: Run?
  public let nextRun: Date?
  public let configurationIssues: [ValidationIssue]
  public let orphanedProcesses: [RuntimeProcess]

  public init(
    workload: Workload,
    runtimeState: RuntimeState,
    health: HealthStatus,
    latestRun: Run?,
    nextRun: Date?,
    configurationIssues: [ValidationIssue],
    orphanedProcesses: [RuntimeProcess] = []
  ) {
    self.workload = workload
    self.runtimeState = runtimeState
    self.health = health
    self.latestRun = latestRun
    self.nextRun = nextRun
    self.configurationIssues = configurationIssues
    self.orphanedProcesses = orphanedProcesses
  }
}

public actor DomainEventBus {
  private var continuations: [UUID: AsyncStream<DomainEvent>.Continuation] = [:]

  public init() {}

  public func subscribe() -> AsyncStream<DomainEvent> {
    let id = UUID()
    return AsyncStream { continuation in
      continuations[id] = continuation
      continuation.onTermination = { @Sendable _ in
        Task { await self.remove(id: id) }
      }
    }
  }

  public func publish(_ event: DomainEvent) {
    for continuation in continuations.values { continuation.yield(event) }
  }

  private func remove(id: UUID) { continuations.removeValue(forKey: id) }
}

public actor PortAllocator {
  private var allocated: Set<Int> = []
  private var nextCandidate = 40_000

  public init() {}

  public func reserve(_ requested: Int?) throws -> Int {
    if let requested {
      guard !allocated.contains(requested), Self.canBind(requested) else {
        throw RuntimeError.conflict("host port \(requested) is already in use")
      }
      allocated.insert(requested)
      return requested
    }
    while nextCandidate <= 60_000
      && (allocated.contains(nextCandidate) || !Self.canBind(nextCandidate))
    {
      nextCandidate += 1
    }
    guard nextCandidate <= 60_000 else {
      throw RuntimeError.conflict("no automatic host port is available")
    }
    let selected = nextCandidate
    allocated.insert(selected)
    nextCandidate += 1
    return selected
  }

  private static func canBind(_ port: Int) -> Bool {
    guard (1...65_535).contains(port) else { return false }
    let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return false }
    defer { Darwin.close(descriptor) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(UInt16(port).bigEndian)
    address.sin_addr = in_addr(s_addr: INADDR_ANY)
    return withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
      }
    }
  }

  public func release(_ ports: [Int]) {
    for port in ports { allocated.remove(port) }
  }

  public func claim(_ ports: [Int]) {
    allocated.formUnion(ports.filter { (1...65_535).contains($0) })
  }
}

private struct QuitTarget: Sendable {
  let workloadID: UUID
  let runID: UUID
  let process: RuntimeProcess
  let adapter: any RuntimeAdapter
  let policy: StopPolicy
}

private enum QuitDisposition: Sendable, Equatable {
  case terminated
  case natural(Int32?)
  case failed
}

public actor WorkloadService {
  public let store: any WasmboxStore
  public let runtime: any RuntimeAdapter
  public let resolver: any ArtifactResolver
  public let secretStore: any SecretStore
  public let logs: any LogStore
  public let eventBus: DomainEventBus
  public nonisolated let persistenceWarning: String?
  public nonisolated let persistenceReadOnly: Bool

  private let environmentResolver: EnvironmentResolver
  private let portAllocator: PortAllocator
  private let healthMonitor: HealthMonitor
  private let metricsCollector: MetricsCollector
  private let runtimes: [RuntimeKind: any RuntimeAdapter]
  private var processes: [UUID: [UUID: RuntimeProcess]] = [:]
  private var runningRevisionIDs: [UUID: [UUID: UUID]] = [:]
  private var runtimeByRun: [UUID: any RuntimeAdapter] = [:]
  private var healthByWorkload: [UUID: HealthStatus] = [:]
  private var runtimeAvailability: [RuntimeKind: RuntimeAvailability] = [:]
  private var updateFailures: Set<UUID> = []
  private var updatingWorkloads: Set<UUID> = []
  private var restartingWorkloads: Set<UUID> = []
  private var scheduledSlots: [UUID: Date] = [:]
  private var lastMaintenanceAt: Date?
  private var reservedSlotsByWorkload: [UUID: Int] = [:]
  private var logOffsets: [UUID: (stdout: Int, stderr: Int)] = [:]
  private var secretValuesByRun: [UUID: [String]] = [:]
  private var stableWorkloads: Set<UUID> = []
  private var restartExhausted: Set<UUID> = []
  private var orphanedProcessesByWorkload: [UUID: [String: RuntimeProcess]] = [:]

  public init(
    store: any WasmboxStore = InMemoryStore(),
    runtime: any RuntimeAdapter = UnavailableRuntimeAdapter(kind: .wasmtime),
    containerRuntime: (any RuntimeAdapter)? = nil,
    wasmRuntime: (any RuntimeAdapter)? = nil,
    resolver: any ArtifactResolver = LocalArtifactResolver(),
    secretStore: any SecretStore = InMemorySecretStore(),
    logs: any LogStore = FileLogStore(),
    eventBus: DomainEventBus = DomainEventBus(),
    portAllocator: PortAllocator = PortAllocator(),
    healthMonitor: HealthMonitor = HealthMonitor()
  ) {
    self.store = store
    self.runtime = runtime
    var registeredRuntimes: [RuntimeKind: any RuntimeAdapter] = [runtime.kind: runtime]
    if let containerRuntime { registeredRuntimes[.appleContainer] = containerRuntime }
    if let wasmRuntime { registeredRuntimes[.wasmtime] = wasmRuntime }
    self.runtimes = registeredRuntimes
    self.resolver = resolver
    self.secretStore = secretStore
    self.logs = logs
    self.eventBus = eventBus
    self.environmentResolver = EnvironmentResolver(secretStore: secretStore)
    self.portAllocator = portAllocator
    self.healthMonitor = healthMonitor
    if let sqlite = store as? SQLiteStore {
      self.persistenceWarning = sqlite.migrationWarning
      self.persistenceReadOnly = sqlite.isReadOnly
    } else {
      self.persistenceWarning = nil
      self.persistenceReadOnly = false
    }
    self.metricsCollector = MetricsCollector(store: store)
  }
  private func runtime(for kind: RuntimeKind) -> any RuntimeAdapter {
    runtimes[kind] ?? runtime
  }

  public func allWorkloads() async throws -> [Workload] { try await store.listWorkloads() }

  public func workload(id: UUID) async throws -> Workload? { try await store.loadWorkload(id: id) }

  public func runs(workloadID: UUID) async throws -> [Run] {
    try await store.listRuns(workloadID: workloadID)
  }

  public func events(workloadID: UUID, runID: UUID? = nil) async throws -> [DomainEvent] {
    try await store.listEvents(workloadID: workloadID, runID: runID)
  }

  public func metrics(runID: UUID, since: Date? = nil) async throws -> [MetricsSample] {
    try await store.listMetrics(runID: runID, since: since)
  }

  public func missedWindows(workloadID: UUID) async throws -> [SchedulerMissedWindow] {
    try await store.listMissedWindows(workloadID: workloadID)
  }
  public func metricAggregates(runID: UUID, since: Date? = nil) async throws -> [MetricAggregate] {
    try await metricsCollector.aggregate(runID: runID, since: since)
  }
  public func garbageCollectArtifacts() async throws -> [String] {
    guard let localResolver = resolver as? LocalArtifactResolver else { return [] }
    let workloads = try await store.listWorkloads()
    var referenced = Set<String>()
    for workload in workloads {
      for revision in [workload.activeRevision, workload.draftRevision] {
        if let pinned = revision.pinnedArtifactID {
          referenced.insert(Self.normalizedArtifactID(pinned))
        }
      }
      for run in try await store.listRuns(workloadID: workload.id) {
        if let artifactID = run.resolvedArtifactID {
          referenced.insert(Self.normalizedArtifactID(artifactID))
        }
      }
    }
    return try await localResolver.cache.removeUnreferenced(keeping: referenced)
  }

  private static func normalizedArtifactID(_ value: String) -> String {
    let normalized = value.lowercased()
    return normalized.hasPrefix("sha256:") ? String(normalized.dropFirst(7)) : normalized
  }

  public func createWorkload(_ workload: Workload) async throws -> Workload {
    let existing = try await store.listWorkloads()
    let issues = ConfigurationValidator.validate(workload: workload, existing: existing)
    guard issues.isEmpty else { throw WorkloadServiceError.invalidConfiguration(issues) }
    try await store.apply([.saveWorkload(workload)])
    return workload
  }

  public func createWorkload(
    name: String,
    tags: [String] = [],
    revision: WorkloadRevision
  ) async throws -> Workload {
    try await createWorkload(Workload(name: name, tags: tags, activeRevision: revision))
  }

  public func saveDraft(workloadID: UUID, revision: WorkloadRevision) async throws -> Workload {
    guard var workload = try await store.loadWorkload(id: workloadID) else {
      throw WorkloadServiceError.workloadNotFound(workloadID)
    }
    let previousReferences = Self.secretReferences(workload)
    var copy = workload
    copy.updateDraft(revision)
    let existing = try await store.listWorkloads()
    let issues = ConfigurationValidator.validate(workload: copy, existing: existing)
    guard issues.isEmpty else { throw WorkloadServiceError.invalidConfiguration(issues) }
    workload.updateDraft(revision)
    try await store.apply([.saveWorkload(workload)])
    await removeUnusedSecrets(previousReferences)
    return workload
  }

  public func saveDraft(
    workloadID: UUID,
    revision: WorkloadRevision,
    secretUpdates: [String: String]
  ) async throws -> Workload {
    guard var workload = try await store.loadWorkload(id: workloadID) else {
      throw WorkloadServiceError.workloadNotFound(workloadID)
    }
    let previousReferences = Self.secretReferences(workload)
    var candidate = workload
    candidate.updateDraft(revision)
    let issues = ConfigurationValidator.validate(
      workload: candidate, existing: try await store.listWorkloads())
    guard issues.isEmpty else { throw WorkloadServiceError.invalidConfiguration(issues) }

    var previous: [String: String?] = [:]
    do {
      for (reference, value) in secretUpdates {
        previous[reference] = try await secretStore.read(reference: reference)
        try await secretStore.write(value: value, reference: reference)
      }
      workload.updateDraft(revision)
      try await store.apply([.saveWorkload(workload)])
      await removeUnusedSecrets(previousReferences)
      return workload
    } catch {
      for (reference, value) in previous {
        if let value {
          try? await secretStore.write(value: value, reference: reference)
        } else {
          try? await secretStore.delete(reference: reference)
        }
      }
      throw error
    }
  }

  public func refreshAndPin(workloadID: UUID) async throws -> Workload {
    guard let workload = try await store.loadWorkload(id: workloadID) else {
      throw WorkloadServiceError.workloadNotFound(workloadID)
    }
    let revision = workload.draftRevision
    let expectedHash: String?
    let allowInsecureTLS: Bool
    switch revision.spec {
    case .container:
      expectedHash = nil
      allowInsecureTLS = false
    case .wasm(let spec):
      expectedHash = spec.expectedSHA256
      allowInsecureTLS = spec.allowInsecureTLS
    }
    let resolved = try await resolver.resolve(
      source: revision.spec,
      updatePolicy: .refreshOnStart,
      pinnedArtifactID: nil,
      expectedHash: expectedHash,
      allowInsecureTLS: allowInsecureTLS)
    var pinnedRevision = revision
    pinnedRevision.artifactUpdatePolicy = .pinned
    pinnedRevision.pinnedArtifactID = resolved.id
    return try await saveDraft(workloadID: workloadID, revision: pinnedRevision)
  }

  public func discardDraft(workloadID: UUID) async throws -> Workload {
    guard var workload = try await store.loadWorkload(id: workloadID) else {
      throw WorkloadServiceError.workloadNotFound(workloadID)
    }
    let previousReferences = Self.secretReferences(workload)
    workload.discardDraft()
    try await store.apply([.saveWorkload(workload)])
    await removeUnusedSecrets(previousReferences)
    return workload
  }

  public func applyDraft(
    workloadID: UUID,
    strategy: ApplyRestartStrategy = .none
  ) async throws -> Workload {
    guard var workload = try await store.loadWorkload(id: workloadID) else {
      throw WorkloadServiceError.workloadNotFound(workloadID)
    }
    let existing = try await store.listWorkloads()
    let issues = ConfigurationValidator.validate(workload: workload, existing: existing)
    guard issues.isEmpty else { throw WorkloadServiceError.invalidConfiguration(issues) }
    let wasRunning =
      workload.desiredState == .running
      && !(processes[workloadID]?.isEmpty ?? true)
    if wasRunning && strategy == .none { throw WorkloadServiceError.restartChoiceRequired }
    let previousReferences = Self.secretReferences(workload)
    let previous = workload
    workload.applyDraft()

    if wasRunning {
      switch strategy {
      case .normalRestart,
        .rollingUpdate where workload.activeRevision.ports.isEmpty:
        try await store.apply([.saveWorkload(workload)])
        _ = try await restartWorkload(id: workloadID)
      case .rollingUpdate:
        if runtime(for: workload.activeRevision.spec.kind).supportsPortHandoff {
          do {
            updatingWorkloads.insert(workloadID)
            defer { updatingWorkloads.remove(workloadID) }
            try await rollingUpdate(workload: workload)
            try await store.apply([.saveWorkload(workload)])
            updateFailures.remove(workloadID)
          } catch {
            try? await store.apply([.saveWorkload(previous)])
            updateFailures.insert(workloadID)
            throw WorkloadServiceError.updateFailed(error.localizedDescription)
          }
        } else {
          try await store.apply([.saveWorkload(workload)])
          _ = try await restartWorkload(id: workloadID)
        }
      case .none:
        break
      }
    } else {
      try await store.apply([.saveWorkload(workload)])
      updateFailures.remove(workloadID)
    }
    await removeUnusedSecrets(previousReferences)
    return workload
  }

  public func checkAvailability(for kind: RuntimeKind) async -> RuntimeAvailability {
    let adapter = runtime(for: kind)
    let availability = await adapter.checkAvailability()
    runtimeAvailability[kind] = availability
    return availability
  }

  public func checkAvailability() async -> RuntimeAvailability {
    await checkAvailability(for: runtime.kind)
  }

  public func recoverRuntimeState() async {
    let workloads = (try? await store.listWorkloads()) ?? []
    let workloadsByID = Dictionary(uniqueKeysWithValues: workloads.map { ($0.id, $0) })
    orphanedProcessesByWorkload.removeAll()

    for kind in RuntimeKind.allCases {
      let adapter = runtime(for: kind)
      let availability = await adapter.checkAvailability()
      runtimeAvailability[kind] = availability
      guard case .available = availability else { continue }
      let discovered = (try? await adapter.listManagedProcesses()) ?? []
      let discoveredByName = Dictionary(
        uniqueKeysWithValues: discovered.map { ($0.runtimeName, $0) })

      for workload in workloads where workload.kind == kind {
        let runs = (try? await store.listRuns(workloadID: workload.id)) ?? []
        for var run in runs where !run.state.isTerminal {
          let listed = discoveredByName[run.runtimeName]
          guard let inspection = try? await adapter.inspect(runtimeName: run.runtimeName) else {
            continue
          }
          guard inspection.state == .running else {
            guard inspection.state == .stopped else { continue }
            try? run.finish(exitCode: inspection.exitCode)
            let event = DomainEvent(kind: .exited, workloadID: workload.id, runID: run.id)
            try? await commit([.saveRun(run), .appendEvent(event)], publishing: [event])
            continue
          }
          let process = RuntimeProcess(
            id: run.runtimeProcessID ?? listed?.id ?? run.runtimeName,
            runID: run.id,
            runtimeName: run.runtimeName,
            hostPorts: run.assignedHostPorts ?? listed?.hostPorts ?? [])
          await portAllocator.claim(process.hostPorts)
          run.adopt(processID: process.id)
          try? await store.saveRun(run)
          processes[workload.id, default: [:]][run.id] = process
          runningRevisionIDs[workload.id, default: [:]][run.id] =
            run.runningRevisionID ?? workload.activeRevision.id
          runtimeByRun[run.id] = adapter
          healthByWorkload[workload.id] =
            workload.activeRevision.healthCheck == nil ? .notConfigured : .unknown
          await healthMonitor.start(workloadID: workload.id, at: run.startedTime ?? Date())
        }
      }

      for process in discovered {
        guard let parsed = Workload.parseRuntimeName(process.runtimeName),
          let workload = workloadsByID[parsed.workloadID], workload.kind == kind,
          processes[workload.id]?[parsed.runID] == nil,
          (try? await adapter.inspect(runtimeName: process.runtimeName).state) == .running
        else { continue }
        orphanedProcessesByWorkload[workload.id, default: [:]][process.runtimeName] = process
        await emit(
          .init(
            kind: .orphaned, workloadID: workload.id, runID: parsed.runID,
            message: process.runtimeName))
      }
    }

    try? await performMaintenance()

    for workload in workloads
    where workload.desiredState == .running
      && (processes[workload.id]?.isEmpty ?? true)
      && (orphanedProcessesByWorkload[workload.id]?.isEmpty ?? true)
    {
      _ = try? await startWorkload(id: workload.id, trigger: .resume)
    }
  }

  public func orphanedProcesses(workloadID: UUID) -> [RuntimeProcess] {
    guard let values = orphanedProcessesByWorkload[workloadID]?.values else { return [] }
    return values.sorted { $0.runtimeName < $1.runtimeName }
  }

  public func adoptOrphan(workloadID: UUID, runtimeName: String) async throws {
    guard let workload = try await store.loadWorkload(id: workloadID) else {
      throw WorkloadServiceError.workloadNotFound(workloadID)
    }
    guard let process = orphanedProcessesByWorkload[workloadID]?[runtimeName],
      let parsed = Workload.parseRuntimeName(runtimeName), parsed.workloadID == workloadID
    else { throw RuntimeError.notFound(runtimeName) }
    let adapter = runtime(for: workload.kind)
    var run =
      try await store.loadRun(id: parsed.runID)
      ?? Run(
        id: parsed.runID, workloadID: workloadID, trigger: .resume,
        resolvedSource: sourceString(for: workload.activeRevision.spec))
    run.adopt(processID: process.id)
    run.attach(
      processID: process.id,
      hostPorts: process.hostPorts,
      revisionID: workload.activeRevision.id)
    await portAllocator.claim(process.hostPorts)
    let adopted = DomainEvent(
      kind: .started, workloadID: workloadID, runID: run.id, message: "Adopted")
    try await commit([.saveRun(run), .appendEvent(adopted)], publishing: [adopted])
    processes[workloadID, default: [:]][run.id] = process
    runningRevisionIDs[workloadID, default: [:]][run.id] = workload.activeRevision.id
    runtimeByRun[run.id] = adapter
    orphanedProcessesByWorkload[workloadID]?.removeValue(forKey: runtimeName)
  }

  public func stopOrphan(workloadID: UUID, runtimeName: String) async throws {
    guard let workload = try await store.loadWorkload(id: workloadID) else {
      throw WorkloadServiceError.workloadNotFound(workloadID)
    }
    guard let process = orphanedProcessesByWorkload[workloadID]?[runtimeName] else {
      throw RuntimeError.notFound(runtimeName)
    }
    try await runtime(for: workload.kind).forceStop(process)
    await portAllocator.release(process.hostPorts)
    orphanedProcessesByWorkload[workloadID]?.removeValue(forKey: runtimeName)
  }

  public func startWorkload(
    id: UUID,
    trigger: RunTrigger = .manual,
    scheduledTime: Date? = nil,
    restartChainID: UUID? = nil,
    attemptIndex: Int? = nil
  ) async throws -> Run {
    guard var workload = try await store.loadWorkload(id: id) else {
      throw WorkloadServiceError.workloadNotFound(id)
    }
    let issues = ConfigurationValidator.validate(
      workload: workload, existing: try await store.listWorkloads())
    guard issues.isEmpty else { throw WorkloadServiceError.invalidConfiguration(issues) }
    let activeRunCount = (try await store.listRuns(workloadID: id)).count { !$0.state.isTerminal }
    let concurrencyLimit = workload.activeRevision.concurrencyPolicy.maxConcurrentRuns
    if activeRunCount + reservedSlotsByWorkload[id, default: 0] >= concurrencyLimit {
      if trigger == .scheduled, let scheduledTime {
        return try await recordSkippedRun(
          workload: workload, scheduledTime: scheduledTime, reason: "MaxConcurrentRuns")
      }
      throw WorkloadServiceError.concurrencyLimitReached(concurrencyLimit)
    }
    reservedSlotsByWorkload[id, default: 0] += 1
    defer {
      reservedSlotsByWorkload[id, default: 1] -= 1
      if reservedSlotsByWorkload[id] == 0 { reservedSlotsByWorkload.removeValue(forKey: id) }
    }
    let adapter = runtime(for: workload.kind)
    let availability = await adapter.checkAvailability()
    runtimeAvailability[workload.kind] = availability
    guard case .available = availability else {
      let reason: String
      if case .unavailable(let value) = availability { reason = value } else { reason = "unknown" }
      throw WorkloadServiceError.runtimeUnavailable(reason)
    }
    if workload.activeRevision.executionMode == .alwaysOn {
      workload.desiredState = .running
      try await store.saveWorkload(workload)
    }

    let source = sourceString(for: workload.activeRevision.spec)
    let artifact: ResolvedArtifact
    do {
      artifact = try await resolve(workload: workload)
    } catch {
      return try await recordFailedRun(
        workload: workload, trigger: trigger, scheduledTime: scheduledTime, source: source,
        error: error)
    }

    if workload.activeRevision.artifactUpdatePolicy == .pinned,
      workload.activeRevision.pinnedArtifactID == nil
    {
      let draftMatchesActive = workload.draftRevision == workload.activeRevision
      workload.activeRevision.pinnedArtifactID = artifact.id
      if draftMatchesActive { workload.draftRevision = workload.activeRevision }
      workload.updatedAt = Date()
      try await store.saveWorkload(workload)
    }

    let chainID: UUID
    if let restartChainID {
      chainID = restartChainID
    } else if trigger == .restart || trigger == .resume {
      chainID = try await latestRestartChain(workloadID: id) ?? UUID()
    } else {
      chainID = UUID()
    }
    let attempt: Int
    if let attemptIndex {
      attempt = attemptIndex
    } else if trigger == .restart {
      attempt = try await nextAttempt(workloadID: id, chainID: chainID)
    } else {
      attempt = 0
    }
    var run = Run(
      workloadID: workload.id,
      trigger: trigger,
      scheduledTime: scheduledTime,
      resolvedArtifactID: artifact.id,
      resolvedSource: source,
      restartChainID: chainID,
      attemptIndex: attempt
    )
    let created = DomainEvent(kind: .runCreated, workloadID: id, runID: run.id)
    try await commit([.saveRun(run), .appendEvent(created)], publishing: [created])
    var assignedRevision: WorkloadRevision?
    var startedProcess: RuntimeProcess?
    do {
      try run.transition(to: .starting)
      try await store.saveRun(run)
      let environment = try await environmentResolver.resolve(workload.activeRevision.environment)
      let runSecrets = await secretValues(for: workload)
      let revision = try await revisionWithAssignedPorts(workload.activeRevision)
      assignedRevision = revision
      let process = try await adapter.start(
        run: run, revision: revision, artifact: artifact, environment: environment)
      startedProcess = process
      run.attach(
        processID: process.id,
        hostPorts: process.hostPorts,
        revisionID: revision.id,
        finalURL: artifact.finalURL)
      try run.transition(to: .running)
      let started = DomainEvent(kind: .started, workloadID: id, runID: run.id)
      try await commit([.saveRun(run), .appendEvent(started)], publishing: [started])
      secretValuesByRun[run.id] = runSecrets
      processes[id, default: [:]][run.id] = process
      runningRevisionIDs[id, default: [:]][run.id] = revision.id
      runtimeByRun[run.id] = adapter
      restartExhausted.remove(id)
      stableWorkloads.remove(id)
      await healthMonitor.start(workloadID: id, at: run.startedTime ?? Date())
      healthByWorkload[id] = workload.activeRevision.healthCheck == nil ? .notConfigured : .unknown
      return run
    } catch {
      if let startedProcess {
        try? await adapter.stop(startedProcess, policy: workload.activeRevision.stopPolicy)
      }
      if let assignedRevision {
        await portAllocator.release(assignedRevision.ports.compactMap(\.hostPort))
      }
      try? run.finish(exitCode: nil, at: Date())
      let failed = DomainEvent(
        kind: .failed, workloadID: id, runID: run.id, message: error.localizedDescription)
      try await commit([.saveRun(run), .appendEvent(failed)], publishing: [failed])
      return run
    }
  }

  public func runOnceNow(workloadID: UUID) async throws -> Run {
    guard let workload = try await store.loadWorkload(id: workloadID) else {
      throw WorkloadServiceError.workloadNotFound(workloadID)
    }
    guard
      workload.activeRevision.executionMode == .once
        || workload.activeRevision.executionMode == .scheduled
    else {
      throw WorkloadServiceError.invalidConfiguration([
        .init(field: "executionMode", message: "Run once is not available for always-on workloads")
      ])
    }
    return try await startWorkload(id: workloadID, trigger: .manual)
  }

  public func stopWorkload(id: UUID) async throws {
    guard var workload = try await store.loadWorkload(id: id) else {
      throw WorkloadServiceError.workloadNotFound(id)
    }
    workload.desiredState = .stopped
    restartExhausted.remove(id)
    try await store.saveWorkload(workload)
    try await stopProcesses(workloadID: id, reason: .stoppedByUser)
    healthByWorkload[id] = workload.activeRevision.healthCheck == nil ? .notConfigured : .unknown
    await healthMonitor.reset(workloadID: id)
  }
  public func restartWorkload(id: UUID) async throws -> Run {
    guard try await store.loadWorkload(id: id) != nil else {
      throw WorkloadServiceError.workloadNotFound(id)
    }
    restartingWorkloads.insert(id)
    defer { restartingWorkloads.remove(id) }
    try await stopProcesses(workloadID: id, reason: .stoppedByUser)
    return try await startWorkload(id: id, trigger: .restart)
  }

  public func updateTags(workloadID: UUID, tags: [String]) async throws -> Workload {
    guard var workload = try await store.loadWorkload(id: workloadID) else {
      throw WorkloadServiceError.workloadNotFound(workloadID)
    }
    workload.tags = Array(
      Set(
        tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
          .filter { !$0.isEmpty }
      )
    ).sorted()
    workload.updatedAt = Date()
    try await store.saveWorkload(workload)
    return workload
  }
  public func saveSecret(value: String, reference: String) async throws {
    let normalized = reference.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else {
      throw WorkloadServiceError.invalidConfiguration([
        ValidationIssue(field: "secretReference", message: "Secret reference is required")
      ])
    }
    try await secretStore.write(value: value, reference: normalized)
  }

  public func workloads(tag: String) async throws -> [Workload] {
    let normalized = tag.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return [] }
    return try await allWorkloads().filter {
      $0.tags.contains { $0.caseInsensitiveCompare(normalized) == .orderedSame }
    }
  }

  public func scheduledTick(workloadID: UUID, at scheduledTime: Date = Date()) async throws -> Run?
  {
    guard let workload = try await store.loadWorkload(id: workloadID) else {
      throw WorkloadServiceError.workloadNotFound(workloadID)
    }
    guard workload.activeRevision.executionMode == .scheduled,
      let schedule = workload.activeRevision.schedule, schedule.enabled
    else {
      scheduledSlots.removeValue(forKey: workloadID)
      return nil
    }
    var calendar = Calendar.current
    calendar.locale = Locale(identifier: "en_US_POSIX")
    guard schedule.cron.matches(scheduledTime, calendar: calendar) else { return nil }
    let components = calendar.dateComponents(
      [.year, .month, .day, .hour, .minute], from: scheduledTime)
    guard let slot = calendar.date(from: components), scheduledSlots[workloadID] != slot else {
      return nil
    }
    let duplicate = try await store.listRuns(workloadID: workloadID).contains { run in
      guard run.trigger == .scheduled, let existing = run.scheduledTime else { return false }
      return calendar.dateComponents(
        [.year, .month, .day, .hour, .minute], from: existing) == components
    }
    guard !duplicate else { return nil }
    scheduledSlots[workloadID] = slot
    let issues = ConfigurationValidator.validate(
      workload: workload, existing: try await store.listWorkloads())
    let adapter = runtime(for: workload.kind)
    let availability = await adapter.checkAvailability()
    runtimeAvailability[workload.kind] = availability
    let activeRuns = (try await store.listRuns(workloadID: workloadID)).filter {
      !$0.state.isTerminal
    }.count
    let decision = Scheduler().decision(
      schedule: schedule,
      configurationIssues: issues,
      runtimeAvailability: availability,
      activeRunCount: activeRuns,
      maxConcurrentRuns: workload.activeRevision.concurrencyPolicy.maxConcurrentRuns
    )
    switch decision {
    case .none: return nil
    case .run:
      return try await startWorkload(
        id: workloadID, trigger: .scheduled, scheduledTime: scheduledTime)
    case .skipped(let reason):
      return try await recordSkippedRun(
        workload: workload, scheduledTime: scheduledTime, reason: reason)
    }
  }

  public func runDueSchedules(at date: Date = Date()) async throws {
    let workloads = try await store.listWorkloads()
    var calendar = Calendar.current
    calendar.locale = Locale(identifier: "en_US_POSIX")
    let currentMinute =
      calendar.date(
        from: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)) ?? date
    let missedEnd = currentMinute.addingTimeInterval(-0.001)

    for workload in workloads where workload.activeRevision.executionMode == .scheduled {
      guard let schedule = workload.activeRevision.schedule else { continue }
      let checkpoint = try await store.loadSchedulerCheckpoint(workloadID: workload.id)
      var mutations: [StoreMutation] = [
        .saveSchedulerCheckpoint(
          SchedulerCheckpoint(workloadID: workload.id, lastEvaluatedAt: date))
      ]
      if schedule.enabled, let previous = checkpoint?.lastEvaluatedAt,
        missedEnd.timeIntervalSince(previous) >= 60
      {
        let window = Scheduler().missedWindow(
          workloadID: workload.id, from: previous, to: missedEnd, schedule: schedule,
          calendar: calendar)
        if window.scheduledCount > 0 { mutations.append(.saveMissedWindow(window)) }
      }
      try await store.apply(mutations)
      _ = try await scheduledTick(workloadID: workload.id, at: date)
    }
  }

  public func poll(at date: Date = Date()) async throws {
    let workloadsByID = Dictionary(
      uniqueKeysWithValues: try await store.listWorkloads().map { ($0.id, $0) })
    let entries = processes.flatMap { workloadID, workloadProcesses in
      workloadProcesses.map { (workloadID, $0.key, $0.value) }
    }
    for (workloadID, runID, process) in entries {
      guard let workload = workloadsByID[workloadID] else { continue }
      let adapter = runtimeByRun[runID] ?? runtime(for: workload.kind)
      await captureLogs(workload: workload, runID: runID, process: process, adapter: adapter)
      let inspection: RuntimeInspection
      do {
        inspection = try await adapter.inspect(runtimeName: process.runtimeName)
      } catch {
        continue
      }
      guard var run = try await store.loadRun(id: runID), run.runtimeProcessID == process.id else {
        removeProcess(workloadID: workloadID, runID: runID)
        await portAllocator.release(process.hostPorts)
        logOffsets.removeValue(forKey: runID)
        continue
      }

      if inspection.state == .running {
        if let healthCheck = workload.activeRevision.healthCheck {
          let success = await adapter.checkHealth(healthCheck.kind, process: process)
          let transition = await healthMonitor.record(
            workloadID: workloadID, check: healthCheck, success: success, at: date)
          let previous = healthByWorkload[workloadID]
          healthByWorkload[workloadID] = transition.status
          if previous != transition.status {
            await emit(
              .init(
                kind: .healthChanged, workloadID: workloadID, runID: runID,
                message: transition.status.rawValue))
          }
          if transition.status == .healthy,
            await healthMonitor.isStable(
              workloadID: workloadID, for: workload.activeRevision.restartPolicy.stableFor, at: date
            )
          {
            stableWorkloads.insert(workloadID)
          }
          if workload.desiredState == .running && transition.restartEligible {
            let stable = stableWorkloads.remove(workloadID) != nil
            let chainID = stable ? UUID() : run.restartChainID
            let attempt =
              stable
              ? 0
              : ((try? await nextAttempt(workloadID: workloadID, chainID: chainID))
                ?? run.attemptIndex + 1)
            if attempt < workload.activeRevision.restartPolicy.maxRestartAttempts {
              do {
                try await stopProcess(
                  workloadID: workloadID, runID: runID, reason: .abnormalKill)
              } catch {
                continue
              }
              await emit(.init(kind: .restartScheduled, workloadID: workloadID, runID: runID))
              await restartAfterBackoff(
                workload: workload, chainID: chainID, attemptIndex: attempt)
              continue
            }
            do {
              try await stopProcess(workloadID: workloadID, runID: runID, reason: .abnormalKill)
              restartExhausted.insert(workloadID)
            } catch {
              continue
            }
            continue
          }
        } else {
          healthByWorkload[workloadID] = .notConfigured
          if workload.desiredState == .running,
            let startedTime = run.startedTime,
            date.timeIntervalSince(startedTime) >= workload.activeRevision.restartPolicy.stableFor
          {
            stableWorkloads.insert(workloadID)
          }
        }
        _ = try? await metricsCollector.collect(
          runID: run.id, process: process, adapter: adapter, now: date)
        continue
      }

      removeProcess(workloadID: workloadID, runID: runID)
      await portAllocator.release(process.hostPorts)
      logOffsets.removeValue(forKey: runID)
      try? run.finish(exitCode: inspection.exitCode, at: date)
      let eventKind: DomainEventKind = inspection.state == .orphaned ? .orphaned : .exited
      let event = DomainEvent(kind: eventKind, workloadID: workloadID, runID: run.id)
      try await commit([.saveRun(run), .appendEvent(event)], publishing: [event])
      try await enforceRetention(
        workloadID: workloadID, policy: workload.activeRevision.retentionPolicy, now: date)

      guard workload.desiredState == .running, inspection.state == .stopped else { continue }
      let stable = stableWorkloads.remove(workloadID) != nil
      let chainID = stable ? UUID() : run.restartChainID
      let attempt =
        stable
        ? 0
        : ((try? await nextAttempt(workloadID: workloadID, chainID: chainID))
          ?? run.attemptIndex + 1)
      guard attempt < workload.activeRevision.restartPolicy.maxRestartAttempts else {
        restartExhausted.insert(workloadID)
        continue
      }
      await emit(.init(kind: .restartScheduled, workloadID: workloadID, runID: run.id))
      await restartAfterBackoff(workload: workload, chainID: chainID, attemptIndex: attempt)
    }
    if lastMaintenanceAt == nil || date.timeIntervalSince(lastMaintenanceAt!) >= 60 {
      try? await performMaintenance(now: date)
      lastMaintenanceAt = date
    }
  }

  private func restartAfterBackoff(
    workload: Workload,
    chainID: UUID,
    attemptIndex: Int
  ) async {
    restartingWorkloads.insert(workload.id)
    defer { restartingWorkloads.remove(workload.id) }
    let delay = max(0, workload.activeRevision.restartPolicy.backoff)
    if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
    if Task.isCancelled { return }
    guard let current = try? await store.loadWorkload(id: workload.id),
      current.desiredState == .running
    else { return }
    _ = try? await startWorkload(
      id: workload.id,
      trigger: .restart,
      restartChainID: chainID,
      attemptIndex: attemptIndex)
  }
  private func captureLogs(
    workload: Workload,
    runID: UUID,
    process: RuntimeProcess,
    adapter: any RuntimeAdapter
  ) async {
    guard let output = try? await adapter.logs(process) else { return }
    let secrets: [String]
    if let tracked = secretValuesByRun[runID] {
      secrets = tracked
    } else {
      secrets = await secretValues(for: workload)
    }
    let previous = logOffsets[runID] ?? (stdout: 0, stderr: 0)
    let stdout = logSuffix(output.stdout, from: previous.stdout)
    let stderr = logSuffix(output.stderr, from: previous.stderr)
    if !stdout.text.isEmpty {
      try? await logs.append(runID: runID, channel: .stdout, text: stdout.text, secrets: secrets)
    }
    if !stderr.text.isEmpty {
      try? await logs.append(runID: runID, channel: .stderr, text: stderr.text, secrets: secrets)
    }
    logOffsets[runID] = (stdout.offset, stderr.offset)
  }

  private func secretValues(for workload: Workload) async -> [String] {
    var values = Set<String>()
    for variable in workload.activeRevision.environment {
      guard let reference = variable.value.secretReference,
        let value = try? await secretStore.read(reference: reference)
      else {
        continue
      }
      values.insert(value)
    }
    return Array(values)
  }
  private static func secretReferences(_ workload: Workload) -> Set<String> {
    Set(
      (workload.activeRevision.environment + workload.draftRevision.environment).compactMap {
        $0.value.secretReference
      })
  }

  private func removeUnusedSecrets(_ candidates: Set<String>) async {
    guard !candidates.isEmpty, let workloads = try? await store.listWorkloads() else { return }
    let referenced = Set(
      workloads.flatMap {
        ($0.activeRevision.environment + $0.draftRevision.environment).compactMap {
          $0.value.secretReference
        }
      })
    for reference in candidates where !referenced.contains(reference) {
      try? await secretStore.delete(reference: reference)
    }
  }

  private func logSuffix(_ text: String, from offset: Int) -> (text: String, offset: Int) {
    let bytes = Array(text.utf8)
    let start = min(max(offset, 0), bytes.count)
    return (String(decoding: bytes[start...], as: UTF8.self), bytes.count)
  }

  private func enforceRetention(
    workloadID: UUID,
    policy: RetentionPolicy,
    now: Date
  ) async throws {
    let runs = try await store.listRuns(workloadID: workloadID)
    let terminalRuns = runs.filter(\.state.isTerminal)
    let keptRunIDs = Set(terminalRuns.prefix(max(0, policy.maxRuns)).map(\.id))
    for run in terminalRuns where !keptRunIDs.contains(run.id) {
      try await logs.remove(runID: run.id)
      try await store.deleteRun(id: run.id)
    }
    let cutoff = now.addingTimeInterval(-TimeInterval(max(0, policy.logDays)) * 86_400)
    for run in terminalRuns where keptRunIDs.contains(run.id) {
      let finishedAt = run.finishedTime ?? run.startedTime ?? run.createdAt
      if let finishedAt, finishedAt < cutoff { try await logs.remove(runID: run.id) }
    }
  }

  public func performMaintenance(now: Date = Date()) async throws {
    let workloads = try await store.listWorkloads()
    for workload in workloads {
      try await enforceRetention(
        workloadID: workload.id, policy: workload.activeRevision.retentionPolicy, now: now)
    }
    var retainedRunIDs = Set<UUID>()
    for workload in workloads {
      retainedRunIDs.formUnion(try await store.listRuns(workloadID: workload.id).map(\.id))
    }
    try await logs.retain(runIDs: retainedRunIDs)
    try await store.apply([.pruneMetrics(before: now.addingTimeInterval(-86_400))])
    _ = try await garbageCollectArtifacts()
  }

  public func status(workloadID: UUID, at date: Date = Date()) async throws
    -> WorkloadStatusSnapshot
  {
    guard let workload = try await store.loadWorkload(id: workloadID) else {
      throw WorkloadServiceError.workloadNotFound(workloadID)
    }
    let all = try await store.listWorkloads()
    let issues = ConfigurationValidator.validate(workload: workload, existing: all)
    let runs = try await store.listRuns(workloadID: workloadID)
    let latest = runs.first
    let next = workload.activeRevision.schedule?.nextRun(after: date)
    let availability = runtimeAvailability[workload.kind]
    let inspection: RuntimeInspection?
    if let entry = processes[workloadID]?.first {
      let adapter = runtimeByRun[entry.key] ?? runtime(for: workload.kind)
      inspection = try? await adapter.inspect(runtimeName: entry.value.runtimeName)
    } else if let orphan = orphanedProcessesByWorkload[workloadID]?.values.first {
      inspection = RuntimeInspection(runtimeName: orphan.runtimeName, state: .orphaned)
    } else {
      inspection = nil
    }
    let health =
      healthByWorkload[workloadID]
      ?? (workload.activeRevision.healthCheck == nil ? .notConfigured : .unknown)
    let runningRevisions: Set<UUID>
    if let revisions = runningRevisionIDs[workloadID] {
      runningRevisions = Set(revisions.values)
    } else {
      runningRevisions = []
    }
    let runningRevisionDiffers =
      !(processes[workloadID]?.isEmpty ?? true)
      && !runningRevisions.isEmpty
      && !runningRevisions.contains(workload.activeRevision.id)
    let state = RuntimeStateDeriver.derive(
      workload: workload,
      latestRun: latest,
      health: health,
      inspection: inspection,
      configurationIssues: issues,
      runtimeAvailability: availability,
      updateRequiresRestart: runningRevisionDiffers,
      updateFailed: updateFailures.contains(workloadID),
      restartExhausted: restartExhausted.contains(workloadID),
      updating: updatingWorkloads.contains(workloadID),
      restarting: restartingWorkloads.contains(workloadID)
    )
    return WorkloadStatusSnapshot(
      workload: workload, runtimeState: state, health: health, latestRun: latest, nextRun: next,
      configurationIssues: issues,
      orphanedProcesses: orphanedProcesses(workloadID: workloadID))
  }

  public func setHealth(workloadID: UUID, status: HealthStatus) async throws {
    let previous = healthByWorkload[workloadID]
    healthByWorkload[workloadID] = status
    guard previous != status else { return }
    await emit(.init(kind: .healthChanged, workloadID: workloadID, message: status.rawValue))
  }

  public func quit() async {
    let workloads = (try? await store.listWorkloads()) ?? []
    let workloadsByID = Dictionary(uniqueKeysWithValues: workloads.map { ($0.id, $0) })
    var targets: [QuitTarget] = []
    for (workloadID, workloadProcesses) in processes {
      guard let workload = workloadsByID[workloadID] else { continue }
      for (runID, process) in workloadProcesses {
        targets.append(
          QuitTarget(
            workloadID: workloadID,
            runID: runID,
            process: process,
            adapter: runtimeByRun[runID] ?? runtime(for: workload.kind),
            policy: StopPolicy(
              signal: workload.activeRevision.stopPolicy.signal,
              timeout: min(30, max(0, workload.activeRevision.stopPolicy.timeout))))
        )
      }
    }

    let dispositions = await withTaskGroup(
      of: (UUID, QuitDisposition).self, returning: [UUID: QuitDisposition].self
    ) { group in
      for target in targets {
        group.addTask {
          do {
            try await target.adapter.stop(target.process, policy: target.policy)
            return (target.runID, .terminated)
          } catch {
            if let inspection = try? await target.adapter.inspect(
              runtimeName: target.process.runtimeName), inspection.state == .stopped
            {
              return (target.runID, .natural(inspection.exitCode))
            }
            do {
              try await target.adapter.forceStop(target.process)
              return (target.runID, .terminated)
            } catch {
              return (target.runID, .failed)
            }
          }
        }
      }
      var result: [UUID: QuitDisposition] = [:]
      for await (runID, disposition) in group { result[runID] = disposition }
      return result
    }

    for target in targets {
      await finalizeQuit(target: target, disposition: dispositions[target.runID] ?? .failed)
    }
  }

  private func finalizeQuit(target: QuitTarget, disposition: QuitDisposition) async {
    guard disposition != .failed,
      var run = try? await store.loadRun(id: target.runID),
      let workload = try? await store.loadWorkload(id: target.workloadID)
    else { return }
    await captureLogs(
      workload: workload, runID: target.runID, process: target.process, adapter: target.adapter)
    switch disposition {
    case .terminated:
      try? run.finish(exitCode: nil, terminationReason: .terminatedByAppQuit)
    case .natural(let exitCode):
      try? run.finish(exitCode: exitCode)
    case .failed:
      return
    }
    let event = DomainEvent(
      kind: run.state == .failed ? .failed : .exited,
      workloadID: target.workloadID,
      runID: target.runID,
      message: run.terminationReason?.rawValue)
    try? await commit([.saveRun(run), .appendEvent(event)], publishing: [event])
    try? await enforceRetention(
      workloadID: target.workloadID, policy: workload.activeRevision.retentionPolicy, now: Date())
    removeProcess(workloadID: target.workloadID, runID: target.runID)
    await portAllocator.release(target.process.hostPorts)
    logOffsets.removeValue(forKey: target.runID)
  }

  public func resumeDesiredWorkloads() async {
    await recoverRuntimeState()
  }

  public func deleteWorkload(id: UUID) async throws {
    guard let workload = try await store.loadWorkload(id: id) else {
      throw WorkloadServiceError.workloadNotFound(id)
    }
    if !(processes[id]?.isEmpty ?? true) {
      do { try await stopProcesses(workloadID: id, reason: .stoppedByUser) } catch {
        throw WorkloadServiceError.cannotDeleteRunningWorkload
      }
    }
    let runs = try await store.listRuns(workloadID: id)
    for run in runs { try await logs.remove(runID: run.id) }
    let referencedElsewhere = Set(
      try await store.listWorkloads().filter { $0.id != id }.flatMap {
        ($0.activeRevision.environment + $0.draftRevision.environment).compactMap {
          $0.value.secretReference
        }
      })
    let ownedReferences = Set(
      (workload.activeRevision.environment + workload.draftRevision.environment).compactMap {
        $0.value.secretReference
      })
    for reference in ownedReferences where !referencedElsewhere.contains(reference) {
      try await secretStore.delete(reference: reference)
    }
    restartExhausted.remove(id)
    try await store.apply([.deleteWorkload(id)])
    processes.removeValue(forKey: id)
    runningRevisionIDs.removeValue(forKey: id)
    healthByWorkload.removeValue(forKey: id)
    updateFailures.remove(id)
    await healthMonitor.reset(workloadID: id)
  }

  #if DEBUG
    public func resetForTesting() async throws {
      for workload in try await store.listWorkloads() {
        try await deleteWorkload(id: workload.id)
      }
    }
  #endif

  public func bulkStart(ids: Set<UUID>) async -> [UUID: Error] {
    var failures: [UUID: Error] = [:]
    for id in ids { do { _ = try await startWorkload(id: id) } catch { failures[id] = error } }
    return failures
  }

  public func bulkStop(ids: Set<UUID>) async -> [UUID: Error] {
    var failures: [UUID: Error] = [:]
    for id in ids { do { try await stopWorkload(id: id) } catch { failures[id] = error } }
    return failures
  }
  public func bulkRestart(ids: Set<UUID>) async -> [UUID: Error] {
    var failures: [UUID: Error] = [:]
    for id in ids {
      do { _ = try await restartWorkload(id: id) } catch { failures[id] = error }
    }
    return failures
  }

  public func bulkStart(tag: String) async throws -> [UUID: Error] {
    let ids = Set(try await workloads(tag: tag).map(\.id))
    return await bulkStart(ids: ids)
  }

  public func bulkStop(tag: String) async throws -> [UUID: Error] {
    let ids = Set(try await workloads(tag: tag).map(\.id))
    return await bulkStop(ids: ids)
  }

  public func bulkRestart(tag: String) async throws -> [UUID: Error] {
    let ids = Set(try await workloads(tag: tag).map(\.id))
    return await bulkRestart(ids: ids)
  }

  public func bulkApply(
    tag: String,
    strategy: ApplyRestartStrategy = .none
  ) async throws -> [UUID: Error] {
    let ids = Set(try await workloads(tag: tag).map(\.id))
    return await bulkApply(ids: ids, strategy: strategy)
  }

  public func bulkDelete(tag: String) async throws -> [UUID: Error] {
    let ids = Set(try await workloads(tag: tag).map(\.id))
    return await bulkDelete(ids: ids)
  }

  public func bulkApply(ids: Set<UUID>, strategy: ApplyRestartStrategy = .none) async -> [UUID:
    Error]
  {
    var failures: [UUID: Error] = [:]
    for id in ids {
      do { _ = try await applyDraft(workloadID: id, strategy: strategy) } catch {
        failures[id] = error
      }
    }
    return failures
  }

  public func bulkDelete(ids: Set<UUID>) async -> [UUID: Error] {
    var failures: [UUID: Error] = [:]
    for id in ids { do { try await deleteWorkload(id: id) } catch { failures[id] = error } }
    return failures
  }

  public func exportJSON(ids: Set<UUID>? = nil) async throws -> Data {
    let workloads = try await store.listWorkloads().filter { ids == nil || ids!.contains($0.id) }
    return try WorkloadTransfer().exportJSON(workloads)
  }

  public func importJSON(_ data: Data, conflict: ImportConflictStrategy = .skip) async throws
    -> ImportResult
  {
    let existing = try await store.listWorkloads()
    let decoded = try WorkloadTransfer().importJSON(data, into: existing, conflict: conflict)
    let replacedReferences = Set(
      existing.filter { old in decoded.imported.contains { $0.id == old.id } }.flatMap {
        Self.secretReferences($0)
      })
    var validationBase = existing
    for imported in decoded.imported {
      validationBase.removeAll { $0.id == imported.id }
      let issues =
        ConfigurationValidator.validate(workload: imported, existing: validationBase)
        + ConfigurationValidator.validate(revision: imported.activeRevision)
      guard issues.isEmpty else { throw WorkloadServiceError.invalidConfiguration(issues) }
      validationBase.append(imported)
    }

    if conflict == .overwrite {
      for imported in decoded.imported where !(processes[imported.id]?.isEmpty ?? true) {
        try await stopWorkload(id: imported.id)
      }
    }
    try await store.apply(decoded.imported.map(StoreMutation.saveWorkload))
    await removeUnusedSecrets(replacedReferences)
    var missing: [String] = []
    for reference in decoded.missingSecretReferences {
      if try await secretStore.read(reference: reference) == nil { missing.append(reference) }
    }
    return ImportResult(
      imported: decoded.imported,
      skipped: decoded.skipped,
      renamed: decoded.renamed,
      missingSecretReferences: missing)
  }

  public func saveImportedSecrets(_ values: [String: String]) async throws {
    var updates: [String: String] = [:]
    for (reference, value) in values {
      let normalized = reference.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !normalized.isEmpty else {
        throw WorkloadServiceError.invalidConfiguration([
          .init(field: "secretReference", message: "Secret reference is required")
        ])
      }
      updates[normalized] = value
    }
    var previous: [String: String?] = [:]
    do {
      for (reference, value) in updates {
        previous[reference] = try await secretStore.read(reference: reference)
        try await secretStore.write(value: value, reference: reference)
      }
    } catch {
      for (reference, value) in previous {
        if let value {
          try? await secretStore.write(value: value, reference: reference)
        } else {
          try? await secretStore.delete(reference: reference)
        }
      }
      throw error
    }
  }

  private func resolve(workload: Workload) async throws -> ResolvedArtifact {
    let expectedHash: String? =
      if case .wasm(let spec) = workload.activeRevision.spec { spec.expectedSHA256 } else { nil }
    let insecureTLS: Bool =
      if case .wasm(let spec) = workload.activeRevision.spec { spec.allowInsecureTLS } else {
        false
      }
    return try await resolver.resolve(
      source: workload.activeRevision.spec,
      updatePolicy: workload.activeRevision.artifactUpdatePolicy,
      pinnedArtifactID: workload.activeRevision.pinnedArtifactID,
      expectedHash: expectedHash,
      allowInsecureTLS: insecureTLS
    )
  }

  private func sourceString(for spec: WorkloadSpec) -> String {
    switch spec {
    case .container(let value): value.imageReference
    case .wasm(let value): value.source.rawValue
    }
  }

  private func revisionWithAssignedPorts(_ revision: WorkloadRevision) async throws
    -> WorkloadRevision
  {
    var copy = revision
    var mappings: [PortMapping] = []
    var reserved: [Int] = []
    do {
      for mapping in revision.ports {
        let port = try await portAllocator.reserve(mapping.hostPort)
        reserved.append(port)
        var assigned = mapping
        assigned.hostPort = port
        mappings.append(assigned)
      }
    } catch {
      await portAllocator.release(reserved)
      throw error
    }
    copy.ports = mappings
    return copy
  }
  private func revisionForRollingUpdate(
    _ revision: WorkloadRevision, occupiedPorts: Set<Int>
  ) async throws -> WorkloadRevision {
    var copy = revision
    var mappings: [PortMapping] = []
    var reserved: [Int] = []
    do {
      for mapping in revision.ports {
        let requested =
          mapping.hostPort.flatMap { occupiedPorts.contains($0) ? nil : $0 }
        let port = try await portAllocator.reserve(requested)
        reserved.append(port)
        var assigned = mapping
        assigned.hostPort = port
        mappings.append(assigned)
      }
    } catch {
      await portAllocator.release(reserved)
      throw error
    }
    copy.ports = mappings
    return copy
  }
  private func stopProcesses(workloadID: UUID, reason: TerminationReason) async throws {
    let runIDs = processes[workloadID].map { Array($0.keys) } ?? []
    for runID in runIDs {
      try await stopProcess(workloadID: workloadID, runID: runID, reason: reason)
    }
  }

  private func stopProcess(
    workloadID: UUID, runID: UUID? = nil, reason: TerminationReason
  ) async throws {
    let selectedRunID: UUID
    let process: RuntimeProcess
    if let runID {
      guard let candidate = processes[workloadID]?[runID] else { return }
      selectedRunID = runID
      process = candidate
    } else if let candidate = processes[workloadID]?.first {
      selectedRunID = candidate.key
      process = candidate.value
    } else {
      return
    }
    guard
      var run = try await store.listRuns(workloadID: workloadID).first(where: {
        $0.id == selectedRunID && $0.runtimeProcessID == process.id && !$0.state.isTerminal
      }),
      let workload = try await store.loadWorkload(id: workloadID)
    else {
      removeProcess(workloadID: workloadID, runID: selectedRunID)
      await portAllocator.release(process.hostPorts)
      return
    }
    let adapter = runtimeByRun[selectedRunID] ?? runtime(for: workload.kind)
    try? run.transition(to: .terminating)
    try await store.saveRun(run)
    do {
      await captureLogs(
        workload: workload, runID: selectedRunID, process: process, adapter: adapter)
      do {
        try await adapter.stop(process, policy: workload.activeRevision.stopPolicy)
      } catch {
        try await adapter.forceStop(process)
      }
      await captureLogs(
        workload: workload, runID: selectedRunID, process: process, adapter: adapter)
      try run.finish(exitCode: nil, terminationReason: reason)
      let event = DomainEvent(
        kind: .exited, workloadID: workloadID, runID: run.id, message: reason.rawValue)
      try await commit([.saveRun(run), .appendEvent(event)], publishing: [event])
      try await enforceRetention(
        workloadID: workloadID, policy: workload.activeRevision.retentionPolicy, now: Date())
      removeProcess(workloadID: workloadID, runID: selectedRunID)
      await portAllocator.release(process.hostPorts)
      logOffsets.removeValue(forKey: selectedRunID)
    } catch {
      if reason == .terminatedByAppQuit {
        try? run.transition(to: .failed)
        try? await store.saveRun(run)
      }
      throw error
    }
  }

  private func removeProcess(workloadID: UUID, runID: UUID) {
    if var workloadProcesses = processes[workloadID] {
      workloadProcesses.removeValue(forKey: runID)
      if workloadProcesses.isEmpty {
        processes.removeValue(forKey: workloadID)
      } else {
        processes[workloadID] = workloadProcesses
      }
    }
    if var revisions = runningRevisionIDs[workloadID] {
      revisions.removeValue(forKey: runID)
      if revisions.isEmpty {
        runningRevisionIDs.removeValue(forKey: workloadID)
      } else {
        runningRevisionIDs[workloadID] = revisions
      }
    }
    runtimeByRun.removeValue(forKey: runID)
    secretValuesByRun.removeValue(forKey: runID)
  }

  private func recordFailedRun(
    workload: Workload,
    trigger: RunTrigger,
    scheduledTime: Date?,
    source: String,
    error: Error
  ) async throws -> Run {
    var run = Run(
      workloadID: workload.id,
      trigger: trigger,
      scheduledTime: scheduledTime,
      resolvedSource: source)
    try run.finish(exitCode: nil, at: Date())
    let created = DomainEvent(kind: .runCreated, workloadID: workload.id, runID: run.id)
    let failed = DomainEvent(
      kind: .failed, workloadID: workload.id, runID: run.id, message: error.localizedDescription)
    try await commit(
      [.saveRun(run), .appendEvent(created), .appendEvent(failed)],
      publishing: [created, failed])
    try await enforceRetention(
      workloadID: workload.id, policy: workload.activeRevision.retentionPolicy, now: Date())
    return run
  }

  private func recordSkippedRun(workload: Workload, scheduledTime: Date, reason: String)
    async throws -> Run
  {
    var run = Run(
      workloadID: workload.id,
      trigger: .scheduled,
      scheduledTime: scheduledTime,
      resolvedSource: sourceString(for: workload.activeRevision.spec))
    try run.skip(reason: reason)
    let created = DomainEvent(kind: .runCreated, workloadID: workload.id, runID: run.id)
    let skipped = DomainEvent(
      kind: .skipped, workloadID: workload.id, runID: run.id, message: reason)
    try await commit(
      [.saveRun(run), .appendEvent(created), .appendEvent(skipped)],
      publishing: [created, skipped])
    try await enforceRetention(
      workloadID: workload.id, policy: workload.activeRevision.retentionPolicy, now: Date())
    return run
  }

  private func latestRestartChain(workloadID: UUID) async throws -> UUID? {
    try await store.listRuns(workloadID: workloadID).first(where: {
      $0.trigger == .restart || $0.trigger == .resume
    })?.restartChainID
  }

  private func nextAttempt(workloadID: UUID, chainID: UUID) async throws -> Int {
    let runs = try await store.listRuns(workloadID: workloadID)
    return
      (runs.filter { $0.trigger == .restart && $0.restartChainID == chainID }
      .map(\.attemptIndex).max() ?? -1) + 1
  }

  private func rollingUpdate(workload: Workload) async throws {
    guard let oldEntry = processes[workload.id]?.first else {
      throw WorkloadServiceError.noRunningRun
    }
    let oldRunID = oldEntry.key
    let oldProcess = oldEntry.value
    let adapter = runtime(for: workload.kind)
    let oldAdapter = runtimeByRun[oldRunID] ?? adapter
    let artifact = try await resolve(workload: workload)
    var run = Run(
      workloadID: workload.id,
      trigger: .rollingUpdate,
      resolvedArtifactID: artifact.id,
      resolvedSource: sourceString(for: workload.activeRevision.spec),
      restartChainID: UUID(),
      attemptIndex: 0
    )
    let created = DomainEvent(kind: .runCreated, workloadID: workload.id, runID: run.id)
    try await commit([.saveRun(run), .appendEvent(created)], publishing: [created])
    var assignedRevision: WorkloadRevision?
    var newProcess: RuntimeProcess?
    do {
      try run.transition(to: .starting)
      try await store.saveRun(run)
      let environment = try await environmentResolver.resolve(workload.activeRevision.environment)
      let runSecrets = await secretValues(for: workload)
      let revision = try await revisionForRollingUpdate(
        workload.activeRevision, occupiedPorts: Set(oldProcess.hostPorts))
      assignedRevision = revision
      let started = try await adapter.update(
        oldProcess: oldProcess, run: run, revision: revision, artifact: artifact,
        environment: environment)
      newProcess = started
      if let healthCheck = workload.activeRevision.healthCheck {
        try await waitForHealthy(
          workloadID: workload.id, check: healthCheck, process: started, adapter: adapter)
      }
      try await oldAdapter.stop(oldProcess, policy: workload.activeRevision.stopPolicy)
      run.attach(
        processID: started.id,
        hostPorts: started.hostPorts,
        revisionID: revision.id,
        finalURL: artifact.finalURL)
      try run.transition(to: .running)
      let startedEvent = DomainEvent(kind: .started, workloadID: workload.id, runID: run.id)
      secretValuesByRun[run.id] = runSecrets
      var mutations: [StoreMutation] = [.saveRun(run), .appendEvent(startedEvent)]
      var events = [startedEvent]
      if var oldRun = try await store.loadRun(id: oldRunID), !oldRun.state.isTerminal {
        try? oldRun.finish(exitCode: nil, terminationReason: .stoppedByUser)
        let exited = DomainEvent(kind: .exited, workloadID: workload.id, runID: oldRun.id)
        mutations += [.saveRun(oldRun), .appendEvent(exited)]
        events.append(exited)
      }
      try await commit(mutations, publishing: events)
      processes[workload.id, default: [:]][run.id] = started
      runningRevisionIDs[workload.id, default: [:]][run.id] = revision.id
      runtimeByRun[run.id] = adapter
      removeProcess(workloadID: workload.id, runID: oldRunID)
      await portAllocator.release(oldProcess.hostPorts)
      updateFailures.remove(workload.id)
    } catch {
      if let newProcess {
        try? await adapter.stop(newProcess, policy: workload.activeRevision.stopPolicy)
      }
      if let assignedRevision {
        await portAllocator.release(assignedRevision.ports.compactMap(\.hostPort))
      }
      try? run.finish(exitCode: nil, at: Date())
      let failed = DomainEvent(
        kind: .failed, workloadID: workload.id, runID: run.id, message: error.localizedDescription)
      try? await commit([.saveRun(run), .appendEvent(failed)], publishing: [failed])
      throw error
    }
  }

  private func waitForHealthy(
    workloadID: UUID,
    check: HealthCheck,
    process: RuntimeProcess,
    adapter: any RuntimeAdapter
  ) async throws {
    await healthMonitor.reset(workloadID: workloadID)
    let deadline = Date().addingTimeInterval(max(30, check.startPeriod + 20))
    while Date() < deadline {
      let success = await adapter.checkHealth(check.kind, process: process)
      let transition = await healthMonitor.record(
        workloadID: workloadID, check: check, success: success)
      if transition.status == .healthy { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw RuntimeError.timeout("rolling update health check did not become healthy")
  }

  private func commit(_ mutations: [StoreMutation], publishing events: [DomainEvent]) async throws {
    try await store.apply(mutations)
    for event in events { await eventBus.publish(event) }
  }

  private func emit(_ event: DomainEvent) async {
    try? await commit([.appendEvent(event)], publishing: [event])
  }
}

public struct CreateWorkload: Sendable {
  public let service: WorkloadService
  public init(service: WorkloadService) { self.service = service }
  public func execute(_ workload: Workload) async throws -> Workload {
    try await service.createWorkload(workload)
  }
}

public struct SaveDraft: Sendable {
  public let service: WorkloadService
  public init(service: WorkloadService) { self.service = service }
  public func execute(workloadID: UUID, revision: WorkloadRevision) async throws -> Workload {
    try await service.saveDraft(workloadID: workloadID, revision: revision)
  }
}

public struct ApplyDraft: Sendable {
  public let service: WorkloadService
  public init(service: WorkloadService) { self.service = service }
  public func execute(workloadID: UUID, strategy: ApplyRestartStrategy = .none) async throws
    -> Workload
  { try await service.applyDraft(workloadID: workloadID, strategy: strategy) }
}

public struct StartWorkload: Sendable {
  public let service: WorkloadService
  public init(service: WorkloadService) { self.service = service }
  public func execute(workloadID: UUID) async throws -> Run {
    try await service.startWorkload(id: workloadID)
  }
}

public struct StopWorkload: Sendable {
  public let service: WorkloadService
  public init(service: WorkloadService) { self.service = service }
  public func execute(workloadID: UUID) async throws {
    try await service.stopWorkload(id: workloadID)
  }
}

public struct RunOnceNow: Sendable {
  public let service: WorkloadService
  public init(service: WorkloadService) { self.service = service }
  public func execute(workloadID: UUID) async throws -> Run {
    try await service.runOnceNow(workloadID: workloadID)
  }
}
