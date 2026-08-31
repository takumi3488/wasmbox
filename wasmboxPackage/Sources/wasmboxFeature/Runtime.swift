import Darwin
import Foundation
import Network
import WasmtimeShim

private final class ProcessCompletion: @unchecked Sendable {
  private let process: Process
  private let output: Pipe
  private let timeoutMessage: String
  private let lock = NSLock()
  private var continuation: CheckedContinuation<String, Error>?
  private var failure: Error?
  private var finished = false

  init(process: Process, output: Pipe, timeoutMessage: String) {
    self.process = process
    self.output = output
    self.timeoutMessage = timeoutMessage
  }

  func start(_ continuation: CheckedContinuation<String, Error>, timeout: TimeInterval?) {
    lock.lock()
    self.continuation = continuation
    lock.unlock()
    process.terminationHandler = { [weak self] _ in self?.finish() }
    DispatchQueue.global(qos: .utility).async { [weak self] in
      guard let self else { return }
      process.waitUntilExit()
      self.finish()
    }
    if let timeout, timeout.isFinite {
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0, timeout)) {
        [weak self] in self?.timeout()
      }
    }
  }

  func cancel() {
    lock.lock()
    if failure == nil { failure = CancellationError() }
    lock.unlock()
    terminate()
  }

  private func timeout() {
    lock.lock()
    guard !finished else {
      lock.unlock()
      return
    }
    failure = RuntimeError.timeout(timeoutMessage)
    lock.unlock()
    terminate()
  }

  private func terminate() {
    guard process.isRunning else { return }
    process.terminate()
    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
  }

  private func finish() {
    lock.lock()
    guard !finished else {
      lock.unlock()
      return
    }
    finished = true
    let continuation = self.continuation
    self.continuation = nil
    let failure = self.failure
    lock.unlock()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    if let failure {
      continuation?.resume(throwing: failure)
    } else if process.terminationStatus == 0 {
      continuation?.resume(returning: String(data: data, encoding: .utf8) ?? "")
    } else {
      continuation?.resume(
        throwing: RuntimeError.unknown(
          String(data: data, encoding: .utf8) ?? "container command failed"))
    }
  }
}

public protocol RuntimeAdapter: Sendable {
  var kind: RuntimeKind { get }
  var supportsPortHandoff: Bool { get }
  func checkAvailability() async -> RuntimeAvailability
  func start(
    run: Run,
    revision: WorkloadRevision,
    artifact: ResolvedArtifact,
    environment: [String: String]
  ) async throws -> RuntimeProcess
  func stop(_ process: RuntimeProcess, policy: StopPolicy) async throws
  func inspect(runtimeName: String) async throws -> RuntimeInspection
  func logs(_ process: RuntimeProcess) async throws -> RuntimeLogs
  func metrics(_ process: RuntimeProcess) async throws -> MetricsSample?
  func checkHealth(_ kind: HealthCheckKind, process: RuntimeProcess) async -> Bool
  func update(
    oldProcess: RuntimeProcess,
    run: Run,
    revision: WorkloadRevision,
    artifact: ResolvedArtifact,
    environment: [String: String]
  ) async throws -> RuntimeProcess
  func listManagedProcesses() async throws -> [RuntimeProcess]
  func forceStop(_ process: RuntimeProcess) async throws
}
extension RuntimeAdapter {
  public var supportsPortHandoff: Bool { false }
  public func checkHealth(_ kind: HealthCheckKind, process: RuntimeProcess) async -> Bool {
    await DefaultHealthProbe().check(kind)
  }
  public func listManagedProcesses() async throws -> [RuntimeProcess] { [] }
  public func forceStop(_ process: RuntimeProcess) async throws {
    try await stop(process, policy: StopPolicy(timeout: 0))
  }
}

public struct RuntimeLogs: Codable, Hashable, Sendable {
  public let stdout: String
  public let stderr: String

  public init(stdout: String = "", stderr: String = "") {
    self.stdout = stdout
    self.stderr = stderr
  }
}

