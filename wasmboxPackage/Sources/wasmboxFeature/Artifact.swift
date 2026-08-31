import CryptoKit
import Foundation

public enum ArtifactResolutionError: Error, Equatable, LocalizedError, Sendable {
  case unsupportedSource
  case sourceNotFound(String)
  case cacheMiss(String)
  case hashMismatch(expected: String, actual: String)
  case invalidURL(String)
  case insecureRedirect
  case tooManyRedirects
  case network(String)

  public var errorDescription: String? {
    switch self {
    case .unsupportedSource: "Artifact source is not supported"
    case .sourceNotFound(let source): "Artifact source not found: \(source)"
    case .cacheMiss(let hash): "Pinned artifact is missing from cache: \(hash)"
    case .hashMismatch(let expected, let actual):
      "Artifact hash mismatch: expected \(expected), got \(actual)"
    case .invalidURL(let url): "Invalid HTTPS URL: \(url)"
    case .insecureRedirect: "HTTPS to HTTP redirects are not allowed"
    case .tooManyRedirects: "Artifact redirect limit exceeded"
    case .network(let message): "Artifact download failed: \(message)"
    }
  }
}

public protocol ArtifactResolver: Sendable {
  func resolve(
    source: WorkloadSpec,
    updatePolicy: ArtifactUpdatePolicy,
    pinnedArtifactID: String?,
    expectedHash: String?,
    allowInsecureTLS: Bool
  ) async throws -> ResolvedArtifact
}

public actor ArtifactCache {
  public let rootURL: URL
  private let fileManager: FileManager

  public init(rootURL: URL? = nil, fileManager: FileManager = .default) {
    self.fileManager = fileManager
    if let rootURL {
      self.rootURL = rootURL
    } else {
      let applicationSupport =
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? fileManager.temporaryDirectory
      self.rootURL = applicationSupport.appendingPathComponent(
        "wasmbox/artifacts", isDirectory: true)
    }
  }

  public func prepare() throws {
    try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
  }

  public func url(for hash: String) -> URL { rootURL.appendingPathComponent(hash) }

  public func contains(_ hash: String) -> Bool {
    fileManager.fileExists(atPath: url(for: hash).path)
  }

  public func store(data: Data, hash: String) throws -> URL {
    try prepare()
    let destination = url(for: hash)
    if !fileManager.fileExists(atPath: destination.path) {
      try data.write(to: destination, options: .atomic)
    }
    return destination
  }

  public func removeUnreferenced(keeping hashes: Set<String>) throws -> [String] {
    try prepare()
    let entries = try fileManager.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)
    var removed: [String] = []
    for entry in entries where !hashes.contains(entry.lastPathComponent) {
      try fileManager.removeItem(at: entry)
      removed.append(entry.lastPathComponent)
    }
    return removed.sorted()
  }
}

public struct LocalArtifactResolver: ArtifactResolver, @unchecked Sendable {
  public let cache: ArtifactCache
  private let fileManager: FileManager
  private let containerExecutableURL: URL

  public init(
    cache: ArtifactCache = ArtifactCache(),
    fileManager: FileManager = .default,
    containerExecutableURL: URL = AppleContainerRuntimeAdapter.defaultExecutableURL
  ) {
    self.cache = cache
    self.fileManager = fileManager
    self.containerExecutableURL = containerExecutableURL
  }

  public func resolve(
    source: WorkloadSpec,
    updatePolicy: ArtifactUpdatePolicy,
    pinnedArtifactID: String?,
    expectedHash: String?,
    allowInsecureTLS: Bool
  ) async throws -> ResolvedArtifact {
    switch source {
    case .container(let spec):
      return try await resolveContainer(
        image: spec.imageReference,
        policy: updatePolicy,
        pinnedArtifactID: pinnedArtifactID,
        expectedHash: expectedHash)
    case .wasm(let wasm):
      switch wasm.source {
      case .localPath(let path):
        return try await resolveLocal(
          path: path,
          source: wasm.source.rawValue,
          policy: updatePolicy,
          pinnedArtifactID: pinnedArtifactID,
          expectedHash: expectedHash ?? wasm.expectedSHA256
        )
      case .httpsURL(let url):
        return try await resolveRemote(
          url: url,
          policy: updatePolicy,
          pinnedArtifactID: pinnedArtifactID,
          expectedHash: expectedHash ?? wasm.expectedSHA256,
          allowInsecureTLS: allowInsecureTLS || wasm.allowInsecureTLS
        )
      }
    }
  }
  private func resolveContainer(
    image: String,
    policy: ArtifactUpdatePolicy,
    pinnedArtifactID: String?,
    expectedHash: String?
  ) async throws -> ResolvedArtifact {
    let reference: String
    if policy == .pinned, let pinnedArtifactID {
      let pinned = Self.normalizedHash(pinnedArtifactID)
      let repository = image.split(separator: "@", maxSplits: 1).first.map(String.init) ?? image
      reference = "\(repository)@sha256:\(pinned)"
    } else {
      reference = image
    }
    if policy == .refreshOnStart || pinnedArtifactID == nil { try await pullContainer(image) }
    let digest = try await inspectContainer(reference)
    if let pinnedArtifactID {
      let pinned = Self.normalizedHash(pinnedArtifactID)
      if pinned.caseInsensitiveCompare(digest) != .orderedSame {
        throw ArtifactResolutionError.hashMismatch(expected: pinnedArtifactID, actual: digest)
      }
    }
    if let expectedHash,
      Self.normalizedHash(expectedHash).caseInsensitiveCompare(digest) != .orderedSame
    {
      throw ArtifactResolutionError.hashMismatch(expected: expectedHash, actual: digest)
    }
    return ResolvedArtifact(
      id: digest, source: image, contentHash: digest, localPath: image)
  }

