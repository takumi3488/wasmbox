import Foundation
import Testing

@testable import wasmboxFeature

struct WasmboxFeatureTests {
  private func wasmRevision(
    source: String = "/tmp/example.wasm",
    mode: ExecutionMode = .once,
    ports: [PortMapping] = [],
    environment: [EnvironmentVariable] = []
  ) throws -> WorkloadRevision {
    if !FileManager.default.fileExists(atPath: source) {
      _ = FileManager.default.createFile(atPath: source, contents: Data())
    }
    return WorkloadRevision(
      spec: .wasm(WasmSpec(source: .localPath(source), socketPermission: !ports.isEmpty)),
      executionMode: mode,
      environment: environment,
      ports: ports
    )
  }

  private func artifact(
    source: String = "/tmp/example.wasm", id: String = String(repeating: "a", count: 64)
  ) -> ResolvedArtifact {
    ResolvedArtifact(id: id, source: source, contentHash: id, localPath: source)
  }
  private struct FailingHealthProbe: HealthProbe {
    func check(_ kind: HealthCheckKind) async -> Bool { false }
  }

  @Test func healthFailureExhaustionStopsProcessAndDerivesFailed() async throws {
    let store = InMemoryStore()
    let runtime = MockRuntimeAdapter()
    let resolver = InMemoryArtifactResolver(artifacts: ["/tmp/example.wasm": artifact()])
    let service = WorkloadService(
      store: store,
      runtime: runtime,
      resolver: resolver,
      healthMonitor: HealthMonitor(probe: FailingHealthProbe()))
    var revision = try wasmRevision(mode: .alwaysOn)
    revision.healthCheck = HealthCheck(
      kind: .http(url: "http://localhost"), failureThreshold: 1, startPeriod: 0,
      unhealthyGracePeriod: 0)
    revision.restartPolicy.maxRestartAttempts = 0
    let workload = try await service.createWorkload(name: "health-exhausted", revision: revision)
    _ = try await service.startWorkload(id: workload.id)
    try await service.poll(at: Date(timeIntervalSince1970: 100))

    let snapshot = try await service.status(workloadID: workload.id)
    #expect(snapshot.runtimeState == .failed)
    #expect(await runtime.stoppedProcesses.count == 1)
  }

  @Test func workloadKeepsDraftSeparateUntilApply() throws {
    var workload = Workload(name: "demo", activeRevision: try wasmRevision())
    var draft = workload.draftRevision
    draft.arguments = ["--verbose"]
    workload.updateDraft(draft)

    #expect(workload.hasDraftChanges)
    #expect(workload.activeRevision.arguments.isEmpty)
    #expect(workload.draftRevision.arguments == ["--verbose"])

    _ = workload.applyDraft()
    #expect(!workload.hasDraftChanges)
    #expect(workload.activeRevision.arguments == ["--verbose"])
  }

  @Test func configurationRejectsFixedPortWithConcurrency() throws {
    var revision = try wasmRevision(ports: [PortMapping(guestPort: 8080, hostPort: 18080)])
    revision.concurrencyPolicy.maxConcurrentRuns = 2
    let issues = ConfigurationValidator.validate(revision: revision)
    #expect(issues.contains { $0.message.contains("maxConcurrentRuns") })
  }