public struct UnavailableRuntimeAdapter: RuntimeAdapter {
  public let kind: RuntimeKind
  public let reason: String

  public init(kind: RuntimeKind, reason: String? = nil) {
    self.kind = kind
    self.reason = reason ?? "Runtime is not installed or connected"
  }

  public func checkAvailability() async -> RuntimeAvailability { .unavailable(reason: reason) }

  public func start(
    run: Run,
    revision: WorkloadRevision,
    artifact: ResolvedArtifact,
    environment: [String: String]
  ) async throws -> RuntimeProcess {
    throw RuntimeError.unavailable(reason)
  }

  public func stop(_ process: RuntimeProcess, policy: StopPolicy) async throws {
    throw RuntimeError.unavailable(reason)
  }

  public func inspect(runtimeName: String) async throws -> RuntimeInspection {
    throw RuntimeError.unavailable(reason)
  }

  public func logs(_ process: RuntimeProcess) async throws -> RuntimeLogs {
    throw RuntimeError.unavailable(reason)
  }

  public func metrics(_ process: RuntimeProcess) async throws -> MetricsSample? {
    throw RuntimeError.unavailable(reason)
  }

  public func update(
    oldProcess: RuntimeProcess,
    run: Run,
    revision: WorkloadRevision,
    artifact: ResolvedArtifact,
    environment: [String: String]
  ) async throws -> RuntimeProcess {
    throw RuntimeError.unavailable(reason)
  }
}

public actor MockRuntimeAdapter: RuntimeAdapter {
  public let kind: RuntimeKind
  public let supportsPortHandoff: Bool
  public var availability: RuntimeAvailability
  public var startError: RuntimeError?
  public var stopError: RuntimeError?
  public var forceStopError: RuntimeError?
  public var updateError: RuntimeError?
  public private(set) var startedProcesses: [RuntimeProcess] = []
  public private(set) var stoppedProcesses: [RuntimeProcess] = []
  public private(set) var updatedProcesses: [RuntimeProcess] = []
  public private(set) var inspectCount = 0
  private var states: [String: RuntimeInspection]
  private var logsByProcess: [String: RuntimeLogs]
  private var metricsByProcess: [String: MetricsSample?]

  public init(
    kind: RuntimeKind = .wasmtime,
    availability: RuntimeAvailability = .available(version: "test"),
    startError: RuntimeError? = nil,
    stopError: RuntimeError? = nil,
    updateError: RuntimeError? = nil,
    forceStopError: RuntimeError? = nil,
    supportsPortHandoff: Bool = true
  ) {
    self.kind = kind
    self.supportsPortHandoff = supportsPortHandoff
    self.availability = availability
    self.startError = startError
    self.stopError = stopError
    self.updateError = updateError
    self.forceStopError = forceStopError
    self.states = [:]
    self.logsByProcess = [:]
    self.metricsByProcess = [:]
  }

  public func checkAvailability() async -> RuntimeAvailability { availability }

  public func start(
    run: Run,
    revision: WorkloadRevision,
    artifact: ResolvedArtifact,
    environment: [String: String]
  ) async throws -> RuntimeProcess {
    if let startError { throw startError }
    let process = RuntimeProcess(
      id: UUID().uuidString, runID: run.id, runtimeName: run.runtimeName,
      hostPorts: revision.ports.compactMap(\.hostPort))
    startedProcesses.append(process)
    states[process.runtimeName] = RuntimeInspection(
      runtimeName: process.runtimeName, state: .running)
    return process
  }

  public func stop(_ process: RuntimeProcess, policy: StopPolicy) async throws {
    if let stopError { throw stopError }
    stoppedProcesses.append(process)
    states[process.runtimeName] = RuntimeInspection(
      runtimeName: process.runtimeName, state: .stopped, exitCode: 143)
  }

  public func inspect(runtimeName: String) async throws -> RuntimeInspection {
    inspectCount += 1
    return states[runtimeName] ?? RuntimeInspection(runtimeName: runtimeName, state: .stopped)
  }

  public func logs(_ process: RuntimeProcess) async throws -> RuntimeLogs {
    logsByProcess[process.runtimeName] ?? RuntimeLogs()
  }

  public func metrics(_ process: RuntimeProcess) async throws -> MetricsSample? {
    metricsByProcess[process.runtimeName] ?? nil
  }

  public func update(
    oldProcess: RuntimeProcess,
    run: Run,
    revision: WorkloadRevision,
    artifact: ResolvedArtifact,
    environment: [String: String]
  ) async throws -> RuntimeProcess {
    if let updateError { throw updateError }
    updatedProcesses.append(oldProcess)
    return try await start(
      run: run, revision: revision, artifact: artifact, environment: environment)
  }

  public func listManagedProcesses() async throws -> [RuntimeProcess] {
    states.values.filter { $0.state == .running }.map {
      RuntimeProcess(id: $0.runtimeName, runtimeName: $0.runtimeName)
    }
  }

  public func forceStop(_ process: RuntimeProcess) async throws {
    if let forceStopError { throw forceStopError }
    stoppedProcesses.append(process)
    states[process.runtimeName] = RuntimeInspection(
      runtimeName: process.runtimeName, state: .stopped, exitCode: 137)
  }

  public func setInspection(_ inspection: RuntimeInspection) {
    states[inspection.runtimeName] = inspection
  }

  public func setLogs(_ logs: RuntimeLogs, for runtimeName: String) {
    logsByProcess[runtimeName] = logs
  }

  public func setMetrics(_ sample: MetricsSample?, for runtimeName: String) {
    metricsByProcess[runtimeName] = sample
  }
}

