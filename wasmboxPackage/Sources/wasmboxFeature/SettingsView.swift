import SwiftUI

public struct WorkloadSettingsView: View {
  private enum HealthEditorKind: String, CaseIterable, Hashable {
    case command
    case http
    case tcp
  }

  private enum DraftBuildError: LocalizedError {
    case invalidCron
    var errorDescription: String? { "Invalid five-field cron" }
  }

  private struct PortEditor: Identifiable {
    let id: UUID
    var guest: String
    var host: String

    init(_ port: PortMapping) {
      id = port.id
      guest = String(port.guestPort)
      host = port.hostPort.map(String.init) ?? ""
    }
  }

  private struct MountEditor: Identifiable {
    let id: UUID
    var host: String
    var guest: String
    var accessMode: AccessMode

    init(_ mount: Mount) {
      id = mount.id
      host = mount.hostPath
      guest = mount.guestPath
      accessMode = mount.accessMode
    }
  }

  private struct EnvironmentEditor: Identifiable {
    let id: UUID
    var key: String
    var plainValue: String
    var isSecret: Bool
    var reference: String
    var secretValue: String

    init(_ variable: EnvironmentVariable) {
      id = variable.id
      key = variable.key
      switch variable.value {
      case .plain(let value):
        plainValue = value
        isSecret = false
        reference = ""
        secretValue = ""
      case .secret(let value):
        plainValue = ""
        isSecret = true
        reference = value
        secretValue = ""
      }
    }
  }

  public let snapshot: WorkloadStatusSnapshot
  public let service: WorkloadService
  public let onSaved: () async -> Void
  public let onExport: () async -> Void
  @State private var sourceText: String
  @State private var entrypointText: String
  @State private var executionMode: ExecutionMode
  @State private var arguments: [String]
  @State private var artifactPolicy: ArtifactUpdatePolicy
  @State private var pinnedArtifactText: String
  @State private var expectedHashText: String
  @State private var allowInsecureTLS: Bool
  @State private var socketPermission: Bool
  @State private var ports: [PortEditor]
  @State private var mounts: [MountEditor]
  @State private var environment: [EnvironmentEditor]
  @State private var healthEnabled: Bool
  @State private var healthKind: HealthEditorKind
  @State private var healthCommandText: String
  @State private var healthURLText: String
  @State private var healthHostText: String
  @State private var healthPortText: String
  @State private var healthFailureThreshold: Int
  @State private var healthSuccessThreshold: Int
  @State private var healthStartPeriod: Double
  @State private var healthGracePeriod: Double
  @State private var cronText: String
  @State private var scheduleEnabled: Bool
  @State private var maxConcurrent: Int
  @State private var maxRestartAttempts: Int
  @State private var stableFor: Double
  @State private var backoff: Double
  @State private var retentionMaxRuns: Int
  @State private var retentionLogDays: Int
  @State private var stopSignal: StopSignal
  @State private var stopTimeout: Double
  @State private var tagsText: String
  @State private var error: String?