  private func pullContainer(_ image: String) async throws {
    guard fileManager.isExecutableFile(atPath: containerExecutableURL.path) else {
      throw ArtifactResolutionError.unsupportedSource
    }
    let process = Process()
    process.executableURL = containerExecutableURL
    process.arguments = ["image", "pull", image]
    process.environment = [:]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    do {
      try process.run()
      let data = output.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else {
        throw ArtifactResolutionError.network(
          String(data: data, encoding: .utf8) ?? "container image pull failed")
      }
    } catch let error as ArtifactResolutionError {
      throw error
    } catch {
      throw ArtifactResolutionError.network(error.localizedDescription)
    }
  }

  private func inspectContainer(_ image: String) async throws -> String {
    guard fileManager.isExecutableFile(atPath: containerExecutableURL.path) else {
      throw ArtifactResolutionError.unsupportedSource
    }
    let process = Process()
    process.executableURL = containerExecutableURL
    process.arguments = ["image", "inspect", image]
    process.environment = [:]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    do {
      try process.run()
      let data = output.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else {
        throw ArtifactResolutionError.network(
          String(data: data, encoding: .utf8) ?? "container image inspect failed")
      }
      guard let json = try? JSONSerialization.jsonObject(with: data),
        let rawDigest = Self.findDigest(in: json)
      else {
        throw ArtifactResolutionError.network("container image digest was not returned")
      }
      let digest = rawDigest.hasPrefix("sha256:") ? String(rawDigest.dropFirst(7)) : rawDigest
      guard ConfigurationValidator.isSHA256(digest) else {
        throw ArtifactResolutionError.network("container image digest is invalid")
      }
      return digest
    } catch let error as ArtifactResolutionError {
      throw error
    } catch {
      throw ArtifactResolutionError.network(error.localizedDescription)
    }
  }

  private static func findDigest(in value: Any) -> String? {
    if let dictionary = value as? [String: Any] {
      if let configuration = dictionary["configuration"] as? [String: Any],
        let descriptor = configuration["descriptor"] as? [String: Any],
        let digest = descriptor["digest"] as? String
      {
        return digest
      }
      for key in ["digest", "id"] {
        if let digest = dictionary[key] as? String, digest.contains("sha256") {
          return digest
        }
      }
      for child in dictionary.values {
        if let digest = findDigest(in: child) { return digest }
      }
    } else if let array = value as? [Any] {
      for child in array {
        if let digest = findDigest(in: child) { return digest }
      }
    }
    return nil
  }

