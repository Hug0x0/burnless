import Foundation

public struct EngineConfiguration: Sendable, Equatable {
  public var executable: URL
  /// Overrides `CLAUDE_CONFIG_DIR` for the engine process when set.
  public var claudeDirectory: String?
  /// Overrides `CODEX_HOME` for the engine process when set.
  public var codexHome: String?
  /// Also fetch current public LiteLLM prices (no usage data is sent).
  public var onlinePricing: Bool
  public var timeZone: TimeZone
  public var timeout: TimeInterval

  public init(
    executable: URL, claudeDirectory: String? = nil, codexHome: String? = nil,
    onlinePricing: Bool = false, timeZone: TimeZone = .current, timeout: TimeInterval = 120
  ) {
    self.executable = executable
    self.claudeDirectory = claudeDirectory
    self.codexHome = codexHome
    self.onlinePricing = onlinePricing
    self.timeZone = timeZone
    self.timeout = timeout
  }

  public var arguments: [String] {
    ["report", "--timezone", timeZone.identifier] + (onlinePricing ? ["--online-pricing"] : [])
  }

  public func environment(base: [String: String]) -> [String: String] {
    var environment = base
    for (key, value) in [("CLAUDE_CONFIG_DIR", claudeDirectory), ("CODEX_HOME", codexHome)] {
      if let value, !value.trimmingCharacters(in: .whitespaces).isEmpty {
        environment[key] = value
      }
    }
    return environment
  }
}

public enum EngineClient {
  public static let executableName = "burnless-engine"

  /// Finds the engine: `BURNLESS_ENGINE`, then the app bundle's Resources,
  /// then a development build next to the Swift package (`swift run`).
  public static func locate(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    bundle: Bundle = .main
  ) -> URL? {
    let manager = FileManager.default
    var candidates: [URL] = []
    if let path = environment["BURNLESS_ENGINE"], !path.isEmpty {
      candidates.append(URL(fileURLWithPath: NSString(string: path).expandingTildeInPath))
    }
    if let resources = bundle.resourceURL {
      candidates.append(resources.appendingPathComponent(executableName))
    }
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    var directory = executable.deletingLastPathComponent()
    for _ in 0..<8 {
      candidates.append(directory.appendingPathComponent("engine/target/release/\(executableName)"))
      candidates.append(
        directory.appendingPathComponent("../engine/target/release/\(executableName)")
          .standardizedFileURL)
      directory = directory.deletingLastPathComponent()
    }
    return candidates.first { manager.isExecutableFile(atPath: $0.path) }
  }

  /// Runs the engine off the calling thread and decodes its report.
  public static func run(_ configuration: EngineConfiguration) async throws -> EngineReport {
    try await Task.detached(priority: .utility) {
      let data = try runProcess(configuration)
      return try EngineReport.decode(data)
    }.value
  }

  static func runProcess(_ configuration: EngineConfiguration) throws -> Data {
    guard FileManager.default.isExecutableFile(atPath: configuration.executable.path) else {
      throw EngineError.missing
    }
    // Output goes to a private temporary file rather than a pipe, so a large
    // report can never block the child on a full pipe buffer.
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("burnless-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let output = directory.appendingPathComponent("report.json")
    FileManager.default.createFile(
      atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
    let handle = try FileHandle(forWritingTo: output)
    defer { try? handle.close() }

    let process = Process()
    process.executableURL = configuration.executable
    process.arguments = configuration.arguments
    process.environment = configuration.environment(base: ProcessInfo.processInfo.environment)
    process.currentDirectoryURL = FileManager.default.temporaryDirectory
    process.standardOutput = handle
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice

    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }
    try process.run()
    if finished.wait(timeout: .now() + configuration.timeout) == .timedOut {
      process.terminate()
      if finished.wait(timeout: .now() + 1) == .timedOut {
        kill(process.processIdentifier, SIGKILL)
        finished.wait()
      }
      throw EngineError.timedOut
    }
    guard process.terminationStatus == 0 else {
      throw EngineError.failed(process.terminationStatus)
    }
    let size = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    guard size > 0, size <= 64_000_000 else { throw EngineError.invalidOutput }
    return try Data(contentsOf: output)
  }
}