  public init(
    snapshot: WorkloadStatusSnapshot,
    service: WorkloadService,
    onSaved: @escaping () async -> Void = {},
    onExport: @escaping () async -> Void = {}
  ) {
    self.snapshot = snapshot
    self.service = service
    self.onSaved = onSaved
    self.onExport = onExport
    let revision = snapshot.workload.draftRevision
    let source: String
    let entrypoint: String
    let initialMounts: [Mount]
    switch revision.spec {
    case .container(let spec):
      source = spec.imageReference
      entrypoint = spec.entrypointOverride?.joined(separator: ", ") ?? ""
      initialMounts = spec.mounts
    case .wasm(let spec):
      source = spec.source.rawValue
      entrypoint = ""
      initialMounts = spec.preopens
    }
    var initialHealthKind: HealthEditorKind = revision.kind == .appleContainer ? .command : .http
    var initialCommand = ""
    var initialURL = ""
    var initialHost = "127.0.0.1"
    var initialPort = ""
    var initialFailureThreshold = 3
    var initialSuccessThreshold = 1
    var initialStartPeriod = 10.0
    var initialGracePeriod = 0.0
    if let health = revision.healthCheck {
      initialFailureThreshold = health.failureThreshold
      initialSuccessThreshold = health.successThreshold
      initialStartPeriod = health.startPeriod
      initialGracePeriod = health.unhealthyGracePeriod
      switch health.kind {
      case .command(let command):
        initialHealthKind = .command
        initialCommand = command.joined(separator: ", ")
      case .http(let url):
        initialHealthKind = .http
        initialURL = url
      case .tcp(let host, let port):
        initialHealthKind = .tcp
        initialHost = host
        initialPort = String(port)
      }
    }
    let schedule = revision.schedule
    _sourceText = State(initialValue: source)
    _entrypointText = State(initialValue: entrypoint)
    _executionMode = State(initialValue: revision.executionMode)
    _arguments = State(initialValue: revision.arguments)
    _artifactPolicy = State(initialValue: revision.artifactUpdatePolicy)
    _pinnedArtifactText = State(initialValue: revision.pinnedArtifactID ?? "")
    if case .wasm(let spec) = revision.spec {
      _expectedHashText = State(initialValue: spec.expectedSHA256 ?? "")
      _allowInsecureTLS = State(initialValue: spec.allowInsecureTLS)
      _socketPermission = State(initialValue: spec.socketPermission)
    } else {
      _expectedHashText = State(initialValue: "")
      _allowInsecureTLS = State(initialValue: false)
      _socketPermission = State(initialValue: false)
    }
    _ports = State(initialValue: revision.ports.map { PortEditor($0) })
    _mounts = State(initialValue: initialMounts.map { MountEditor($0) })
    _environment = State(initialValue: revision.environment.map { EnvironmentEditor($0) })
    _healthEnabled = State(initialValue: revision.healthCheck != nil)
    _healthKind = State(initialValue: initialHealthKind)
    _healthCommandText = State(initialValue: initialCommand)
    _healthURLText = State(initialValue: initialURL)
    _healthHostText = State(initialValue: initialHost)
    _healthPortText = State(initialValue: initialPort)
    _healthFailureThreshold = State(initialValue: initialFailureThreshold)
    _healthSuccessThreshold = State(initialValue: initialSuccessThreshold)
    _healthStartPeriod = State(initialValue: initialStartPeriod)
    _healthGracePeriod = State(initialValue: initialGracePeriod)
    _cronText = State(initialValue: schedule?.cron.expression ?? "* * * * *")
    _scheduleEnabled = State(initialValue: schedule?.enabled ?? true)
    _maxConcurrent = State(initialValue: revision.concurrencyPolicy.maxConcurrentRuns)
    _maxRestartAttempts = State(initialValue: revision.restartPolicy.maxRestartAttempts)
    _stableFor = State(initialValue: revision.restartPolicy.stableFor)
    _backoff = State(initialValue: revision.restartPolicy.backoff)
    _retentionMaxRuns = State(initialValue: revision.retentionPolicy.maxRuns)
    _retentionLogDays = State(initialValue: revision.retentionPolicy.logDays)
    _stopSignal = State(initialValue: revision.stopPolicy.signal)
    _stopTimeout = State(initialValue: revision.stopPolicy.timeout)
    _tagsText = State(initialValue: snapshot.workload.tags.joined(separator: ", "))
    _error = State(initialValue: nil)
  }

  private var availableHealthKinds: [HealthEditorKind] {
    snapshot.workload.kind == .appleContainer
      ? HealthEditorKind.allCases
      : [.http, .tcp]
  }

  private var liveIssues: [ValidationIssue] {
    do { return ConfigurationValidator.validate(revision: try makeRevision()) } catch {
      return [.init(field: "schedule", message: error.localizedDescription)]
    }
  }