  @Test func configurationRejectsInvalidPinnedArtifactHash() throws {
    var revision = try wasmRevision()
    revision.pinnedArtifactID = "not-a-sha256"

    #expect(
      ConfigurationValidator.validate(revision: revision).contains {
        $0.field == "pinnedArtifactID"
      })
  }
  @Test func configurationRejectsDuplicateFixedPortsAcrossWorkloads() throws {
    let first = Workload(
      name: "one",
      activeRevision: try wasmRevision(ports: [PortMapping(guestPort: 80, hostPort: 18080)]))
    let second = Workload(
      name: "two",
      activeRevision: try wasmRevision(ports: [PortMapping(guestPort: 81, hostPort: 18080)]))
    let issues = ConfigurationValidator.validate(workload: second, existing: [first])
    #expect(issues.contains { $0.message.contains("18080") })
  }

  @Test func cronAcceptsOnlyFiveFieldsAndFindsNextMinute() throws {
    let cron = try CronExpression("*/15 * * * *")
    let calendar = Calendar(identifier: .gregorian)
    let date = calendar.date(
      from: DateComponents(
        timeZone: TimeZone(secondsFromGMT: 0), year: 2026, month: 8, day: 30, hour: 12, minute: 1))!
    let next = cron.next(after: date, calendar: calendar)
    #expect(next.map { calendar.component(.minute, from: $0) } == 15)
    #expect(throws: ValidationError.invalidSchedule("@daily")) { try CronExpression("@daily") }
    #expect(throws: ValidationError.invalidSchedule("* * * *")) { try CronExpression("* * * *") }
  }

  @Test func runSuccessDependsOnlyOnExitCode() throws {
    var successful = Run(workloadID: UUID(), trigger: .manual, resolvedSource: "local")
    try successful.transition(to: .starting)
    try successful.transition(to: .running)
    try successful.finish(exitCode: 0)
    #expect(successful.state == .succeeded)
    #expect(successful.isSuccessful)

    var failed = Run(workloadID: UUID(), trigger: .manual, resolvedSource: "local")
    try failed.transition(to: .starting)
    try failed.transition(to: .running)
    try failed.finish(exitCode: 1)
    #expect(failed.state == .failed)
    #expect(!failed.isSuccessful)
  }

  @Test func runtimeNameContainsBothAggregateIdentifiers() {
    let workloadID = UUID()
    let runID = UUID()
    #expect(
      Workload.runtimeName(workloadID: workloadID, runID: runID)
        == "wasmbox-\(workloadID.uuidString)-\(runID.uuidString)")
  }

  @Test func healthTrackerHonorsThresholdsAndGracePeriod() {
    var tracker = HealthTracker()
    let check = HealthCheck(
      kind: .http(url: "http://localhost"), failureThreshold: 2, successThreshold: 2,
      unhealthyGracePeriod: 5)
    let start = Date(timeIntervalSince1970: 100)
    tracker.start(at: start)
    #expect(
      tracker.record(success: false, check: check, at: start.addingTimeInterval(11)) == .unknown)
    #expect(
      tracker.record(success: false, check: check, at: start.addingTimeInterval(12)) == .unhealthy)
    #expect(!tracker.restartEligible(check: check, at: start.addingTimeInterval(16)))
    #expect(tracker.restartEligible(check: check, at: start.addingTimeInterval(17)))
    #expect(
      tracker.record(success: true, check: check, at: start.addingTimeInterval(18)) == .unhealthy)
    #expect(
      tracker.record(success: true, check: check, at: start.addingTimeInterval(19)) == .healthy)
  }

  @Test func environmentResolverReadsSecretsWithoutHostInheritance() async throws {
    let secrets = InMemorySecretStore(values: ["token": "secret-value"])
    let resolver = EnvironmentResolver(secretStore: secrets)
    let values = try await resolver.resolve([
      EnvironmentVariable(key: "PLAIN", value: .plain("explicit")),
      EnvironmentVariable(key: "TOKEN", value: .secret(reference: "token")),
    ])
    #expect(values == ["PLAIN": "explicit", "TOKEN": "secret-value"])
  }

  @Test func logStoreMasksKnownSecretsAndTailsLines() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let logs = FileLogStore(rootURL: root)
    let runID = UUID()
    try await logs.append(
      runID: runID, channel: .stdout, text: "one\npassword\ntwo\n", secrets: ["password"])
    try await logs.append(runID: runID, channel: .stderr, text: "error\n", secrets: [])
    #expect(try await logs.read(runID: runID, mode: .merged, lastLines: 2) == "two\nerror")
    #expect(try await logs.search(runID: runID, query: "password", mode: .merged).isEmpty)
    #expect(try await logs.search(runID: runID, query: "••••", mode: .stdout) == ["••••"])
  }

  @Test func exportContainsReferencesButNotSecretValues() throws {
    let workload = Workload(
      name: "secret-workload",
      activeRevision: try wasmRevision(environment: [
        EnvironmentVariable(key: "TOKEN", value: .secret(reference: "keychain-token"))
      ])
    )
    let data = try WorkloadTransfer().exportJSON([workload])
    let json = String(decoding: data, as: UTF8.self)
    #expect(json.contains("keychain-token"))
    #expect(!json.contains("secret-value"))
  }

  @Test func importDefaultsToSkipAndCanRenameCollision() throws {
    let existing = Workload(name: "demo", activeRevision: try wasmRevision())
    let data = try WorkloadTransfer().exportJSON([existing])
    let skipped = try WorkloadTransfer().importJSON(data, into: [existing])
    #expect(skipped.imported.isEmpty)
    #expect(skipped.skipped == ["demo"])
    let renamed = try WorkloadTransfer().importJSON(data, into: [existing], conflict: .rename)
    #expect(renamed.imported.first?.name == "demo (2)")
  }

  @Test func schedulerSkipsAtConcurrencyLimit() throws {
    let schedule = Schedule(cron: try CronExpression("* * * * *"))
    let decision = Scheduler().decision(
      schedule: schedule,
      configurationIssues: [],
      runtimeAvailability: .available(version: "test"),
      activeRunCount: 1,
      maxConcurrentRuns: 1
    )
    #expect(decision == .skipped(reason: "MaxConcurrentRuns"))
  }

  @Test func inMemoryStorePersistsAndDeletesAggregateData() async throws {
    let store = InMemoryStore()
    let workload = Workload(name: "persisted", activeRevision: try wasmRevision())
    try await store.saveWorkload(workload)
    #expect(try await store.loadWorkload(id: workload.id) == workload)
    let run = Run(workloadID: workload.id, trigger: .manual, resolvedSource: "/tmp/example.wasm")
    try await store.saveRun(run)
    try await store.appendEvent(
      DomainEvent(kind: .runCreated, workloadID: workload.id, runID: run.id))
    try await store.deleteWorkload(id: workload.id)
    #expect(try await store.loadWorkload(id: workload.id) == nil)
    #expect(try await store.listRuns(workloadID: workload.id).isEmpty)
    #expect(try await store.listEvents(workloadID: workload.id, runID: nil).isEmpty)
  }

  @Test func sqliteStoreRoundTripsWorkloadAndRun() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "wasmbox-\(UUID().uuidString).sqlite")
    let store = try SQLiteStore(url: url)
    let backup = url.deletingPathExtension().appendingPathExtension("sqlite.backup")
    #expect(FileManager.default.fileExists(atPath: backup.path))
    #expect(!store.isReadOnly)
    let workload = Workload(name: "sqlite", activeRevision: try wasmRevision())
    try await store.saveWorkload(workload)
    let loaded = try await store.listWorkloads()
    #expect(loaded.count == 1)
    #expect(loaded.first?.id == workload.id)
    #expect(loaded.first?.name == workload.name)
    let run = Run(workloadID: workload.id, trigger: .manual, resolvedSource: "/tmp/example.wasm")
    try await store.saveRun(run)
    let loadedRun = try await store.loadRun(id: run.id)
    #expect(loadedRun == run)
  }

  @Test func serviceDoesNotStartInvalidOrUnavailableWorkload() async throws {
    let store = InMemoryStore()
    let runtime = MockRuntimeAdapter(availability: .unavailable(reason: "missing"))
    let resolver = InMemoryArtifactResolver(artifacts: ["/tmp/example.wasm": artifact()])
    let service = WorkloadService(store: store, runtime: runtime, resolver: resolver)
    let workload = try await service.createWorkload(name: "blocked", revision: wasmRevision())
    var caught: Error?
    do { _ = try await service.startWorkload(id: workload.id) } catch { caught = error }
    #expect(caught as? WorkloadServiceError == .runtimeUnavailable("missing"))
    #expect(try await service.runs(workloadID: workload.id).isEmpty)
  }

  @Test func serviceRecordsArtifactFailureAsFailedRunWithoutRuntimeStart() async throws {
    let store = InMemoryStore()
    let runtime = MockRuntimeAdapter()
    let resolver = InMemoryArtifactResolver(error: .sourceNotFound("missing"))
    let service = WorkloadService(store: store, runtime: runtime, resolver: resolver)
    let workload = try await service.createWorkload(
      name: "artifact-failure", revision: wasmRevision())
    let run = try await service.runOnceNow(workloadID: workload.id)
    #expect(run.state == .failed)
    #expect(await runtime.startedProcesses.isEmpty)
  }

  @Test func serviceStartsRunAndPollRecordsExternalExitAndRestart() async throws {
    let store = InMemoryStore()
    let runtime = MockRuntimeAdapter()
    let resolver = InMemoryArtifactResolver(artifacts: ["/tmp/example.wasm": artifact()])
    let revision = try wasmRevision(mode: .alwaysOn)
    let service = WorkloadService(store: store, runtime: runtime, resolver: resolver)
    var workload = try await service.createWorkload(name: "always", revision: revision)
    workload.desiredState = .running
    try await store.saveWorkload(workload)
    let first = try await service.startWorkload(id: workload.id, trigger: .resume)
    await runtime.setInspection(
      RuntimeInspection(runtimeName: first.runtimeName, state: .stopped, exitCode: 1))
    try await service.poll()
    let runs = try await service.runs(workloadID: workload.id)
    #expect(runs.contains { $0.id == first.id && $0.state == .failed })
    #expect(runs.contains { $0.trigger == .restart })
    #expect(await runtime.startedProcesses.count == 2)
  }
  @Test func restartChainStopsAfterConfiguredAttempts() async throws {
    let runtime = MockRuntimeAdapter()
    let service = WorkloadService(
      store: InMemoryStore(),
      runtime: runtime,
      resolver: InMemoryArtifactResolver(artifacts: ["/tmp/example.wasm": artifact()]))
    var revision = try wasmRevision(mode: .alwaysOn)
    revision.restartPolicy.maxRestartAttempts = 1
    revision.restartPolicy.backoff = 0
    let workload = try await service.createWorkload(name: "restart-limit", revision: revision)
    let first = try await service.startWorkload(id: workload.id)
    await runtime.setInspection(
      RuntimeInspection(runtimeName: first.runtimeName, state: .stopped, exitCode: 1))

    try await service.poll()
    let restarted = try #require(
      try await service.runs(workloadID: workload.id).first(where: { $0.trigger == .restart }))
    await runtime.setInspection(
      RuntimeInspection(runtimeName: restarted.runtimeName, state: .stopped, exitCode: 1))
    try await service.poll()

    let runs = try await service.runs(workloadID: workload.id)
    #expect(runs.count == 2)
    #expect(try await service.status(workloadID: workload.id).runtimeState == .failed)
  }
  @Test func serviceStopsEveryRunTrackedByRunID() async throws {
    let store = InMemoryStore()
    let runtime = MockRuntimeAdapter()
    let resolver = InMemoryArtifactResolver(artifacts: ["/tmp/example.wasm": artifact()])
    var revision = try wasmRevision(mode: .alwaysOn, ports: [PortMapping(guestPort: 8080)])
    revision.concurrencyPolicy.maxConcurrentRuns = 2
    let service = WorkloadService(store: store, runtime: runtime, resolver: resolver)
    let workload = try await service.createWorkload(name: "parallel", revision: revision)

    _ = try await service.startWorkload(id: workload.id)
    _ = try await service.startWorkload(id: workload.id)
    try await service.stopWorkload(id: workload.id)

    #expect(await runtime.startedProcesses.count == 2)
    #expect(await runtime.stoppedProcesses.count == 2)
    #expect(try await service.runs(workloadID: workload.id).allSatisfy { $0.state == .terminated })
  }

  @Test func manualStartPersistsAlwaysOnDesiredState() async throws {
    let store = InMemoryStore()
    let runtime = MockRuntimeAdapter()
    let resolver = InMemoryArtifactResolver(artifacts: ["/tmp/example.wasm": artifact()])
    let service = WorkloadService(store: store, runtime: runtime, resolver: resolver)
    let workload = try await service.createWorkload(
      name: "manual-always", revision: wasmRevision(mode: .alwaysOn))

    _ = try await service.startWorkload(id: workload.id)

    #expect(try await service.workload(id: workload.id)?.desiredState == .running)
  }

  @Test func scheduledTickRunsOnlyOnceForOneCronMinute() async throws {
    let store = InMemoryStore()
    let runtime = MockRuntimeAdapter()
    let resolver = InMemoryArtifactResolver(artifacts: ["/tmp/example.wasm": artifact()])
    var revision = try wasmRevision(mode: .scheduled)
    revision.schedule = Schedule(cron: try CronExpression("* * * * *"))
    let service = WorkloadService(store: store, runtime: runtime, resolver: resolver)
    let workload = try await service.createWorkload(name: "scheduled", revision: revision)
    let date = Date(timeIntervalSince1970: 1_756_560_000)

    #expect(try await service.scheduledTick(workloadID: workload.id, at: date) != nil)
    #expect(try await service.scheduledTick(workloadID: workload.id, at: date) == nil)
    #expect(try await service.runs(workloadID: workload.id).count == 1)
  }
  @Test func runDueSchedulesRecordsMissedWindowWithoutReplay() async throws {
    let store = InMemoryStore()
    let service = WorkloadService(
      store: store,
      runtime: MockRuntimeAdapter(),
      resolver: InMemoryArtifactResolver(artifacts: ["/tmp/example.wasm": artifact()]))
    var revision = try wasmRevision(mode: .scheduled)
    revision.schedule = Schedule(cron: try CronExpression("* * * * *"))
    let workload = try await service.createWorkload(name: "missed-window", revision: revision)
    let firstDate = Date(timeIntervalSince1970: 1_756_560_000)
    let secondDate = firstDate.addingTimeInterval(5 * 60)

    try await service.runDueSchedules(at: firstDate)
    try await service.runDueSchedules(at: secondDate)

    let windows = try await service.missedWindows(workloadID: workload.id)
    #expect(windows.count == 1)
    #expect(windows.first?.scheduledCount == 4)
    #expect(try await service.missedWindows(workloadID: workload.id).count == 1)
  }
  @Test func skippedScheduleRunIsLatestAndEmitsCreationEvent() async throws {
    let store = InMemoryStore()
    let runtime = MockRuntimeAdapter()
    let resolver = InMemoryArtifactResolver(artifacts: ["/tmp/example.wasm": artifact()])
    var revision = try wasmRevision(mode: .scheduled)
    revision.schedule = Schedule(cron: try CronExpression("* * * * *"))
    let service = WorkloadService(store: store, runtime: runtime, resolver: resolver)
    let workload = try await service.createWorkload(name: "skipped-events", revision: revision)
    let date = Date(timeIntervalSince1970: 1_756_560_000)
    _ = try await service.startWorkload(id: workload.id)

    let skipped = try await service.scheduledTick(workloadID: workload.id, at: date)
    let events = try await service.events(workloadID: workload.id)

    #expect(skipped?.state == .skipped)
    #expect(try await service.runs(workloadID: workload.id).first?.id == skipped?.id)
    #expect(events.contains { $0.kind == .runCreated && $0.runID == skipped?.id })
    #expect(events.contains { $0.kind == .skipped && $0.runID == skipped?.id })
  }

  @Test func scheduledContainerUsesContainerRuntimeAvailability() async throws {
    let store = InMemoryStore()
    let primary = UnavailableRuntimeAdapter(kind: .wasmtime)
    let container = MockRuntimeAdapter(kind: .appleContainer)
    let resolver = InMemoryArtifactResolver(
      artifacts: ["example:latest": artifact(source: "example:latest")])
    let service = WorkloadService(
      store: store,
      runtime: primary,
      containerRuntime: container,
      resolver: resolver)
    var revision = WorkloadRevision(
      spec: .container(ContainerSpec(imageReference: "example:latest")),
      executionMode: .scheduled)
    revision.schedule = Schedule(cron: try CronExpression("* * * * *"))
    let workload = try await service.createWorkload(name: "scheduled-container", revision: revision)
    let run = try await service.scheduledTick(
      workloadID: workload.id, at: Date(timeIntervalSince1970: 1_756_560_000))

    #expect(run != nil)
    #expect(await container.startedProcesses.count == 1)
  }

  @Test func pollPersistsIncrementalMaskedRuntimeLogs() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let logs = FileLogStore(rootURL: root)
    let secrets = InMemorySecretStore(values: ["token": "secret-value"])
    let store = InMemoryStore()
    let runtime = MockRuntimeAdapter()
    let resolver = InMemoryArtifactResolver(artifacts: ["/tmp/example.wasm": artifact()])
    let revision = try wasmRevision(
      mode: .alwaysOn,
      environment: [EnvironmentVariable(key: "TOKEN", value: .secret(reference: "token"))])
    let service = WorkloadService(
      store: store, runtime: runtime, resolver: resolver, secretStore: secrets, logs: logs)
    let workload = try await service.createWorkload(name: "logs", revision: revision)
    let run = try await service.startWorkload(id: workload.id)
    await runtime.setLogs(
      RuntimeLogs(stdout: "secret-value\nfirst\n", stderr: "warning\n"),
      for: run.runtimeName)

    try await service.poll(at: run.startedTime ?? Date())
    await runtime.setLogs(
      RuntimeLogs(stdout: "secret-value\nfirst\nsecond\n", stderr: "warning\n"),
      for: run.runtimeName)
    try await service.poll(at: (run.startedTime ?? Date()).addingTimeInterval(5))

    let output = try await logs.read(runID: run.id, mode: .stdout, lastLines: 10)
    #expect(output == "••••\nfirst\nsecond")
  }

  @Test func rollingUpdateUsesTemporaryPortAndKeepsNewRunTracked() async throws {
    let store = InMemoryStore()
    let runtime = MockRuntimeAdapter()
    let resolver = InMemoryArtifactResolver(artifacts: ["/tmp/example.wasm": artifact()])
    let revision = try wasmRevision(
      mode: .alwaysOn, ports: [PortMapping(guestPort: 8080)])
    let service = WorkloadService(store: store, runtime: runtime, resolver: resolver)
    let workload = try await service.createWorkload(name: "rolling", revision: revision)
    let oldRun = try await service.startWorkload(id: workload.id)
    var draft = revision
    draft.arguments = ["v2"]
    _ = try await service.saveDraft(workloadID: workload.id, revision: draft)

    _ = try await service.applyDraft(workloadID: workload.id, strategy: .rollingUpdate)

    let started = await runtime.startedProcesses
    #expect(started.count == 2)
    #expect(started.first?.hostPorts.first != nil)
    #expect(started.last?.hostPorts != started.first?.hostPorts)
    let firstProcess = try #require(started.first)
    #expect((await runtime.updatedProcesses).map(\.id) == [firstProcess.id])
    #expect((await runtime.stoppedProcesses).map(\.id) == [firstProcess.id])
    #expect(try await service.runs(workloadID: workload.id).contains { $0.id == oldRun.id })
  }
  @Test func unsupportedRollingUpdateFallsBackToNormalRestart() async throws {
    let store = InMemoryStore()
    let runtime = MockRuntimeAdapter(supportsPortHandoff: false)
    let resolver = InMemoryArtifactResolver(artifacts: ["/tmp/example.wasm": artifact()])
    let revision = try wasmRevision(
      mode: .alwaysOn, ports: [PortMapping(guestPort: 8080)])
    let service = WorkloadService(store: store, runtime: runtime, resolver: resolver)
    let workload = try await service.createWorkload(name: "rolling-fallback", revision: revision)
    _ = try await service.startWorkload(id: workload.id)
    var draft = revision
    draft.arguments = ["v2"]
    _ = try await service.saveDraft(workloadID: workload.id, revision: draft)

    _ = try await service.applyDraft(workloadID: workload.id, strategy: .rollingUpdate)

    let saved = try await service.workload(id: workload.id)
    #expect(saved?.activeRevision.arguments == ["v2"])
    #expect(await runtime.startedProcesses.count == 2)
    #expect(await runtime.updatedProcesses.isEmpty)
    #expect(await runtime.stoppedProcesses.count == 1)
  }

  @Test func cronUsesStandardDayOfMonthOrDayOfWeekMatching() throws {
    let cron = try CronExpression("0 0 1 * 1")
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let dayOne = calendar.date(from: DateComponents(year: 2026, month: 9, day: 1))!
    let daySeven = calendar.date(from: DateComponents(year: 2026, month: 9, day: 7))!
    let dayTwo = calendar.date(from: DateComponents(year: 2026, month: 9, day: 2))!

    #expect(cron.matches(dayOne, calendar: calendar))
    #expect(cron.matches(daySeven, calendar: calendar))
    #expect(!cron.matches(dayTwo, calendar: calendar))
  }

  @Test func healthTrackerReportsStableHealthyPeriod() {
    var tracker = HealthTracker()
    let check = HealthCheck(kind: .http(url: "http://localhost"), startPeriod: 0)
    tracker.start(at: Date(timeIntervalSince1970: 100))
    tracker.record(success: true, check: check, at: Date(timeIntervalSince1970: 100))

    #expect(!tracker.isStable(for: 10, at: Date(timeIntervalSince1970: 109)))
    #expect(tracker.isStable(for: 10, at: Date(timeIntervalSince1970: 110)))
  }

  @Test func invalidWasmHTTPSourceCannotBeSaved() throws {
    let revision = WorkloadRevision(spec: .wasm(WasmSpec(source: .httpsURL("http://example.com"))))
    let workload = Workload(name: "invalid-url", activeRevision: revision)

    let issues = ConfigurationValidator.validate(revision: revision)
    #expect(issues.contains { $0.message.contains("HTTPS") })
    #expect(!ConfigurationValidator.validate(workload: workload).isEmpty)
  }

  @Test func pinnedInMemoryArtifactDoesNotRefreshMissingPin() async throws {
    let resolver = InMemoryArtifactResolver(artifacts: ["source": artifact(source: "source")])
    var caught: Error?
    do {
      _ = try await resolver.resolve(
        source: .wasm(WasmSpec(source: .localPath("source"))), updatePolicy: .pinned,
        pinnedArtifactID: String(repeating: "b", count: 64), expectedHash: nil,
        allowInsecureTLS: false)
    } catch {
      caught = error
    }

    #expect(caught as? ArtifactResolutionError == .cacheMiss(String(repeating: "b", count: 64)))
  }
  @Test func pinnedLocalArtifactRejectsTamperedCacheEntry() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let cache = ArtifactCache(rootURL: root)
    let expected = LocalArtifactResolver.sha256(Data("expected".utf8))
    _ = try await cache.store(data: Data("tampered".utf8), hash: expected)
    let resolver = LocalArtifactResolver(cache: cache)

    var caught: Error?
    do {
      _ = try await resolver.resolve(
        source: .wasm(WasmSpec(source: .localPath("unused"))), updatePolicy: .pinned,
        pinnedArtifactID: expected, expectedHash: nil, allowInsecureTLS: false)
    } catch {
      caught = error
    }

    #expect(
      caught as? ArtifactResolutionError
        == .hashMismatch(
          expected: expected, actual: LocalArtifactResolver.sha256(Data("tampered".utf8))))
  }

  @Test func containerMetricsParseJSONAndPreserveRunID() async throws {
    let executable = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString)
    try Data(
      "#!/bin/sh\nprintf '%s' '[{\"cpuPercent\":12.5,\"memoryUsage\":\"1.5MiB\"}]'\n".utf8
    ).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let runID = UUID()
    let adapter = AppleContainerRuntimeAdapter(executableURL: executable)

    let sample = try await adapter.metrics(
      RuntimeProcess(id: "process", runID: runID, runtimeName: "container"))

    #expect(sample?.runID == runID)
    #expect(sample?.cpuPercent == 12.5)
    #expect(sample?.memoryBytes == 1_572_864)
  }

  @Test func tagsSupportCaseInsensitiveBulkRestart() async throws {
    let store = InMemoryStore()
    let runtime = MockRuntimeAdapter()
    let resolver = InMemoryArtifactResolver(artifacts: ["/tmp/example.wasm": artifact()])
    let service = WorkloadService(store: store, runtime: runtime, resolver: resolver)
    let tagged = try await service.createWorkload(
      name: "tagged", tags: ["prod"], revision: try wasmRevision(mode: .alwaysOn))
    _ = try await service.createWorkload(
      name: "untagged", revision: try wasmRevision(mode: .alwaysOn))
    _ = try await service.startWorkload(id: tagged.id)
    _ = try await service.updateTags(workloadID: tagged.id, tags: [" Prod ", "prod", ""])

    #expect(try await service.workloads(tag: "PROD").map(\.id) == [tagged.id])
    let failures = try await service.bulkRestart(tag: "prod")

    #expect(failures.isEmpty)
    #expect(await runtime.startedProcesses.count == 2)
    #expect(await runtime.stoppedProcesses.count == 1)
  }

  @Test func metricAggregatesAverageCPUAndPeakMemoryPerMinute() async throws {
    let store = InMemoryStore()
    let service = WorkloadService(store: store, runtime: MockRuntimeAdapter())
    let runID = UUID()
    let minute = Date(timeIntervalSince1970: 60 * 100)
    try await store.saveMetrics(
      MetricsSample(
        runID: runID, timestamp: minute.addingTimeInterval(5), cpuPercent: 10, memoryBytes: 100)
    )
    try await store.saveMetrics(
      MetricsSample(
        runID: runID, timestamp: minute.addingTimeInterval(55), cpuPercent: 30, memoryBytes: 200)
    )

    let aggregates = try await service.metricAggregates(runID: runID)

    #expect(aggregates.count == 1)
    #expect(aggregates.first?.averageCPUPercent == 20)
    #expect(aggregates.first?.peakMemoryBytes == 200)
  }

  @Test func artifactGarbageCollectionKeepsWorkloadPinAndRemovesUnreferencedFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let cache = ArtifactCache(rootURL: root)
    let pinned = String(repeating: "a", count: 64)
    let unreferenced = String(repeating: "b", count: 64)
    _ = try await cache.store(data: Data("pinned".utf8), hash: pinned)
    _ = try await cache.store(data: Data("unreferenced".utf8), hash: unreferenced)
    let resolver = LocalArtifactResolver(cache: cache)
    let store = InMemoryStore()
    let service = WorkloadService(store: store, runtime: MockRuntimeAdapter(), resolver: resolver)
    var revision = try wasmRevision()
    revision.pinnedArtifactID = pinned
    _ = try await service.createWorkload(name: "gc", revision: revision)

    let removed = try await service.garbageCollectArtifacts()

    #expect(removed == [unreferenced])
    #expect(await cache.contains(pinned))
    #expect(!(await cache.contains(unreferenced)))
  }

  @Test func refreshAndPinStoresResolvedIDOnlyInDraft() async throws {
    let store = InMemoryStore()
    let resolver = InMemoryArtifactResolver(artifacts: ["/tmp/example.wasm": artifact()])
    let service = WorkloadService(store: store, runtime: MockRuntimeAdapter(), resolver: resolver)
    let workload = try await service.createWorkload(
      name: "pin-update", revision: wasmRevision())

    let updated = try await service.refreshAndPin(workloadID: workload.id)

    #expect(updated.activeRevision.artifactUpdatePolicy == .refreshOnStart)
    #expect(updated.activeRevision.pinnedArtifactID == nil)
    #expect(updated.draftRevision.artifactUpdatePolicy == .pinned)
    #expect(updated.draftRevision.pinnedArtifactID == String(repeating: "a", count: 64))
  }

  @Test func wasmtimeReportsUnavailableWhenConfiguredLibraryIsMissing() async {
    let adapter = WasmtimeRuntimeAdapter(libraryNames: ["/definitely/missing/libwasmtime.dylib"])
    let availability = await adapter.checkAvailability()

    #expect(availability == .unavailable(reason: "Wasmtime C API could not be loaded"))
  }
  @Test func logStoreMasksSecretsSplitAcrossAppendsAndPreservesMergedAppendOrder() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let logs = FileLogStore(rootURL: root)
    let maskedRun = UUID()
    try await logs.append(
      runID: maskedRun, channel: .stdout, text: "token=sec", secrets: ["secret"])
    try await logs.append(runID: maskedRun, channel: .stdout, text: "ret\n", secrets: ["secret"])

    let stdout = try await logs.read(runID: maskedRun, mode: .stdout)
    #expect(!stdout.contains("secret"))
    #expect(stdout.contains("token=••••"))

    let orderedRun = UUID()
    try await logs.append(runID: orderedRun, channel: .stdout, text: "one\n", secrets: [])
    try await logs.append(runID: orderedRun, channel: .stderr, text: "two\n", secrets: [])
    try await logs.append(runID: orderedRun, channel: .stdout, text: "three\n", secrets: [])
    #expect(try await logs.read(runID: orderedRun, mode: .merged) == "one\ntwo\nthree")
  }

  @Test func draftChangedFieldsNamesOnlyChangedConfiguration() throws {
    var workload = Workload(name: "diff", activeRevision: try wasmRevision())
    #expect(workload.draftChangedFields.isEmpty)
    workload.draftRevision.arguments = ["--verbose"]
    workload.draftRevision.stopPolicy.timeout = 20

    #expect(workload.draftChangedFields == ["Arguments", "Stop policy"])
  }

  @Test func containerCommandHealthCheckRunsInsideNamedContainer() async throws {
    let executable = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString)
    try Data(
      "#!/bin/sh\n[ \"$1\" = exec ] && [ \"$2\" = workload-name ] && [ \"$3\" = /bin/check ]\n".utf8
    )
    .write(to: executable)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let adapter = AppleContainerRuntimeAdapter(executableURL: executable)
    let process = RuntimeProcess(id: "id", runtimeName: "workload-name")

    #expect(await adapter.checkHealth(.command(["/bin/check"]), process: process))
  }
  @Test func quitFallsBackToForceStopAndPersistsTermination() async throws {
    let store = InMemoryStore()
    let runtime = MockRuntimeAdapter(stopError: .timeout("graceful stop timed out"))
    let resolver = InMemoryArtifactResolver(artifacts: ["/tmp/example.wasm": artifact()])
    let service = WorkloadService(store: store, runtime: runtime, resolver: resolver)
    let workload = try await service.createWorkload(
      name: "quit-fallback", revision: wasmRevision(mode: .alwaysOn))
    let run = try await service.startWorkload(id: workload.id)

    await service.quit()

    let saved = try #require(await service.runs(workloadID: workload.id).first)
    #expect(saved.id == run.id)
    #expect(saved.state == .terminated)
    #expect(saved.terminationReason == .terminatedByAppQuit)
    #expect(await runtime.stoppedProcesses.count == 1)
  }
  @Test func unusedSecretsAreDeletedOnlyAfterActiveReferenceIsRemoved() async throws {
    let store = InMemoryStore()
    let secrets = InMemorySecretStore(values: ["token": "secret-value"])
    let service = WorkloadService(
      store: store,
      runtime: MockRuntimeAdapter(),
      resolver: InMemoryArtifactResolver(artifacts: ["/tmp/example.wasm": artifact()]),
      secretStore: secrets)
    let revision = try wasmRevision(
      environment: [EnvironmentVariable(key: "TOKEN", value: .secret(reference: "token"))])
    let workload = try await service.createWorkload(name: "secret-lifecycle", revision: revision)
    var withoutSecret = workload.draftRevision
    withoutSecret.environment = []

    _ = try await service.saveDraft(workloadID: workload.id, revision: withoutSecret)
    #expect(try await secrets.read(reference: "token") == "secret-value")
    _ = try await service.applyDraft(workloadID: workload.id)
    #expect(try await secrets.read(reference: "token") == nil)
  }

  @Test func retentionKeepsNewestTerminalRunOnly() async throws {
    let runtime = MockRuntimeAdapter()
    let service = WorkloadService(
      store: InMemoryStore(),
      runtime: runtime,
      resolver: InMemoryArtifactResolver(artifacts: ["/tmp/example.wasm": artifact()]))
    var revision = try wasmRevision()
    revision.retentionPolicy.maxRuns = 1
    let workload = try await service.createWorkload(name: "retention", revision: revision)

    let first = try await service.runOnceNow(workloadID: workload.id)
    try await service.stopWorkload(id: workload.id)
    _ = try await service.runOnceNow(workloadID: workload.id)
    try await service.stopWorkload(id: workload.id)

    let runs = try await service.runs(workloadID: workload.id)
    #expect(runs.count == 1)
    #expect(runs.first?.id != first.id)
  }
  @Test func portAllocatorClaimsRecoveredPortsBeforeNewAllocation() async throws {
    let allocator = PortAllocator()
    await allocator.claim([40_000])

    let automatic = try await allocator.reserve(nil)

    #expect(automatic != 40_000)
  }
  @Test func importReturnsOnlySecretReferencesMissingFromKeychain() async throws {
    let present = EnvironmentVariable(key: "PRESENT", value: .secret(reference: "present"))
    let missing = EnvironmentVariable(key: "MISSING", value: .secret(reference: "missing"))
    let workload = Workload(
      name: "import-secrets",
      activeRevision: try wasmRevision(environment: [present, missing]))
    let data = try WorkloadTransfer().exportJSON([workload])
    let secrets = InMemorySecretStore(values: ["present": "value"])
    let service = WorkloadService(
      store: InMemoryStore(),
      runtime: MockRuntimeAdapter(),
      secretStore: secrets)

    let result = try await service.importJSON(data)

    #expect(result.missingSecretReferences == ["missing"])
  }

  @Test func pollRunsMaintenanceAndRemovesUnreferencedArtifacts() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let cache = ArtifactCache(rootURL: root)
    let pinned = String(repeating: "a", count: 64)
    let unreferenced = String(repeating: "b", count: 64)
    _ = try await cache.store(data: Data("pinned".utf8), hash: pinned)
    _ = try await cache.store(data: Data("unused".utf8), hash: unreferenced)
    var revision = try wasmRevision()
    revision.pinnedArtifactID = pinned
    let service = WorkloadService(
      store: InMemoryStore(),
      runtime: MockRuntimeAdapter(),
      resolver: LocalArtifactResolver(cache: cache))
    _ = try await service.createWorkload(name: "maintenance", revision: revision)

    try await service.poll(at: Date(timeIntervalSince1970: 10_000))

    #expect(!(await cache.contains(unreferenced)))
    #expect(await cache.contains(pinned))
  }
  @Test func recoveryExposesOrphanAndAdoptionCreatesRunEvidence() async throws {
    let runtime = MockRuntimeAdapter()
    let store = InMemoryStore()
    let service = WorkloadService(
      store: store,
      runtime: runtime,
      resolver: InMemoryArtifactResolver(artifacts: ["/tmp/example.wasm": artifact()]))
    let revision = try wasmRevision()
    let workload = try await service.createWorkload(name: "orphan", revision: revision)
    let orphan = Run(
      workloadID: workload.id, trigger: .manual, resolvedSource: "/tmp/example.wasm")
    _ = try await runtime.start(
      run: orphan,
      revision: revision,
      artifact: artifact(),
      environment: [:])

    await service.recoverRuntimeState()
    let before = try await service.status(workloadID: workload.id)
    #expect(before.runtimeState == .orphaned)
    #expect(before.orphanedProcesses.count == 1)

    try await service.adoptOrphan(workloadID: workload.id, runtimeName: orphan.runtimeName)
    let adopted = try #require(await service.runs(workloadID: workload.id).first)
    #expect(adopted.state == .running)
    #expect(adopted.runtimeProcessID != nil)
    #expect((try await service.status(workloadID: workload.id)).orphanedProcesses.isEmpty)
    #expect(
      try await service.events(workloadID: workload.id).contains {
        $0.kind == .orphaned || ($0.kind == .started && $0.message == "Adopted")
      })
  }
}
