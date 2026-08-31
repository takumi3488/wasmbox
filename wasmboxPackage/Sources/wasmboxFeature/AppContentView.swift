import AppKit
import Charts
import SwiftUI
import UniformTypeIdentifiers

struct AppWorkloadRow: Identifiable, Sendable {
  let id: UUID
  let name: String
  let kind: String
  let desired: String
  let runtime: String
  let health: String
  let nextRun: String
  let ports: String

  init(snapshot: WorkloadStatusSnapshot) {
    let workload = snapshot.workload
    id = workload.id
    name = workload.name
    kind = workload.kind.displayName
    desired = workload.desiredState == .running ? "Running" : "Stopped"
    runtime = snapshot.runtimeState.rawValue
    health = snapshot.health.rawValue
    nextRun = snapshot.nextRun?.formatted(date: .omitted, time: .shortened) ?? "—"
    ports = workload.activeRevision.ports.map {
      "\($0.guestPort):\($0.hostPort.map(String.init) ?? "auto")"
    }.joined(separator: ", ")
  }
}

@MainActor
public final class WasmboxAppModel: ObservableObject {
  @Published private(set) var rows: [AppWorkloadRow] = []
  @Published private(set) var snapshots: [UUID: WorkloadStatusSnapshot] = [:]
  @Published var selectedID: UUID?
  @Published var selectedIDs: Set<UUID> = []
  @Published private(set) var loading = true
  @Published private(set) var notice: String?
  @Published private(set) var exportData: Data? = nil
  @Published private(set) var requiredSecretReferences: [String] = []

  let service: WorkloadService
  private var refreshTask: Task<Void, Never>?
  private var eventTask: Task<Void, Never>?

  public init() {
    let environment = ProcessInfo.processInfo.environment
    let containerRuntime = AppleContainerRuntimeAdapter()
    let wasmRuntime = WasmtimeRuntimeAdapter()
    var migrationWarning: String?
    if let path = environment["WASMBOX_TEST_DB_URL"],
      let store = try? SQLiteStore(url: URL(fileURLWithPath: path))
    {
      migrationWarning = store.migrationWarning
      service = WorkloadService(
        store: store, runtime: wasmRuntime, containerRuntime: containerRuntime,
        wasmRuntime: wasmRuntime, secretStore: KeychainSecretStore())
    } else if let store = try? SQLiteStore() {
      migrationWarning = store.migrationWarning
      service = WorkloadService(
        store: store, runtime: wasmRuntime, containerRuntime: containerRuntime,
        wasmRuntime: wasmRuntime, secretStore: KeychainSecretStore())
    } else {
      service = WorkloadService(
        runtime: wasmRuntime, containerRuntime: containerRuntime, wasmRuntime: wasmRuntime,
        secretStore: KeychainSecretStore())
    }
    notice = migrationWarning
    refresh()
  }

  func start() {
    guard ProcessInfo.processInfo.environment["WASMBOX_UI_TEST"] != "1" else { return }
    guard refreshTask == nil else { return }
    refreshTask = Task { [weak self] in
      guard let self else { return }
      await service.recoverRuntimeState()
      while !Task.isCancelled {
        do {
          try await service.poll()
          try await service.runDueSchedules()
        } catch {
          notice = error.localizedDescription
        }
        await refreshNow()
        try? await Task.sleep(for: .seconds(5))
      }
    }
    eventTask = Task { [weak self] in
      guard let self else { return }
      let stream = await service.eventBus.subscribe()
      for await event in stream where !Task.isCancelled {
        notice = "\(event.kind.rawValue)\(event.message.map { ": \($0)" } ?? "")"
        await refreshNow()
      }
    }
  }

  func stop() {
    refreshTask?.cancel()
    eventTask?.cancel()
    refreshTask = nil
    eventTask = nil
  }
  public func stopForApplicationTermination() -> NSApplication.TerminateReply {
    refreshTask?.cancel()
    eventTask?.cancel()
    refreshTask = nil
    eventTask = nil
    let service = service
    Task.detached {
      await service.quit()
      await MainActor.run { NSApp.reply(toApplicationShouldTerminate: true) }
    }
    return .terminateLater

  }
  func refresh() { Task { await refreshNow() } }

  func refreshNow() async {
    do {
      let workloads = try await service.allWorkloads()
      var newSnapshots: [UUID: WorkloadStatusSnapshot] = [:]
      for workload in workloads {
        if let snapshot = try? await service.status(workloadID: workload.id) {
          newSnapshots[workload.id] = snapshot
        }
      }
      let validIDs = Set(newSnapshots.keys)
      snapshots = newSnapshots
      rows = newSnapshots.values.sorted {
        $0.workload.name.localizedStandardCompare($1.workload.name) == .orderedAscending
      }.map(AppWorkloadRow.init)
      selectedIDs.formIntersection(validIDs)
      if let selectedID, !validIDs.contains(selectedID) { self.selectedID = nil }
      loading = false
    } catch {
      notice = error.localizedDescription
      loading = false
    }
  }