  public var body: some View {
    Form {
      if service.persistenceReadOnly {
        Section("Persistence") {
          Text(service.persistenceWarning ?? "Database is read-only after migration failure")
            .foregroundStyle(.red)
        }
      }
      Section("Source") {
        TextField("Image or Wasm path / HTTPS URL", text: $sourceText)
          .accessibilityIdentifier("workload-source-edit")
        if snapshot.workload.kind == .appleContainer {
          TextField("Entrypoint override (comma-separated)", text: $entrypointText)
        }
        Picker("Artifact update", selection: $artifactPolicy) {
          Text("Pinned").tag(ArtifactUpdatePolicy.pinned)
          Text("Refresh on start").tag(ArtifactUpdatePolicy.refreshOnStart)
        }
        if artifactPolicy == .pinned {
          TextField("Pinned digest / SHA-256", text: $pinnedArtifactText)
        }
        Button("Refresh and pin current artifact") { Task { await refreshAndPin() } }
          .accessibilityIdentifier("refresh-and-pin")
        if snapshot.workload.kind == .wasmtime {
          TextField("Expected SHA-256 (optional)", text: $expectedHashText)
          Toggle("Allow insecure TLS", isOn: $allowInsecureTLS)
          if allowInsecureTLS {
            Text("TLS verification disabled for this workload.").foregroundStyle(.orange)
          }
          Toggle("Allow WASI socket access", isOn: $socketPermission)
        }
      }
      Section("Execution") {
        Picker("Execution mode", selection: $executionMode) {
          Text("Once").tag(ExecutionMode.once)
          Text("Scheduled").tag(ExecutionMode.scheduled)
          Text("Always-on").tag(ExecutionMode.alwaysOn)
        }
        if executionMode == .scheduled {
          TextField("Five-field cron", text: $cronText)
          Toggle("Schedule enabled", isOn: $scheduleEnabled)
          if (try? CronExpression(cronText)) == nil {
            Text("Invalid five-field cron").foregroundStyle(.red)
          }
        }
      }
      Section("Arguments") {
        ForEach(arguments.indices, id: \.self) { index in
          TextField("Argument \(index + 1)", text: $arguments[index])
        }
        Button("Add argument") { arguments.append("") }
      }
      Section("Environment") {
        ForEach($environment) { variable in
          VStack(alignment: .leading) {
            HStack {
              TextField("Key", text: variable.key)
              Picker("Value type", selection: variable.isSecret) {
                Text("Plain").tag(false)
                Text("Secret").tag(true)
              }.labelsHidden()
              Button("Remove", role: .destructive) {
                environment.removeAll { $0.id == variable.wrappedValue.id }
              }
            }
            if variable.wrappedValue.isSecret {
              HStack {
                TextField("Keychain reference", text: variable.reference)
                SecureField("Secret value (leave blank to keep)", text: variable.secretValue)
              }
            } else {
              TextField("Value", text: variable.plainValue)
            }
          }
        }
        Button("Add variable") {
          environment.append(
            EnvironmentEditor(
              EnvironmentVariable(key: "", value: .plain(""))))
        }
        Text("Host environment variables are never inherited.").font(.caption).foregroundStyle(
          .secondary)
      }
      Section(snapshot.workload.kind == .appleContainer ? "Container mounts" : "WASI preopens") {
        ForEach($mounts) { mount in
          HStack {
            TextField("Host path", text: mount.host)
            TextField("Guest path", text: mount.guest)
            Picker("Access", selection: mount.accessMode) {
              Text("Read-only").tag(AccessMode.readOnly)
              Text("Read-write").tag(AccessMode.readWrite)
            }.labelsHidden()
            Button("Remove", role: .destructive) {
              mounts.removeAll { $0.id == mount.wrappedValue.id }
            }
          }
        }
        Button("Add path") {
          mounts.append(MountEditor(Mount(hostPath: "", guestPath: "")))
        }
      }
      Section("Ports") {
        ForEach($ports) { port in
          HStack {
            TextField("Guest port", text: port.guest)
            TextField("Host port (blank = automatic)", text: port.host)
            Button("Remove", role: .destructive) {
              ports.removeAll { $0.id == port.wrappedValue.id }
            }
          }
        }
        Button("Add port") {
          ports.append(PortEditor(PortMapping(guestPort: 0)))
        }
        Text("Fixed host ports require max concurrent runs = 1.").font(.caption).foregroundStyle(
          .secondary)
      }
      Section("Health check") {
        Toggle("Enabled", isOn: $healthEnabled)
        if healthEnabled {
          Picker("Type", selection: $healthKind) {
            ForEach(availableHealthKinds, id: \.self) { kind in
              Text(kind.rawValue.capitalized).tag(kind)
            }
          }
          switch healthKind {
          case .command:
            TextField("Command (comma-separated argv)", text: $healthCommandText)
          case .http:
            TextField("HTTP URL", text: $healthURLText)
          case .tcp:
            TextField("TCP host", text: $healthHostText)
            TextField("TCP port", text: $healthPortText)
          }
          Stepper(
            "Failure threshold: \(healthFailureThreshold)",
            value: $healthFailureThreshold,
            in: 1...100)
          Stepper(
            "Success threshold: \(healthSuccessThreshold)",
            value: $healthSuccessThreshold,
            in: 1...100)
          Stepper(
            "Start period: \(healthStartPeriod, specifier: "%.0f") s", value: $healthStartPeriod,
            in: 0...3_600, step: 1)
          Stepper(
            "Unhealthy grace: \(healthGracePeriod, specifier: "%.0f") s",
            value: $healthGracePeriod,
            in: 0...3_600,
            step: 1)
        }
      }
      Section("Restart") {
        Stepper(
          "Max restart attempts: \(maxRestartAttempts)", value: $maxRestartAttempts, in: 0...100)
        Stepper(
          "Stable for: \(stableFor, specifier: "%.0f") s", value: $stableFor, in: 0...86_400,
          step: 1)
        Stepper("Backoff: \(backoff, specifier: "%.0f") s", value: $backoff, in: 0...3_600, step: 1)
      }
      Section("Retention") {
        Stepper("Max runs: \(retentionMaxRuns)", value: $retentionMaxRuns, in: 0...10_000)
        Stepper("Log days: \(retentionLogDays)", value: $retentionLogDays, in: 0...3_650)
      }
      Section("Stop policy") {
        Picker("Signal", selection: $stopSignal) {
          ForEach(StopSignal.allCases, id: \.self) { signal in
            Text(signal.rawValue).tag(signal)
          }
        }
        Stepper(
          "Timeout: \(stopTimeout, specifier: "%.0f") s", value: $stopTimeout, in: 0...300, step: 1)
      }
      Section("Concurrency and tags") {
        Stepper("Max concurrent runs: \(maxConcurrent)", value: $maxConcurrent, in: 1...32)
        TextField("Comma-separated tags", text: $tagsText)
          .accessibilityIdentifier("workload-tags")
      }
      if !liveIssues.isEmpty {
        Section("Validation") {
          ForEach(liveIssues) { issue in
            Text("\(issue.field): \(issue.message)").foregroundStyle(.red)
          }
        }
      }
      if let error { Text(error).foregroundStyle(.red) }
      HStack {
        Button("Save draft") { Task { await save() } }
          .disabled(!liveIssues.isEmpty)
          .accessibilityIdentifier("save-draft")
        Button("Export configuration") { Task { await onExport() } }
          .accessibilityIdentifier("export-settings")
      }
    }
    .disabled(service.persistenceReadOnly)
    .formStyle(.grouped).padding()
  }

