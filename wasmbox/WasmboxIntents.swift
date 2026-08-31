import AppIntents
import Foundation
import wasmboxFeature

private actor WasmboxIntentBridge {
  static let shared = WasmboxIntentBridge()
  let service: WorkloadService

  init() {
    let environment = ProcessInfo.processInfo.environment
    let containerRuntime = AppleContainerRuntimeAdapter()
    let wasmRuntime = WasmtimeRuntimeAdapter()
    if let path = environment["WASMBOX_TEST_DB_URL"],
      let store = try? SQLiteStore(url: URL(fileURLWithPath: path))
    {
      service = WorkloadService(
        store: store, runtime: wasmRuntime, containerRuntime: containerRuntime,
        wasmRuntime: wasmRuntime, secretStore: KeychainSecretStore())
    } else if let store = try? SQLiteStore() {
      service = WorkloadService(
        store: store, runtime: wasmRuntime, containerRuntime: containerRuntime,
        wasmRuntime: wasmRuntime, secretStore: KeychainSecretStore())
    } else {
      service = WorkloadService(
        runtime: wasmRuntime, containerRuntime: containerRuntime, wasmRuntime: wasmRuntime,
        secretStore: KeychainSecretStore())
    }
  }

  func create(name: String, source: String, kind: String, mode: String) async throws -> String {
    let runtimeKind =
      kind.lowercased() == "container" ? RuntimeKind.appleContainer : RuntimeKind.wasmtime
    let execution = ExecutionMode(rawValue: mode.lowercased()) ?? .once
    let spec: WorkloadSpec =
      runtimeKind == .appleContainer
      ? .container(ContainerSpec(imageReference: source))
      : .wasm(
        WasmSpec(source: source.hasPrefix("https://") ? .httpsURL(source) : .localPath(source)))
    let workload = try await service.createWorkload(
      name: name,
      revision: WorkloadRevision(spec: spec, executionMode: execution)
    )
    return workload.id.uuidString
  }

  func names() async throws -> [String] {
    try await service.allWorkloads().map(\.name)
  }

  func status(name: String) async throws -> String {
    guard let workload = try await service.allWorkloads().first(where: { $0.name == name }) else {
      throw WorkloadServiceError.workloadNotFound(UUID())
    }
    return try await service.status(workloadID: workload.id).runtimeState.rawValue
  }

  func export() async throws -> String {
    String(decoding: try await service.exportJSON(), as: UTF8.self)
  }
}

struct CreateWorkloadIntent: AppIntent {
  static var title: LocalizedStringResource { "Create Workload" }
  static var description = IntentDescription("Create a local Container or Wasm workload.")

  @Parameter(title: "Name") var name: String
  @Parameter(title: "Source") var source: String
  @Parameter(title: "Kind") var kind: String
  @Parameter(title: "Execution mode") var mode: String

  init() {
    name = ""
    source = ""
    kind = "wasm"
    mode = "once"
  }

  func perform() async throws -> some ReturnsValue<String> {
    .result(
      value: try await WasmboxIntentBridge.shared.create(
        name: name, source: source, kind: kind, mode: mode))
  }

}

struct ListWorkloadsIntent: AppIntent {
  static var title: LocalizedStringResource { "List Workloads" }
  static var description = IntentDescription("List configured wasmbox workloads.")

  func perform() async throws -> some ReturnsValue<[String]> {
    .result(value: try await WasmboxIntentBridge.shared.names())
  }
}

struct WorkloadStatusIntent: AppIntent {
  static var title: LocalizedStringResource { "Get Workload Status" }
  static var description = IntentDescription("Read the derived runtime status of a workload.")

  @Parameter(title: "Name") var name: String

  init() { name = "" }

  func perform() async throws -> some ReturnsValue<String> {
    .result(value: try await WasmboxIntentBridge.shared.status(name: name))
  }

}

struct ExportWorkloadsIntent: AppIntent {
  static var title: LocalizedStringResource { "Export Workloads" }
  static var description = IntentDescription(
    "Export workload configuration without secrets, runs, logs, or metrics.")

  func perform() async throws -> some ReturnsValue<String> {
    .result(value: try await WasmboxIntentBridge.shared.export())
  }
}