  func create(name: String, revision: WorkloadRevision) async -> String? {
    do {
      let workload = try await service.createWorkload(name: name, revision: revision)
      selectedID = workload.id
      notice = "Created \(name)"
      await refreshNow()
      return nil
    } catch {
      notice = error.localizedDescription
      return error.localizedDescription
    }
  }

  func startSelected() async {
    await perform("Start requested") {
      _ = try await service.startWorkload(id: try selected())
    }
  }

  func runOnceSelected() async {
    await perform("Run requested") {
      _ = try await service.runOnceNow(workloadID: try selected())
    }
  }
  func stopSelected() async {
    await perform("Stop requested") { try await service.stopWorkload(id: try selected()) }
  }

  func adoptOrphan(workloadID: UUID, runtimeName: String) async {
    await perform("Orphan adopted") {
      try await service.adoptOrphan(workloadID: workloadID, runtimeName: runtimeName)
    }
  }

  func stopOrphan(workloadID: UUID, runtimeName: String) async {
    await perform("Orphan stopped") {
      try await service.stopOrphan(workloadID: workloadID, runtimeName: runtimeName)
    }
  }
  func deleteSelected() async {
    await perform("Workload deleted") {
      let id = try selected()
      try await service.deleteWorkload(id: id)
      selectedID = nil
    }
  }

  func applySelected(strategy: ApplyRestartStrategy = .normalRestart) async {
    await perform("Draft applied") {
      _ = try await service.applyDraft(workloadID: try selected(), strategy: strategy)
    }
  }
  func discardSelected() async {
    await perform("Draft discarded") {
      _ = try await service.discardDraft(workloadID: try selected())
    }
  }
  func exportSelected() async {
    do {
      let data = try await service.exportJSON(ids: selectedID.map { [$0] })
      exportData = data
      notice = "Export ready (\(data.count) bytes)"
    } catch { notice = error.localizedDescription }
  }
  func clearExportData() { exportData = nil }
  func importJSON(from url: URL, conflict: ImportConflictStrategy) async {
    do {
      let accessing = url.startAccessingSecurityScopedResource()
      defer {
        if accessing { url.stopAccessingSecurityScopedResource() }
      }
      let data = try Data(contentsOf: url)
      let result = try await service.importJSON(data, conflict: conflict)
      requiredSecretReferences = result.missingSecretReferences
      notice =
        "Imported \(result.imported.count), skipped \(result.skipped.count), renamed \(result.renamed.count)"
      await refreshNow()
    } catch {
      notice = error.localizedDescription
    }
  }

  func saveImportedSecrets(_ values: [String: String]) async -> Bool {
    do {
      try await service.saveImportedSecrets(values)
      requiredSecretReferences = []
      notice = "Imported secrets saved"
      return true
    } catch {
      notice = error.localizedDescription
      return false
    }
  }

  func dismissImportedSecrets() { requiredSecretReferences = [] }
  func bulkStartSelected() async {
    await bulkPerform("Bulk start completed") { ids in await service.bulkStart(ids: ids) }
  }

  func bulkStopSelected() async {
    await bulkPerform("Bulk stop completed") { ids in await service.bulkStop(ids: ids) }
  }

  func bulkRestartSelected() async {
    await bulkPerform("Bulk restart completed") { ids in await service.bulkRestart(ids: ids) }
  }

  func bulkApply(ids: Set<UUID>) async {
    await bulkPerform("Bulk apply completed", ids: ids) { ids in
      await service.bulkApply(ids: ids, strategy: .normalRestart)
    }
  }

  func bulkDelete(ids: Set<UUID>) async {
    await bulkPerform("Bulk delete completed", ids: ids) { ids in
      await service.bulkDelete(ids: ids)
    }
    selectedIDs.subtract(ids)
  }

  func impactRows(tag: String) async -> [AppWorkloadRow] {
    let normalized = tag.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else {
      notice = "Tag is required"
      return []
    }
    do {
      let ids = Set(try await service.workloads(tag: normalized).map(\.id))
      return rows.filter { ids.contains($0.id) }
    } catch {
      notice = error.localizedDescription
      return []
    }
  }
  func bulkStart(tag: String) async {
    await bulkTagPerform("Bulk tag start completed", tag: tag) {
      try await service.bulkStart(tag: $0)
    }
  }

  func bulkStop(tag: String) async {
    await bulkTagPerform("Bulk tag stop completed", tag: tag) {
      try await service.bulkStop(tag: $0)
    }
  }

  func bulkRestart(tag: String) async {
    await bulkTagPerform("Bulk tag restart completed", tag: tag) {
      try await service.bulkRestart(tag: $0)
    }
  }

  private func bulkTagPerform(
    _ success: String,
    tag: String,
    operation: (String) async throws -> [UUID: Error]
  ) async {
    let normalized = tag.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else {
      notice = "Tag is required"
      return
    }
    do {
      let failures = try await operation(normalized)
      notice = failures.isEmpty ? success : "\(success): \(failures.count) failed"
      await refreshNow()
    } catch {
      notice = error.localizedDescription
    }
  }