  private func refreshAndPin() async {
    guard await save(notify: false) else { return }
    do {
      let workload = try await service.refreshAndPin(workloadID: snapshot.workload.id)
      artifactPolicy = .pinned
      pinnedArtifactText = workload.draftRevision.pinnedArtifactID ?? ""
      await onSaved()
    } catch {
      self.error = error.localizedDescription
    }
  }
  private func makeRevision() throws -> WorkloadRevision {
    var revision = snapshot.workload.draftRevision
    revision.executionMode = executionMode
    revision.arguments = arguments
    revision.artifactUpdatePolicy = artifactPolicy
    let pinned = pinnedArtifactText.trimmingCharacters(in: .whitespacesAndNewlines)
    revision.pinnedArtifactID = pinned.isEmpty ? nil : pinned
    revision.ports = ports.map {
      let guest = Int($0.guest) ?? 0
      let hostText = $0.host.trimmingCharacters(in: .whitespacesAndNewlines)
      return PortMapping(
        id: $0.id, guestPort: guest, hostPort: hostText.isEmpty ? nil : Int(hostText) ?? 0)
    }
    revision.environment = environment.map {
      EnvironmentVariable(
        id: $0.id,
        key: $0.key.trimmingCharacters(in: .whitespacesAndNewlines),
        value: $0.isSecret
          ? .secret(reference: $0.reference.trimmingCharacters(in: .whitespacesAndNewlines))
          : .plain($0.plainValue))
    }
    revision.restartPolicy = RestartPolicy(
      maxRestartAttempts: maxRestartAttempts, stableFor: stableFor, backoff: backoff)
    revision.retentionPolicy = RetentionPolicy(
      maxRuns: retentionMaxRuns, logDays: retentionLogDays)
    revision.concurrencyPolicy = ConcurrencyPolicy(maxConcurrentRuns: maxConcurrent)
    revision.stopPolicy = StopPolicy(signal: stopSignal, timeout: stopTimeout)
    let source = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
    switch revision.spec {
    case .container(var spec):
      spec.imageReference = source
      let entrypoint = entrypointText.split(separator: ",").map {
        $0.trimmingCharacters(in: .whitespacesAndNewlines)
      }.filter { !$0.isEmpty }
      spec.entrypointOverride = entrypoint.isEmpty ? nil : entrypoint
      spec.mounts = mounts.map {
        Mount(
          id: $0.id,
          hostPath: $0.host.trimmingCharacters(in: .whitespacesAndNewlines),
          guestPath: $0.guest.trimmingCharacters(in: .whitespacesAndNewlines),
          accessMode: $0.accessMode)
      }
      revision.spec = .container(spec)
    case .wasm(var spec):
      spec.source =
        source.lowercased().hasPrefix("https://")
        ? .httpsURL(source) : .localPath(source)
      spec.preopens = mounts.map {
        Mount(
          id: $0.id,
          hostPath: $0.host.trimmingCharacters(in: .whitespacesAndNewlines),
          guestPath: $0.guest.trimmingCharacters(in: .whitespacesAndNewlines),
          accessMode: $0.accessMode)
      }
      let expected = expectedHashText.trimmingCharacters(in: .whitespacesAndNewlines)
      spec.expectedSHA256 = expected.isEmpty ? nil : expected
      spec.allowInsecureTLS = allowInsecureTLS
      spec.socketPermission = socketPermission
      revision.spec = .wasm(spec)
    }
    if healthEnabled {
      let kind: HealthCheckKind
      switch healthKind {
      case .command:
        kind = .command(
          healthCommandText.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
          })
      case .http:
        kind = .http(url: healthURLText.trimmingCharacters(in: .whitespacesAndNewlines))
      case .tcp:
        kind = .tcp(
          host: healthHostText.trimmingCharacters(in: .whitespacesAndNewlines),
          port: Int(healthPortText) ?? 0)
      }
      revision.healthCheck = HealthCheck(
        kind: kind,
        failureThreshold: healthFailureThreshold,
        successThreshold: healthSuccessThreshold,
        startPeriod: healthStartPeriod,
        unhealthyGracePeriod: healthGracePeriod)
    } else {
      revision.healthCheck = nil
    }
    if executionMode == .scheduled {
      guard let cron = try? CronExpression(cronText) else { throw DraftBuildError.invalidCron }
      revision.schedule = Schedule(
        id: revision.schedule?.id ?? UUID(), cron: cron, enabled: scheduleEnabled)
    } else {
      revision.schedule = nil
    }
    return revision
  }

  private func save(notify: Bool = true) async -> Bool {
    error = nil
    do {
      let revision = try makeRevision()
      let issues = ConfigurationValidator.validate(revision: revision)
      guard issues.isEmpty else {
        error = issues.map(\.message).joined(separator: ", ")
        return false
      }
      var secretUpdates: [String: String] = [:]
      for variable in environment where variable.isSecret && !variable.secretValue.isEmpty {
        secretUpdates[variable.reference.trimmingCharacters(in: .whitespacesAndNewlines)] =
          variable.secretValue
      }
      _ = try await service.saveDraft(
        workloadID: snapshot.workload.id, revision: revision, secretUpdates: secretUpdates)
      let tags = tagsText.split(separator: ",").map {
        $0.trimmingCharacters(in: .whitespacesAndNewlines)
      }
      _ = try await service.updateTags(workloadID: snapshot.workload.id, tags: tags)
      if notify { await onSaved() }
      return true
    } catch let failure {
      error = failure.localizedDescription
      return false
    }
  }
}