  private func resolveLocal(
    path: String,
    source: String,
    policy: ArtifactUpdatePolicy,
    pinnedArtifactID: String?,
    expectedHash: String?
  ) async throws -> ResolvedArtifact {
    if policy == .pinned, let pinnedArtifactID {
      let pinned = Self.normalizedHash(pinnedArtifactID)
      guard await cache.contains(pinned) else {
        throw ArtifactResolutionError.cacheMiss(pinnedArtifactID)
      }
      let url = await cache.url(for: pinned)
      let data: Data
      do { data = try Data(contentsOf: url, options: .mappedIfSafe) } catch {
        throw ArtifactResolutionError.cacheMiss(pinnedArtifactID)
      }
      let actual = Self.sha256(data)
      guard actual.caseInsensitiveCompare(pinned) == .orderedSame else {
        throw ArtifactResolutionError.hashMismatch(expected: pinnedArtifactID, actual: actual)
      }
      if let expectedHash,
        Self.normalizedHash(expectedHash).caseInsensitiveCompare(actual) != .orderedSame
      {
        throw ArtifactResolutionError.hashMismatch(expected: expectedHash, actual: actual)
      }
      return ResolvedArtifact(
        id: pinned, source: source, contentHash: actual, localPath: url.path)
    }
    guard fileManager.fileExists(atPath: path), fileManager.isReadableFile(atPath: path) else {
      throw ArtifactResolutionError.sourceNotFound(path)
    }
    let data: Data
    do { data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) } catch {
      throw ArtifactResolutionError.network(error.localizedDescription)
    }
    let hash = Self.sha256(data)
    if let expectedHash,
      Self.normalizedHash(expectedHash).caseInsensitiveCompare(hash) != .orderedSame
    {
      throw ArtifactResolutionError.hashMismatch(expected: expectedHash, actual: hash)
    }
    let destination = try await cache.store(data: data, hash: hash)
    return ResolvedArtifact(
      id: hash, source: source, contentHash: hash, localPath: destination.path)
  }

  private func resolveRemote(
    url: String,
    policy: ArtifactUpdatePolicy,
    pinnedArtifactID: String?,
    expectedHash: String?,
    allowInsecureTLS: Bool
  ) async throws -> ResolvedArtifact {
    if policy == .pinned, let pinnedArtifactID {
      let pinned = Self.normalizedHash(pinnedArtifactID)
      guard await cache.contains(pinned) else {
        throw ArtifactResolutionError.cacheMiss(pinnedArtifactID)
      }
      let path = await cache.url(for: pinned).path
      let data: Data
      do { data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) } catch {
        throw ArtifactResolutionError.cacheMiss(pinnedArtifactID)
      }
      let actual = Self.sha256(data)
      guard actual.caseInsensitiveCompare(pinned) == .orderedSame else {
        throw ArtifactResolutionError.hashMismatch(expected: pinnedArtifactID, actual: actual)
      }
      if let expectedHash,
        Self.normalizedHash(expectedHash).caseInsensitiveCompare(actual) != .orderedSame
      {
        throw ArtifactResolutionError.hashMismatch(expected: expectedHash, actual: actual)
      }
      return ResolvedArtifact(
        id: pinned, source: url, contentHash: actual, localPath: path, finalURL: url)
    }
    guard var currentURL = URL(string: url), currentURL.scheme?.lowercased() == "https" else {
      throw ArtifactResolutionError.invalidURL(url)
    }
    var redirects = 0
    let data: Data
    var finalURL = currentURL
    let totalDeadline = Date().addingTimeInterval(600)
    while true {
      do {
        let remaining = totalDeadline.timeIntervalSinceNow
        guard remaining > 0 else {
          throw ArtifactResolutionError.network("Total timeout after 10 minutes")
        }
        let (downloaded, http) = try await ArtifactDownloadClient(
          allowInsecureTLS: allowInsecureTLS, totalTimeout: remaining
        ).download(currentURL)
        if (300...399).contains(http.statusCode),
          let location = http.value(forHTTPHeaderField: "Location")
        {
          guard let redirected = URL(string: location, relativeTo: currentURL)?.absoluteURL else {
            throw ArtifactResolutionError.invalidURL(location)
          }
          guard redirected.scheme?.lowercased() == "https" else {
            throw ArtifactResolutionError.insecureRedirect
          }
          redirects += 1
          guard redirects <= 5 else { throw ArtifactResolutionError.tooManyRedirects }
          currentURL = redirected
          continue
        }
        guard (200...299).contains(http.statusCode) else {
          throw ArtifactResolutionError.network("HTTP \(http.statusCode)")
        }
        data = downloaded
        finalURL = http.url ?? currentURL
        break
      } catch let error as ArtifactResolutionError {
        throw error
      } catch {
        throw ArtifactResolutionError.network(error.localizedDescription)
      }
    }
    let hash = Self.sha256(data)
    if let expectedHash,
      Self.normalizedHash(expectedHash).caseInsensitiveCompare(hash) != .orderedSame
    {
      throw ArtifactResolutionError.hashMismatch(expected: expectedHash, actual: hash)
    }
    let destination = try await cache.store(data: data, hash: hash)
    return ResolvedArtifact(
      id: hash,
      source: url,
      contentHash: hash,
      localPath: destination.path,
      finalURL: finalURL.absoluteString
    )
  }

  private static func normalizedHash(_ value: String) -> String {
    value.lowercased().hasPrefix("sha256:") ? String(value.dropFirst(7)) : value
  }

  public static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

public struct InMemoryArtifactResolver: ArtifactResolver, Sendable {
  public var artifacts: [String: ResolvedArtifact]
  public var error: ArtifactResolutionError?

  public init(artifacts: [String: ResolvedArtifact] = [:], error: ArtifactResolutionError? = nil) {
    self.artifacts = artifacts
    self.error = error
  }