  private func bulkPerform(
    _ success: String,
    ids: Set<UUID>? = nil,
    operation: (Set<UUID>) async -> [UUID: Error]
  ) async {
    let failures = await operation(ids ?? selectedIDs)
    notice = failures.isEmpty ? success : "\(success): \(failures.count) failed"
    await refreshNow()
  }

  private func selected() throws -> UUID {
    guard let selectedID else { throw WorkloadServiceError.noRunningRun }
    return selectedID
  }

  private func perform(_ success: String, operation: () async throws -> Void) async {
    do {
      try await operation()
      notice = success
      await refreshNow()
    } catch { notice = error.localizedDescription }
  }
}

private struct JSONFileDocument: FileDocument {
  static var readableContentTypes: [UTType] { [.json] }

  let data: Data

  init(data: Data) { self.data = data }

  init(configuration: ReadConfiguration) throws {
    data = configuration.file.regularFileContents ?? Data()
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}

private enum BulkImpactAction: String {
  case apply
  case delete

  var title: String { self == .apply ? "Apply drafts" : "Delete workloads" }
  var buttonTitle: String { self == .apply ? "Apply" : "Delete" }
}

private struct BulkImpactPlan: Identifiable {
  let id = UUID()
  let action: BulkImpactAction
  let rows: [AppWorkloadRow]
}

public struct ContentView: View {
  @StateObject private var model: WasmboxAppModel
  @State private var showCreate = false
  @State private var showDelete = false
  @State private var bulkImpact: BulkImpactPlan?
  @State private var showImport = false
  @State private var importConflict: ImportConflictStrategy = .skip
  @State private var showExport = false
  @State private var bulkTag = ""
  @State private var showImportedSecrets = false

  public init() {
    self.init(model: WasmboxAppModel())
  }