public actor AppleContainerRuntimeAdapter: RuntimeAdapter {
  public let kind: RuntimeKind = .appleContainer
  public static var defaultExecutableURL: URL {
    let paths = ["/usr/local/bin/container", "/opt/homebrew/bin/container", "/usr/bin/container"]
    return URL(
      fileURLWithPath: paths.first(where: FileManager.default.isExecutableFile(atPath:))
        ?? paths[0])
  }
  public let executableURL: URL
  private var processes: [String: RuntimeProcess] = [:]

  public init(executableURL: URL = AppleContainerRuntimeAdapter.defaultExecutableURL) {
    self.executableURL = executableURL
  }

  public func checkAvailability() async -> RuntimeAvailability {
    #if !arch(arm64)
      return .unavailable(reason: "Apple container requires Apple silicon")
    #else
      guard #available(macOS 26, *) else {
        return .unavailable(reason: "Apple container requires macOS 26 or later")
      }
      guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
        return .unavailable(
          reason:
            "Apple container is not installed. Install it from the Apple container documentation."
        )
      }
      do {
        let versionOutput = try await runProcess(
          arguments: ["system", "version", "--format", "json"])
        _ = try await runProcess(arguments: ["system", "status", "--format", "json"])
        guard let data = versionOutput.data(using: .utf8),
          let entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
          let version = entries.first(where: { $0["appName"] as? String == "container" })?[
            "version"]
            as? String,
          !version.isEmpty
        else {
          return .unavailable(reason: "Apple container version could not be determined")
        }
        return .available(version: version)
      } catch {
        return .unavailable(reason: error.localizedDescription)
      }
    #endif
  }

  public func start(
    run: Run,
    revision: WorkloadRevision,
    artifact: ResolvedArtifact,
    environment: [String: String]
  ) async throws -> RuntimeProcess {
    guard case .container(let spec) = revision.spec else {
      throw RuntimeError.invalid("Container adapter received a Wasm revision")
    }
    let process = RuntimeProcess(
      id: UUID().uuidString, runID: run.id, runtimeName: run.runtimeName,
      hostPorts: revision.ports.compactMap(\.hostPort))
    var arguments = ["run", "--detach", "--name", run.runtimeName]
    for mapping in revision.ports {
      let port = mapping.hostPort.map(String.init) ?? String(mapping.guestPort)
      arguments += ["--publish", "\(port):\(mapping.guestPort)"]
    }
    for (key, value) in environment.sorted(by: { $0.key < $1.key }) {
      arguments += ["--env", "\(key)=\(value)"]
    }
    for mount in spec.mounts {
      arguments += [
        "--volume",
        "\(mount.hostPath):\(mount.guestPath)\(mount.accessMode == .readOnly ? ":ro" : "")",
      ]
    }
    if let entrypoint = spec.entrypointOverride {
      arguments += ["--entrypoint"] + entrypoint
    }
    let image =
      artifact.id.count == 64 && !spec.imageReference.contains("@sha256:")
      ? "\(spec.imageReference)@sha256:\(artifact.id)"
      : spec.imageReference
    arguments.append(image)
    arguments += revision.arguments
    do {
      _ = try await runProcess(arguments: arguments)
      processes[process.runtimeName] = process
      return process
    } catch let error as RuntimeError {
      throw error
    } catch { throw RuntimeError.unknown(error.localizedDescription) }
  }

  public func stop(_ process: RuntimeProcess, policy: StopPolicy) async throws {
    do {
      _ = try await runProcess(
        arguments: [
          "stop", "--signal", policy.signal.rawValue, "--time", String(Int(policy.timeout)),
          process.runtimeName,
        ], timeout: max(1, policy.timeout + 5))
      processes.removeValue(forKey: process.runtimeName)
    } catch { throw RuntimeError.timeout(error.localizedDescription) }
  }

  public func forceStop(_ process: RuntimeProcess) async throws {
    do {
      _ = try await runProcess(
        arguments: ["kill", "--signal", "KILL", process.runtimeName], timeout: 10)
      processes.removeValue(forKey: process.runtimeName)
    } catch { throw RuntimeError.timeout(error.localizedDescription) }
  }

  public func listManagedProcesses() async throws -> [RuntimeProcess] {
    let output = try await runProcess(arguments: ["list", "--all", "--format", "json"])
    guard let data = output.data(using: .utf8),
      let value = try? JSONSerialization.jsonObject(with: data)
    else { throw RuntimeError.unknown("container list returned invalid JSON") }
    let names = Self.managedNames(in: value)
    return names.map { name in
      processes[name] ?? RuntimeProcess(id: name, runtimeName: name)
    }
  }

  public func inspect(runtimeName: String) async throws -> RuntimeInspection {
    do {
      let output = try await runProcess(arguments: ["inspect", runtimeName])
      guard let data = output.data(using: .utf8),
        let json = try? JSONSerialization.jsonObject(with: data)
      else {
        return RuntimeInspection(runtimeName: runtimeName, state: .running)
      }
      let running =
        Self.value(for: "running", in: json) as? Bool
        ?? (Self.value(for: "status", in: json) as? String)
        .map { $0.localizedCaseInsensitiveContains("running") }
        ?? true
      let exitCode = (Self.value(for: "exitCode", in: json) as? NSNumber)?.int32Value
      return RuntimeInspection(
        runtimeName: runtimeName,
        state: running ? .running : .stopped,
        exitCode: running ? nil : exitCode)
    } catch {
      processes.removeValue(forKey: runtimeName)
      return RuntimeInspection(runtimeName: runtimeName, state: .stopped)
    }
  }

  public func logs(_ process: RuntimeProcess) async throws -> RuntimeLogs {
    do {
      let output = try await runProcess(arguments: ["logs", process.runtimeName])
      return RuntimeLogs(stdout: output)
    } catch { throw RuntimeError.unknown(error.localizedDescription) }
  }

  public func metrics(_ process: RuntimeProcess) async throws -> MetricsSample? {
    guard let runID = process.runID else { return nil }
    let output = try await runProcess(
      arguments: ["stats", "--format", "json", "--no-stream", process.runtimeName])
    guard let data = output.data(using: .utf8),
      let json = try? JSONSerialization.jsonObject(with: data),
      let cpu = Self.firstNumber(for: ["cpuPercent", "cpuPercentage", "cpu"], in: json),
      let memory = Self.firstMemoryBytes(
        for: ["memoryBytes", "memoryUsage", "memory", "memUsage"], in: json)
    else {
      return nil
    }
    return MetricsSample(
      runID: runID, cpuPercent: cpu, memoryBytes: Int64(max(0, memory)))
  }

  public func update(
    oldProcess: RuntimeProcess,
    run: Run,
    revision: WorkloadRevision,
    artifact: ResolvedArtifact,
    environment: [String: String]
  ) async throws -> RuntimeProcess {
    return try await start(
      run: run, revision: revision, artifact: artifact, environment: environment)
  }

  private static func firstNumber(for keys: [String], in object: Any) -> Double? {
    let wanted = Set(keys)
    if let dictionary = object as? [String: Any] {
      for (key, value) in dictionary where wanted.contains(key) {
        if let number = number(from: value) { return number }
      }
      for child in dictionary.values {
        if let number = firstNumber(for: keys, in: child) { return number }
      }
    } else if let array = object as? [Any] {
      for child in array {
        if let number = firstNumber(for: keys, in: child) { return number }
      }
    }
    return nil
  }

  private static func firstMemoryBytes(for keys: [String], in object: Any) -> Double? {
    let wanted = Set(keys)
    if let dictionary = object as? [String: Any] {
      for (key, value) in dictionary where wanted.contains(key) {
        if let memory = memoryBytes(from: value) { return memory }
      }
      for child in dictionary.values {
        if let memory = firstMemoryBytes(for: keys, in: child) { return memory }
      }
    } else if let array = object as? [Any] {
      for child in array {
        if let memory = firstMemoryBytes(for: keys, in: child) { return memory }
      }
    }
    return nil
  }

  private static func number(from value: Any) -> Double? {
    if let number = value as? NSNumber { return number.doubleValue }
    guard let string = value as? String else { return nil }
    return Double(
      string.trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "%", with: ""))
  }

  private static func memoryBytes(from value: Any) -> Double? {
    if let number = value as? NSNumber { return number.doubleValue }
    guard let raw = value as? String else { return nil }
    let value =
      raw.trimmingCharacters(in: .whitespacesAndNewlines)
      .split(separator: "/", maxSplits: 1)
      .first.map(String.init) ?? raw
    let numberText = value.prefix { $0.isNumber || $0 == "." }
    guard let number = Double(numberText) else { return nil }
    let suffix =
      value.dropFirst(numberText.count)
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    let multiplier: Double
    switch suffix {
    case "kib", "ki": multiplier = 1_024
    case "mib", "mi": multiplier = 1_048_576
    case "gib", "gi": multiplier = 1_073_741_824
    case "kb": multiplier = 1_000
    case "mb": multiplier = 1_000_000
    case "gb": multiplier = 1_000_000_000
    default: multiplier = 1
    }
    return number * multiplier
  }

  private static func value(for key: String, in object: Any) -> Any? {
    if let dictionary = object as? [String: Any] {
      if let direct = dictionary[key] { return direct }
      for child in dictionary.values {
        if let found = value(for: key, in: child) { return found }
      }
    } else if let array = object as? [Any] {
      for child in array {
        if let found = value(for: key, in: child) { return found }
      }
    }
    return nil
  }

  private static func managedNames(in value: Any) -> [String] {
    var names: [String] = []
    if let dictionary = value as? [String: Any] {
      for key in ["name", "id"] {
        if let name = dictionary[key] as? String, name.hasPrefix("wasmbox-") {
          names.append(name)
          break
        }
      }
      for child in dictionary.values { names += managedNames(in: child) }
    } else if let array = value as? [Any] {
      for child in array { names += managedNames(in: child) }
    }
    return Array(Set(names)).sorted()
  }

  public func checkHealth(_ kind: HealthCheckKind, process: RuntimeProcess) async -> Bool {
    switch kind {
    case .command(let command):
      guard !command.isEmpty else { return false }
      do {
        _ = try await runProcess(arguments: ["exec", process.runtimeName] + command)
        return true
      } catch {
        return false
      }
    case .http, .tcp:
      return await DefaultHealthProbe().check(kind)
    }
  }
  private func runProcess(
    arguments: [String], environment: [String: String] = [:], timeout: TimeInterval? = 60
  ) async throws -> String {
    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments
    // Never inherit the host environment. Workload variables are the complete environment.
    process.environment = environment
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let completion = ProcessCompletion(
      process: process, output: output, timeoutMessage: "Container command timed out")
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        completion.start(continuation, timeout: timeout)
      }
    } onCancel: {
      completion.cancel()
    }
  }
}