  public func resolve(
    source: WorkloadSpec,
    updatePolicy: ArtifactUpdatePolicy,
    pinnedArtifactID: String?,
    expectedHash: String?,
    allowInsecureTLS: Bool
  ) async throws -> ResolvedArtifact {
    if let error { throw error }
    let key: String
    switch source {
    case .container(let spec): key = spec.imageReference
    case .wasm(let spec): key = spec.source.rawValue
    }
    let artifact: ResolvedArtifact
    if updatePolicy == .pinned, let pinnedArtifactID {
      let normalizedPinned = Self.normalizedHash(pinnedArtifactID)
      guard
        let pinned = artifacts.first(where: {
          Self.normalizedHash($0.key).caseInsensitiveCompare(normalizedPinned) == .orderedSame
        })?.value
      else {
        throw ArtifactResolutionError.cacheMiss(pinnedArtifactID)
      }
      artifact = pinned
    } else {
      guard let resolved = artifacts[key] else {
        throw ArtifactResolutionError.sourceNotFound(key)
      }
      artifact = resolved
    }
    if let expectedHash,
      Self.normalizedHash(expectedHash).caseInsensitiveCompare(
        Self.normalizedHash(artifact.contentHash)
      ) != .orderedSame
    {
      throw ArtifactResolutionError.hashMismatch(
        expected: expectedHash, actual: artifact.contentHash)
    }
    return artifact
  }

  private static func normalizedHash(_ value: String) -> String {
    value.lowercased().hasPrefix("sha256:") ? String(value.dropFirst(7)) : value
  }
}

private final class ArtifactDownloadClient: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let allowInsecureTLS: Bool
  private let totalTimeout: TimeInterval
  private let lock = NSLock()
  private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
  private var session: URLSession?
  private var task: URLSessionDataTask?
  private var response: HTTPURLResponse?
  private var data = Data()
  private var connectTimer: DispatchWorkItem?
  private var readTimer: DispatchWorkItem?
  private var totalTimer: DispatchWorkItem?
  private var finished = false

  init(allowInsecureTLS: Bool, totalTimeout: TimeInterval = 600) {
    self.allowInsecureTLS = allowInsecureTLS
    self.totalTimeout = totalTimeout
  }

  func download(_ url: URL) async throws -> (Data, HTTPURLResponse) {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        start(url: url, continuation: continuation)
      }
    } onCancel: {
      finish(.failure(CancellationError()))
    }
  }

  private func start(
    url: URL,
    continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>
  ) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 600
    configuration.timeoutIntervalForResource = 600
    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    let task = session.dataTask(with: URLRequest(url: url))
    lock.lock()
    self.continuation = continuation
    self.session = session
    self.task = task
    lock.unlock()
    connectTimer = schedule(after: 10, message: "Connect timeout after 10 seconds")
    totalTimer = schedule(after: totalTimeout, message: "Total timeout after 10 minutes")
    task.resume()
  }

  private func schedule(after seconds: TimeInterval, message: String) -> DispatchWorkItem {
    let item = DispatchWorkItem { [weak self] in
      self?.finish(.failure(ArtifactResolutionError.network(message)))
    }
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds, execute: item)
    return item
  }

  private func resetReadTimer() {
    readTimer?.cancel()
    readTimer = schedule(after: 30, message: "Read timeout after 30 seconds")
  }

  private func finish(_ result: Result<(Data, HTTPURLResponse), Error>) {
    lock.lock()
    guard !finished else {
      lock.unlock()
      return
    }
    finished = true
    let continuation = self.continuation
    self.continuation = nil
    connectTimer?.cancel()
    readTimer?.cancel()
    totalTimer?.cancel()
    let session = self.session
    lock.unlock()
    session?.invalidateAndCancel()
    continuation?.resume(with: result)
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    guard let response = response as? HTTPURLResponse else {
      completionHandler(.cancel)
      finish(.failure(ArtifactResolutionError.network("Non-HTTP response")))
      return
    }
    lock.lock()
    self.response = response
    connectTimer?.cancel()
    resetReadTimer()
    lock.unlock()
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    lock.lock()
    self.data.append(data)
    resetReadTimer()
    lock.unlock()
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: Error?
  ) {
    if let error {
      finish(.failure(error))
      return
    }
    lock.lock()
    let response = self.response
    let data = self.data
    lock.unlock()
    guard let response else {
      finish(.failure(ArtifactResolutionError.network("Missing HTTP response")))
      return
    }
    finish(.success((data, response)))
  }

  func urlSession(
    _ session: URLSession,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    guard allowInsecureTLS, let trust = challenge.protectionSpace.serverTrust else {
      completionHandler(.performDefaultHandling, nil)
      return
    }
    completionHandler(.useCredential, URLCredential(trust: trust))
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}