  public init(model: WasmboxAppModel) {
    _model = StateObject(wrappedValue: model)
  }
  public var body: some View {
    NavigationSplitView {
      VStack(spacing: 0) {
        if model.loading {
          ProgressView("Loading")
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .accessibilityIdentifier("loading-indicator")
        }
        Grid(alignment: .leading, horizontalSpacing: 8) {
          GridRow {
            Text("Select").bold()
            Text("Name").bold()
            Text("Kind").bold()
            Text("Desired").bold()
            Text("Runtime").bold()
            Text("Health").bold()
            Text("Next run").bold()
            Text("Ports").bold()
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.top, 8)
        List(selection: $model.selectedID) {
          ForEach(model.rows) { row in
            Grid(alignment: .leading, horizontalSpacing: 8) {
              GridRow {
                Toggle(
                  "",
                  isOn: Binding(
                    get: { model.selectedIDs.contains(row.id) },
                    set: { selected in
                      if selected {
                        model.selectedIDs.insert(row.id)
                      } else {
                        model.selectedIDs.remove(row.id)
                      }
                    })
                )
                .labelsHidden()
                .accessibilityIdentifier("select-\(row.name)")
                Text(row.name).lineLimit(1)
                Text(row.kind).lineLimit(1)
                Text(row.desired).lineLimit(1)
                Text(row.runtime).lineLimit(1)
                Text(row.health).lineLimit(1)
                Text(row.nextRun).lineLimit(1)
                Text(row.ports.isEmpty ? "No ports" : row.ports).lineLimit(1)
              }
            }
            .font(.caption)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("workload-\(row.name)")
            .accessibilityLabel(
              "\(row.name), \(row.kind), \(row.desired), \(row.runtime), \(row.health)"
            )
            .tag(row.id)
          }
        }
        .accessibilityIdentifier("workload-list")
      }
      .frame(minWidth: 400)
    } detail: {
      if let id = model.selectedID, let snapshot = model.snapshots[id] {
        DetailView(snapshot: snapshot, model: model, showDelete: $showDelete)
      } else {
        ContentUnavailableView(
          "Select a workload", systemImage: "shippingbox",
          description: Text("Create or select a workload to inspect it.")
        )
        .accessibilityIdentifier("empty-detail")
      }
    }
    .navigationTitle("wasmbox")
    .toolbar {
      ToolbarItemGroup {
        Button("New Workload", systemImage: "plus") { showCreate = true }
          .disabled(model.service.persistenceReadOnly)
          .accessibilityIdentifier("new-workload")
        Button("Refresh", systemImage: "arrow.clockwise") { model.refresh() }
          .accessibilityIdentifier("refresh-workloads")
        TextField("Bulk tag", text: $bulkTag)
          .frame(width: 120)
          .accessibilityIdentifier("bulk-tag")
        Menu("Tag bulk", systemImage: "tag") {
          Button("Start by tag") { Task { await model.bulkStart(tag: bulkTag) } }
            .accessibilityIdentifier("bulk-tag-start")
          Button("Stop by tag") { Task { await model.bulkStop(tag: bulkTag) } }
            .accessibilityIdentifier("bulk-tag-stop")
          Button("Restart by tag") { Task { await model.bulkRestart(tag: bulkTag) } }
            .accessibilityIdentifier("bulk-tag-restart")
          Button("Apply by tag") {
            Task {
              bulkImpact = BulkImpactPlan(
                action: .apply, rows: await model.impactRows(tag: bulkTag))
            }
          }
          .accessibilityIdentifier("bulk-tag-apply")
          Button("Delete by tag", role: .destructive) {
            Task {
              bulkImpact = BulkImpactPlan(
                action: .delete, rows: await model.impactRows(tag: bulkTag))
            }
          }
          .accessibilityIdentifier("bulk-tag-delete")
        }
        .disabled(model.service.persistenceReadOnly)
        Menu("Bulk", systemImage: "checklist") {
          Button("Start selected") { Task { await model.bulkStartSelected() } }
            .disabled(model.selectedIDs.isEmpty)
            .accessibilityIdentifier("bulk-start")
          Button("Stop selected") { Task { await model.bulkStopSelected() } }
            .disabled(model.selectedIDs.isEmpty)
            .accessibilityIdentifier("bulk-stop")
          Button("Restart selected") { Task { await model.bulkRestartSelected() } }
            .disabled(model.selectedIDs.isEmpty)
            .accessibilityIdentifier("bulk-restart")
          Button("Apply selected") {
            bulkImpact = BulkImpactPlan(
              action: .apply, rows: model.rows.filter { model.selectedIDs.contains($0.id) })
          }
          .disabled(model.selectedIDs.isEmpty)
          .accessibilityIdentifier("bulk-apply")
          Divider()
          Button("Delete selected", role: .destructive) {
            bulkImpact = BulkImpactPlan(
              action: .delete, rows: model.rows.filter { model.selectedIDs.contains($0.id) })
          }
          .disabled(model.selectedIDs.isEmpty)
          .accessibilityIdentifier("bulk-delete")
        }
        .disabled(model.service.persistenceReadOnly)
        Menu("Import / Export", systemImage: "arrow.up.arrow.down") {
          Button("Import (skip conflicts)") {
            importConflict = .skip
            showImport = true
          }
          .disabled(model.service.persistenceReadOnly)
          Button("Import (overwrite)") {
            importConflict = .overwrite
            showImport = true
          }
          .disabled(model.service.persistenceReadOnly)
          Button("Import (rename)") {
            importConflict = .rename
            showImport = true
          }
          .disabled(model.service.persistenceReadOnly)
          Button("Export selected") { Task { await model.exportSelected() } }
            .disabled(model.selectedID == nil)
            .accessibilityIdentifier("export-workload")
        }
      }
    }
    .sheet(isPresented: $showCreate) {
      CreateView { name, revision in
        await model.create(name: name, revision: revision)
      }
    }
    .sheet(item: $bulkImpact) { plan in
      BulkImpactView(plan: plan) { ids in
        switch plan.action {
        case .apply: await model.bulkApply(ids: ids)
        case .delete: await model.bulkDelete(ids: ids)
        }
      }
    }
    .confirmationDialog("Delete workload?", isPresented: $showDelete) {
      Button("Delete", role: .destructive) { Task { await model.deleteSelected() } }
      Button("Cancel", role: .cancel) {}
    }
    .fileImporter(
      isPresented: $showImport,
      allowedContentTypes: [.json],
      allowsMultipleSelection: false
    ) { result in
      guard case .success(let urls) = result, let url = urls.first else { return }
      Task { await model.importJSON(from: url, conflict: importConflict) }
    }
    .onChange(of: model.requiredSecretReferences) { _, references in
      showImportedSecrets = !references.isEmpty
    }
    .sheet(isPresented: $showImportedSecrets) {
      ImportSecretsView(
        references: model.requiredSecretReferences,
        save: { values in
          if await model.saveImportedSecrets(values) { showImportedSecrets = false }
        },
        cancel: {
          model.dismissImportedSecrets()
          showImportedSecrets = false
        })
    }
    .onChange(of: model.exportData) { _, data in
      showExport = data != nil
    }
    .fileExporter(
      isPresented: $showExport,
      document: JSONFileDocument(data: model.exportData ?? Data()),
      contentType: .json,
      defaultFilename: "wasmbox.json"
    ) { _ in
      model.clearExportData()
    }
    .safeAreaInset(edge: .bottom) {
      if let notice = model.notice {
        Text(notice).font(.caption).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal)
          .accessibilityIdentifier("status-message")
      }
    }
    .task { model.start() }
    .onDisappear { model.stop() }
  }
}

private struct BulkImpactView: View {
  @Environment(\.dismiss) private var dismiss
  let plan: BulkImpactPlan
  let confirm: (Set<UUID>) async -> Void
  @State private var selected: Set<UUID>