private func withCStringArray<T>(
  _ values: [String],
  _ body: (UnsafePointer<UnsafePointer<CChar>?>?, Int) -> T
) -> T {
  let storage = values.map { Array($0.utf8CString) }
  func visit(
    _ index: Int,
    _ pointers: [UnsafePointer<CChar>?]
  ) -> T {
    guard index < storage.count else {
      return pointers.withUnsafeBufferPointer { buffer in
        body(buffer.baseAddress, pointers.count)
      }
    }
    return storage[index].withUnsafeBufferPointer { buffer in
      var next = pointers
      next.append(buffer.baseAddress)
      return visit(index + 1, next)
    }
  }
  return visit(0, [])
}

public actor WasmtimeRuntimeAdapter: RuntimeAdapter {
  public let kind: RuntimeKind = .wasmtime
  public let libraryNames: [String]

  private struct LogPaths: Sendable {
    let stdout: URL
    let stderr: URL
  }

  private var logPaths: [String: LogPaths] = [:]

  public init(
    libraryNames: [String] = [
      "libwasmtime.dylib",
      "libwasmtime.0.dylib",
      "/opt/homebrew/lib/libwasmtime.dylib",
      "/usr/local/lib/libwasmtime.dylib",
    ]
  ) {
    self.libraryNames = libraryNames
  }

  public func checkAvailability() async -> RuntimeAvailability {
    var message = [CChar](repeating: 0, count: 1024)
    let loaded = withCStringArray(libraryNames) { paths, count in
      message.withUnsafeMutableBufferPointer { buffer in
        wasmbox_wasmtime_runtime_available(
          paths, count, buffer.baseAddress, buffer.count)
      }
    }
    guard loaded != 0 else {
      return .unavailable(reason: Self.message(from: message))
    }
    return .available(version: "Wasmtime C API")
  }

  public func start(
    run: Run,
    revision: WorkloadRevision,
    artifact: ResolvedArtifact,
    environment: [String: String]
  ) async throws -> RuntimeProcess {
    guard case .wasm(let spec) = revision.spec else {
      throw RuntimeError.invalid("Wasmtime adapter received a Container revision")
    }
    guard spec.socketPermission || revision.ports.isEmpty else {
      throw RuntimeError.invalid("Wasm socket permission is required for port mappings")
    }
    guard revision.ports.isEmpty else {
      throw RuntimeError.invalid("WASI socket port mappings are unavailable in this Wasmtime C API")
    }
    guard FileManager.default.fileExists(atPath: artifact.localPath) else {
      throw RuntimeError.notFound(artifact.localPath)
    }

    let baseURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("wasmbox-wasm-\(UUID().uuidString)")
    let stdoutURL = baseURL.appendingPathExtension("stdout")
    let stderrURL = baseURL.appendingPathExtension("stderr")
    let process = RuntimeProcess(
      id: UUID().uuidString, runID: run.id, runtimeName: run.runtimeName, hostPorts: [])
    let arguments = revision.arguments
    let environmentEntries = environment.sorted { $0.key < $1.key }
    let environmentNames = environmentEntries.map(\.key)
    let environmentValues = environmentEntries.map(\.value)
    let preopenHosts = spec.preopens.map(\.hostPath)
    let preopenGuests = spec.preopens.map(\.guestPath)
    let preopenReadOnly = spec.preopens.map {
      $0.accessMode == .readOnly ? Int32(1) : Int32(0)
    }
    var message = [CChar](repeating: 0, count: 1024)

    let started = run.runtimeName.withCString { runtimeName in
      artifact.localPath.withCString { modulePath in
        stdoutURL.path.withCString { stdoutPath in
          stderrURL.path.withCString { stderrPath in
            withCStringArray(arguments) { argumentPointers, argumentCount in
              withCStringArray(environmentNames) { environmentNamePointers, environmentCount in
                withCStringArray(environmentValues) { environmentValuePointers, _ in
                  withCStringArray(preopenHosts) { preopenHostPointers, preopenCount in
                    withCStringArray(preopenGuests) { preopenGuestPointers, _ in
                      preopenReadOnly.withUnsafeBufferPointer { readOnlyBuffer in
                        message.withUnsafeMutableBufferPointer { buffer in
                          wasmbox_wasmtime_start(
                            runtimeName,
                            modulePath,
                            argumentPointers,
                            argumentCount,
                            environmentNamePointers,
                            environmentValuePointers,
                            environmentCount,
                            preopenHostPointers,
                            preopenGuestPointers,
                            readOnlyBuffer.baseAddress,
                            preopenCount,
                            stdoutPath,
                            stderrPath,
                            buffer.baseAddress,
                            buffer.count)
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
    guard started != 0 else {
      throw RuntimeError.unknown(Self.message(from: message))
    }
    logPaths[process.runtimeName] = LogPaths(stdout: stdoutURL, stderr: stderrURL)
    return process
  }

  public func stop(_ process: RuntimeProcess, policy: StopPolicy) async throws {
    var message = [CChar](repeating: 0, count: 1024)
    let milliseconds = UInt32(clamping: Int(max(0, policy.timeout) * 1_000))
    let stopped = process.runtimeName.withCString { runtimeName in
      message.withUnsafeMutableBufferPointer { buffer in
        wasmbox_wasmtime_stop(runtimeName, milliseconds, buffer.baseAddress, buffer.count)
      }
    }
    guard stopped != 0 else {
      throw RuntimeError.timeout(Self.message(from: message))
    }
  }

  public func inspect(runtimeName: String) async throws -> RuntimeInspection {
    var state: Int32 = 0
    var exitCode: Int32 = -1
    var message = [CChar](repeating: 0, count: 1024)
    let inspected = runtimeName.withCString { name in
      message.withUnsafeMutableBufferPointer { buffer in
        wasmbox_wasmtime_inspect(
          name,
          &state,
          &exitCode,
          buffer.baseAddress,
          buffer.count)
      }
    }
    guard inspected != 0 else {
      throw RuntimeError.notFound(Self.message(from: message))
    }
    return RuntimeInspection(
      runtimeName: runtimeName,
      state: state == 1 ? .running : .stopped,
      exitCode: exitCode < 0 ? nil : exitCode)
  }

  public func logs(_ process: RuntimeProcess) async throws -> RuntimeLogs {
    guard let paths = logPaths[process.runtimeName] else { return RuntimeLogs() }
    let stdout = (try? String(contentsOf: paths.stdout, encoding: .utf8)) ?? ""
    let stderr = (try? String(contentsOf: paths.stderr, encoding: .utf8)) ?? ""
    return RuntimeLogs(stdout: stdout, stderr: stderr)
  }

  public func metrics(_ process: RuntimeProcess) async throws -> MetricsSample? { nil }

  public func update(
    oldProcess: RuntimeProcess,
    run: Run,
    revision: WorkloadRevision,
    artifact: ResolvedArtifact,
    environment: [String: String]
  ) async throws -> RuntimeProcess {
    try await start(run: run, revision: revision, artifact: artifact, environment: environment)
  }

  public func listManagedProcesses() async throws -> [RuntimeProcess] {
    logPaths.keys.compactMap { name in
      var state: Int32 = 0
      var exitCode: Int32 = -1
      var message = [CChar](repeating: 0, count: 256)
      let found = name.withCString { runtimeName in
        message.withUnsafeMutableBufferPointer {
          wasmbox_wasmtime_inspect(runtimeName, &state, &exitCode, $0.baseAddress, $0.count)
        }
      }
      return found != 0 && state == 1 ? RuntimeProcess(id: name, runtimeName: name) : nil
    }
  }

  public func forceStop(_ process: RuntimeProcess) async throws {
    try await stop(process, policy: StopPolicy(timeout: 0))
  }

  private static func message(from buffer: [CChar]) -> String {
    String(
      decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) },
      as: UTF8.self)
  }
}

public protocol HealthProbe: Sendable {
  func check(_ kind: HealthCheckKind) async -> Bool
}

public struct DefaultHealthProbe: HealthProbe {
  public init() {}

  public func check(_ kind: HealthCheckKind) async -> Bool {
    switch kind {
    case .command(let command):
      guard let executable = command.first else { return false }
      let process = Process()
      process.executableURL = URL(fileURLWithPath: executable)
      process.arguments = Array(command.dropFirst())
      do {
        process.environment = [:]
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
      } catch { return false }
    case .http(let rawURL):
      guard let url = URL(string: rawURL), url.scheme == "http" || url.scheme == "https" else {
        return false
      }
      do {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(from: url)
        return (response as? HTTPURLResponse).map { (200...399).contains($0.statusCode) } ?? false
      } catch { return false }
    case .tcp(let host, let port):
      return await checkTCP(host: host, port: port)
    }
  }

  private func checkTCP(host: String, port: Int) async -> Bool {
    guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
      return false
    }
    let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
    let completion = TCPProbeCompletion(connection: connection)
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        completion.set(continuation)
        connection.stateUpdateHandler = { state in
          switch state {
          case .ready: completion.finish(true)
          case .failed, .cancelled: completion.finish(false)
          default: break
          }
        }
        connection.start(queue: DispatchQueue.global(qos: .utility))
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
          completion.finish(false)
        }
      }
    } onCancel: {
      completion.finish(false)
    }
  }
}

private final class TCPProbeCompletion: @unchecked Sendable {
  private let connection: NWConnection
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Bool, Never>?
  private var completed = false

  init(connection: NWConnection) { self.connection = connection }

  func set(_ continuation: CheckedContinuation<Bool, Never>) {
    lock.lock()
    if completed {
      lock.unlock()
      continuation.resume(returning: false)
      return
    }
    self.continuation = continuation
    lock.unlock()
  }

  func finish(_ value: Bool) {
    lock.lock()
    guard !completed else {
      lock.unlock()
      return
    }
    completed = true
    let continuation = self.continuation
    self.continuation = nil
    lock.unlock()
    connection.cancel()
    continuation?.resume(returning: value)
  }
}
public actor HealthMonitor {
  private var trackers: [UUID: HealthTracker] = [:]
  private let probe: HealthProbe

  public init(probe: HealthProbe = DefaultHealthProbe()) { self.probe = probe }
  public func start(workloadID: UUID, at date: Date = Date()) {
    var tracker = trackers[workloadID] ?? HealthTracker()
    tracker.start(at: date)
    trackers[workloadID] = tracker
  }

  public func check(workloadID: UUID, check: HealthCheck, at date: Date = Date()) async
    -> HealthTransition
  {
    record(workloadID: workloadID, check: check, success: await probe.check(check.kind), at: date)
  }

  public func record(
    workloadID: UUID, check: HealthCheck, success: Bool, at date: Date = Date()
  ) -> HealthTransition {
    var tracker = trackers[workloadID] ?? HealthTracker()
    if tracker.startedAt == nil || date < tracker.startedAt! { tracker.start(at: date) }
    let status = tracker.record(success: success, check: check, at: date)
    trackers[workloadID] = tracker
    return HealthTransition(
      status: status, restartEligible: tracker.restartEligible(check: check, at: date))
  }

  public func reset(workloadID: UUID) { trackers.removeValue(forKey: workloadID) }
  public func isStable(workloadID: UUID, for duration: TimeInterval, at date: Date = Date()) -> Bool
  {
    trackers[workloadID]?.isStable(for: duration, at: date) ?? false
  }
}