  init(plan: BulkImpactPlan, confirm: @escaping (Set<UUID>) async -> Void) {
    self.plan = plan
    self.confirm = confirm
    _selected = State(initialValue: Set(plan.rows.map(\.id)))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(plan.action.title).font(.title2).bold()
      Text("Select affected workloads.").foregroundStyle(.secondary)
      List(plan.rows) { row in
        Toggle(
          isOn: Binding(
            get: { selected.contains(row.id) },
            set: { enabled in
              if enabled { selected.insert(row.id) } else { selected.remove(row.id) }
            })
        ) {
          VStack(alignment: .leading) {
            Text(row.name)
            Text("\(row.runtime) • \(row.kind)").font(.caption).foregroundStyle(.secondary)
          }
        }
      }
      .overlay {
        if plan.rows.isEmpty {
          ContentUnavailableView("No affected workloads", systemImage: "checkmark.circle")
        }
      }
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
        Button(
          plan.action.buttonTitle,
          role: plan.action == .delete ? .destructive : nil
        ) {
          Task {
            await confirm(selected)
            dismiss()
          }
        }
        .disabled(selected.isEmpty)
      }
    }
    .padding()
    .frame(width: 480, height: 440)
  }
}

private struct ImportSecretsView: View {
  let references: [String]
  let save: ([String: String]) async -> Void
  let cancel: () -> Void
  @State private var values: [String: String]

  init(
    references: [String],
    save: @escaping ([String: String]) async -> Void,
    cancel: @escaping () -> Void
  ) {
    self.references = references
    self.save = save
    self.cancel = cancel
    _values = State(initialValue: Dictionary(uniqueKeysWithValues: references.map { ($0, "") }))
  }

  var body: some View {
    Form {
      Section("Re-enter imported secrets") {
        ForEach(references, id: \.self) { reference in
          SecureField(
            reference,
            text: Binding(
              get: { values[reference, default: ""] },
              set: { values[reference] = $0 })
          )
          .accessibilityIdentifier("import-secret-\(reference)")
        }
      }
      HStack {
        Spacer()
        Button("Cancel", action: cancel)
        Button("Save") { Task { await save(values) } }
          .keyboardShortcut(.defaultAction)
          .disabled(references.contains { values[$0, default: ""].isEmpty })
      }
    }
    .formStyle(.grouped)
    .padding()
    .frame(width: 460)
  }
}

private struct CreateView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var kind: RuntimeKind = .wasmtime
  @State private var source = ""
  @State private var mode: ExecutionMode = .once
  @State private var cron = "* * * * *"
  @State private var submissionError: String?
  let create: (String, WorkloadRevision) async -> String?

  private var revision: WorkloadRevision? {
    let normalizedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
    let spec: WorkloadSpec =
      kind == .appleContainer
      ? .container(ContainerSpec(imageReference: normalizedSource))
      : .wasm(
        WasmSpec(
          source: normalizedSource.lowercased().hasPrefix("https://")
            ? .httpsURL(normalizedSource) : .localPath(normalizedSource)))
    var revision = WorkloadRevision(spec: spec, executionMode: mode)
    if mode == .scheduled {
      guard let expression = try? CronExpression(cron) else { return nil }
      revision.schedule = Schedule(cron: expression)
    }
    return revision
  }

  private var issues: [ValidationIssue] {
    guard let revision else {
      return [.init(field: "schedule", message: "Invalid five-field cron")]
    }
    return ConfigurationValidator.validate(revision: revision)
  }

  var body: some View {
    VStack(spacing: 0) {
      Form {
        Section("Workload") {
          TextField("Name", text: $name).accessibilityIdentifier("workload-name")
          if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text("Name is required").foregroundStyle(.red)
          }
          Picker("Kind", selection: $kind) {
            Text("Container").tag(RuntimeKind.appleContainer)
            Text("Wasm").tag(RuntimeKind.wasmtime)
          }.accessibilityIdentifier("workload-kind")
          TextField(kind == .appleContainer ? "OCI image" : "Wasm path or HTTPS URL", text: $source)
            .accessibilityIdentifier("workload-source")
          Picker("Execution mode", selection: $mode) {
            Text("Once").tag(ExecutionMode.once)
            Text("Scheduled").tag(ExecutionMode.scheduled)
            Text("Always-on").tag(ExecutionMode.alwaysOn)
          }.accessibilityIdentifier("execution-mode")
          if mode == .scheduled {
            TextField("Five-field cron", text: $cron).accessibilityIdentifier("create-cron")
          }
        }
        if !issues.isEmpty {
          Section("Validation") {
            ForEach(issues) { issue in
              Text("\(issue.field): \(issue.message)").foregroundStyle(.red)
            }
          }
        }
        if let submissionError { Text(submissionError).foregroundStyle(.red) }
      }
      .formStyle(.grouped)
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
        Button("Create") {
          guard let revision else { return }
          Task {
            if let failure = await create(name, revision) {
              submissionError = failure
            } else {
              dismiss()
            }
          }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(
          name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !issues.isEmpty
        )
        .accessibilityIdentifier("create-workload")
      }
      .padding()
    }
    .frame(width: 460, height: 560)
    .navigationTitle("New Workload")
  }
}

private struct DetailView: View {
  let snapshot: WorkloadStatusSnapshot
  @ObservedObject var model: WasmboxAppModel
  @Binding var showDelete: Bool
  @State private var tab = "Summary"
  @State private var selectedRunID: UUID?
  private let tabs = ["Summary", "Runs", "Logs", "Metrics", "Events", "Settings"]

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Picker("Detail", selection: $tab) { ForEach(tabs, id: \.self) { Text($0).tag($0) } }
        .pickerStyle(.segmented).padding().accessibilityIdentifier("detail-tabs")
      switch tab {
      case "Summary": SummaryView(snapshot: snapshot, model: model, showDelete: $showDelete)
      case "Runs":
        RunsView(snapshot: snapshot, model: model, selectedRunID: $selectedRunID)
      case "Logs":
        LogsView(snapshot: snapshot, model: model, selectedRunID: $selectedRunID)
      case "Metrics":
        MetricsView(snapshot: snapshot, model: model, selectedRunID: $selectedRunID)
      case "Events":
        EventsView(snapshot: snapshot, model: model, selectedRunID: $selectedRunID)
      default: SettingsView(snapshot: snapshot, model: model)
      }
    }
  }
}

private struct SummaryView: View {
  let snapshot: WorkloadStatusSnapshot
  @ObservedObject var model: WasmboxAppModel
  @Binding var showDelete: Bool
  @State private var strategy: ApplyRestartStrategy = .normalRestart

  var body: some View {
    Form {
      Section("Status") {
        LabeledContent("Name", value: snapshot.workload.name)
        LabeledContent("Kind", value: snapshot.workload.kind.displayName)
        LabeledContent(
          "Desired state", value: snapshot.workload.desiredState == .running ? "Running" : "Stopped"
        )
        LabeledContent("Runtime state", value: snapshot.runtimeState.rawValue)
        LabeledContent("Health", value: snapshot.health.rawValue)
        LabeledContent(
          "Next run",
          value: snapshot.nextRun?.formatted(date: .abbreviated, time: .shortened) ?? "—")
        if snapshot.runtimeState == .updateRequiresRestart {
          Label("Apply requires restart", systemImage: "arrow.clockwise.circle")
            .foregroundStyle(.orange)
        } else if snapshot.runtimeState == .updateFailed {
          Label(
            "Last update failed; previous revision restored",
            systemImage: "exclamationmark.triangle"
          )
          .foregroundStyle(.red)
        }
      }
      if !snapshot.orphanedProcesses.isEmpty {
        Section("Orphaned processes") {
          ForEach(snapshot.orphanedProcesses) { process in
            HStack {
              Text(process.runtimeName).font(.caption).textSelection(.enabled)
              Spacer()
              Button("Adopt") {
                Task {
                  await model.adoptOrphan(
                    workloadID: snapshot.workload.id, runtimeName: process.runtimeName)
                }
              }
              Button("Stop", role: .destructive) {
                Task {
                  await model.stopOrphan(
                    workloadID: snapshot.workload.id, runtimeName: process.runtimeName)
                }
              }
            }
          }
        }
        .disabled(model.service.persistenceReadOnly)
      }

      Section("Draft / active") {
        LabeledContent("Draft changes", value: snapshot.workload.hasDraftChanges ? "Yes" : "No")
        if !snapshot.workload.draftChangedFields.isEmpty {
          ForEach(snapshot.workload.draftChangedFields, id: \.self) { field in
            Label(field, systemImage: "pencil")
          }
        }
        if !snapshot.configurationIssues.isEmpty {
          ForEach(snapshot.configurationIssues) {
            Text("\($0.field): \($0.message)").foregroundStyle(.red)
          }
        }
        Picker("Apply strategy", selection: $strategy) {
          Text("Normal restart").tag(ApplyRestartStrategy.normalRestart)
          Text("Rolling update").tag(ApplyRestartStrategy.rollingUpdate)
        }
        .accessibilityIdentifier("apply-strategy")
        HStack {
          Button("Apply") { Task { await model.applySelected(strategy: strategy) } }.disabled(
            !snapshot.workload.hasDraftChanges
          ).accessibilityIdentifier("apply-draft")
          Button("Discard draft") { Task { await model.discardSelected() } }.disabled(
            !snapshot.workload.hasDraftChanges
          ).accessibilityIdentifier("discard-draft")
        }
      }
      .disabled(model.service.persistenceReadOnly)
      Section("Actions") {
        HStack {
          Button("Start") { Task { await model.startSelected() } }.accessibilityIdentifier(
            "start-workload")
          Button("Run once") { Task { await model.runOnceSelected() } }.accessibilityIdentifier(
            "run-once")
          Button("Stop") { Task { await model.stopSelected() } }.accessibilityIdentifier(
            "stop-workload")
          Spacer()
          Button("Export") { Task { await model.exportSelected() } }.accessibilityIdentifier(
            "export-workload")
          Button("Delete", role: .destructive) { showDelete = true }.accessibilityIdentifier(
            "delete-workload")
        }
      }
      .disabled(model.service.persistenceReadOnly)
    }.formStyle(.grouped).padding()
  }
}

private struct RunsView: View {
  let snapshot: WorkloadStatusSnapshot
  @ObservedObject var model: WasmboxAppModel
  @Binding var selectedRunID: UUID?
  @State private var runs: [Run] = []

  var body: some View {
    VStack(spacing: 0) {
      List(runs, selection: $selectedRunID) { run in
        VStack(alignment: .leading) {
          Text(run.trigger.rawValue).bold()
          Text("\(run.state.rawValue) • \(run.runtimeName)").font(.caption).foregroundStyle(
            .secondary)
        }
        .tag(run.id)
        .accessibilityIdentifier("run-\(run.id.uuidString)")
      }
      .overlay { if runs.isEmpty { ContentUnavailableView("No runs", systemImage: "clock") } }
      if let run = runs.first(where: { $0.id == selectedRunID }) {
        RunDetailView(run: run).padding()
      }
    }
    .task(id: snapshot.latestRun) {
      let loaded = (try? await model.service.runs(workloadID: snapshot.workload.id)) ?? []
      runs = loaded
      if selectedRunID == nil || !loaded.contains(where: { $0.id == selectedRunID }) {
        selectedRunID = loaded.first?.id
      }
    }
    .accessibilityIdentifier("runs-list")
  }
}

private struct RunDetailView: View {
  let run: Run

  private var duration: String {
    guard let start = run.startedTime else { return "—" }
    return ((run.finishedTime ?? Date()).timeIntervalSince(start)).formatted(
      .number.precision(.fractionLength(1))) + " s"
  }

  var body: some View {
    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
      GridRow {
        Text("Start").foregroundStyle(.secondary)
        Text(run.startedTime?.formatted(date: .abbreviated, time: .standard) ?? "—")
        Text("End").foregroundStyle(.secondary)
        Text(run.finishedTime?.formatted(date: .abbreviated, time: .standard) ?? "—")
      }
      GridRow {
        Text("Duration").foregroundStyle(.secondary)
        Text(duration)
        Text("Exit code").foregroundStyle(.secondary)
        Text(run.exitCode.map(String.init) ?? "—")
      }
      GridRow {
        Text("Termination").foregroundStyle(.secondary)
        Text(run.terminationReason?.rawValue ?? run.skipReason ?? "—")
        Text("Restart attempt").foregroundStyle(.secondary)
        Text("\(run.attemptIndex)")
      }
    }
    .font(.caption)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

}

private struct LogScrollPosition: Equatable {
  let atTop: Bool
  let atBottom: Bool
}

private struct LogsView: View {
  let snapshot: WorkloadStatusSnapshot
  @ObservedObject var model: WasmboxAppModel
  @Binding var selectedRunID: UUID?
  @State private var mode: LogViewMode = .merged
  @State private var query = ""
  @State private var text = ""
  @State private var follow = true
  @State private var newLineCount = 0
  @State private var observedText = ""
  @State private var lineLimit = 1_000
  var body: some View {
    VStack {
      HStack {
        Picker("Stream", selection: $mode) {
          Text("Merged").tag(LogViewMode.merged)
          Text("stdout").tag(LogViewMode.stdout)
          Text("stderr").tag(LogViewMode.stderr)
        }.pickerStyle(.segmented)
        TextField("Search", text: $query)
        Toggle("Follow", isOn: $follow)
          .toggleStyle(.checkbox)
          .accessibilityIdentifier("log-follow")
        Button("Reload") { Task { await load(force: true) } }
        if newLineCount > 0 {
          Text("\(newLineCount) new lines").font(.caption).foregroundStyle(.secondary)
          Button("Back to tail") {
            follow = true
            newLineCount = 0
            Task { await load(force: true) }
          }
        }
      }.padding(.horizontal)
      ScrollViewReader { proxy in
        ScrollView {
          Text(text.isEmpty ? "No log output" : text)
            .font(.system(.body, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .padding()
            .id("log-tail")
        }
        .onScrollGeometryChange(for: LogScrollPosition.self) { geometry in
          LogScrollPosition(
            atTop: geometry.contentOffset.y <= 8,
            atBottom: geometry.contentOffset.y + geometry.containerSize.height
              >= geometry.contentSize.height - 8)
        } action: { _, position in
          if !position.atBottom { follow = false }
          if position.atTop && text.split(separator: "\n").count >= lineLimit {
            lineLimit += 1_000
            Task { await load(force: true) }
          }
        }
        .onAppear { proxy.scrollTo("log-tail", anchor: .bottom) }
        .onChange(of: text) { _, _ in
          if follow { proxy.scrollTo("log-tail", anchor: .bottom) }
        }
      }.accessibilityIdentifier("log-viewer")
    }
    .task(id: follow) {
      while !Task.isCancelled {
        await load()
        try? await Task.sleep(for: .seconds(2))
      }
    }
    .onChange(of: mode) { _, _ in Task { await load(force: true) } }
    .onChange(of: query) { _, _ in Task { await load(force: true) } }
    .onChange(of: selectedRunID) { _, _ in
      lineLimit = 1_000
      text = ""
      observedText = ""
      newLineCount = 0
      follow = true
      Task { await load(force: true) }
    }
  }
  private func load(force: Bool = false) async {
    let runs = (try? await model.service.runs(workloadID: snapshot.workload.id)) ?? []
    guard let run = runs.first(where: { $0.id == selectedRunID }) ?? runs.first else {
      return
    }
    let updated: String
    if query.isEmpty {
      updated =
        (try? await model.service.logs.read(runID: run.id, mode: mode, lastLines: lineLimit)) ?? ""
    } else {
      updated =
        ((try? await model.service.logs.search(runID: run.id, query: query, mode: mode)) ?? [])
        .joined(separator: "\n")
    }
    if observedText.isEmpty && !text.isEmpty { observedText = text }
    let previousObserved = observedText
    observedText = updated
    guard force || text.isEmpty || follow else {
      guard updated != previousObserved else { return }
      let oldCount = previousObserved.split(separator: "\n", omittingEmptySubsequences: true).count
      let newCount = updated.split(separator: "\n", omittingEmptySubsequences: true).count
      newLineCount += max(1, newCount - oldCount)
      return
    }
    text = updated
    newLineCount = 0
  }
}

private struct MetricsView: View {
  let snapshot: WorkloadStatusSnapshot
  @ObservedObject var model: WasmboxAppModel
  @Binding var selectedRunID: UUID?
  @State private var aggregates: [MetricAggregate] = []
  var body: some View {
    Group {
      if aggregates.isEmpty {
        ContentUnavailableView(
          snapshot.workload.kind == .wasmtime ? "Metrics unavailable for Wasmtime" : "No metrics",
          systemImage: "chart.xyaxis.line")
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 20) {
            GroupBox("CPU average (%)") {
              Chart(aggregates, id: \.minute) { aggregate in
                LineMark(
                  x: .value("Time", aggregate.minute),
                  y: .value("CPU", aggregate.averageCPUPercent))
              }.frame(minHeight: 180)
            }
            GroupBox("Memory peak (bytes)") {
              Chart(aggregates, id: \.minute) { aggregate in
                LineMark(
                  x: .value("Time", aggregate.minute),
                  y: .value("Memory", aggregate.peakMemoryBytes))
              }.frame(minHeight: 180)
            }
          }.padding()
        }
      }
    }
    .task(id: selectedRunID) {
      while !Task.isCancelled {
        await load()
        try? await Task.sleep(for: .seconds(5))
      }
    }
    .accessibilityIdentifier("metrics-view")
  }
  private func load() async {
    let runs = (try? await model.service.runs(workloadID: snapshot.workload.id)) ?? []
    guard let run = runs.first(where: { $0.id == selectedRunID }) ?? runs.first else {
      aggregates = []
      return
    }
    aggregates =
      (try? await model.service.metricAggregates(
        runID: run.id, since: Date().addingTimeInterval(-86_400))) ?? []
  }
}

private struct EventsView: View {
  let snapshot: WorkloadStatusSnapshot
  @ObservedObject var model: WasmboxAppModel
  @Binding var selectedRunID: UUID?
  @State private var events: [DomainEvent] = []
  var body: some View {
    List(events) { event in
      VStack(alignment: .leading) {
        Text(event.kind.rawValue).bold()
        Text(event.message ?? event.occurredAt.formatted(date: .abbreviated, time: .standard)).font(
          .caption
        ).foregroundStyle(.secondary)
      }
    }
    .overlay {
      if events.isEmpty {
        ContentUnavailableView("No events", systemImage: "list.bullet.rectangle")
      }
    }
    .task(id: selectedRunID) {
      while !Task.isCancelled {
        await load()
        try? await Task.sleep(for: .seconds(5))
      }
    }
    .accessibilityIdentifier("events-list")
  }
  private func load() async {
    let runs = (try? await model.service.runs(workloadID: snapshot.workload.id)) ?? []
    let runID = runs.first(where: { $0.id == selectedRunID })?.id ?? runs.first?.id
    events =
      (try? await model.service.events(workloadID: snapshot.workload.id, runID: runID)) ?? []
  }
}

private struct SettingsView: View {
  let snapshot: WorkloadStatusSnapshot
  @ObservedObject var model: WasmboxAppModel

  var body: some View {
    WorkloadSettingsView(
      snapshot: snapshot,
      service: model.service,
      onSaved: { await model.refreshNow() },
      onExport: { await model.exportSelected() })
  }
}
