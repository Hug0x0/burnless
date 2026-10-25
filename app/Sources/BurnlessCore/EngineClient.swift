import Foundation

public struct EngineConfiguration: Sendable, Equatable {
  public var executable: URL
  /// Overrides `CLAUDE_CONFIG_DIR` for the engine process when set.
  public var claudeDirectory: String?
  /// Overrides `CODEX_HOME` for the engine process when set.
  public var codexHome: String?
  /// Overrides `GEMINI_DATA_DIR` (the folder holding `<project>/chats/`) when set.
  public var geminiDirectory: String?
  /// Also fetch current public LiteLLM prices (no usage data is sent).
  public var onlinePricing: Bool
  public var timeZone: TimeZone
  public var timeout: TimeInterval

  public init(
    executable: URL, claudeDirectory: String? = nil, codexHome: String? = nil,
    geminiDirectory: String? = nil, onlinePricing: Bool = false, timeZone: TimeZone = .current, timeout: TimeInterval = 120
  ) {
    self.executable = executable
    self.claudeDirectory = claudeDirectory
    self.codexHome = codexHome
    self.geminiDirectory = geminiDirectory
    self.onlinePricing = onlinePricing
    self.timeZone = timeZone
    self.timeout = timeout
  }

  public var arguments: [String] {
    ["report", "--timezone", timeZone.identifier] + (onlinePricing ? ["--online-pricing"] : [])
  }

  /// Arguments for `quota`. Live reads use the existing sign-ins read-only.
  public func quotaArguments(liveClaude: Bool, liveCodex: Bool) -> [String] {
    ["quota"] + (liveClaude ? ["--live-claude"] : []) + (liveCodex ? ["--live-codex"] : [])
  }

  public func environment(base: [String: String]) -> [String: String] {
    var environment = base
    for (key, value) in [
      ("CLAUDE_CONFIG_DIR", claudeDirectory), ("CODEX_HOME", codexHome),
      ("GEMINI_DATA_DIR", geminiDirectory),
    ] {
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
      let data = try runProcess(configuration, arguments: configuration.arguments)
      return try EngineReport.decode(data)
    }.value
  }

  /// Reads plans and limit meters. Fast: it only inspects the newest files.
  public static func quota(
    _ configuration: EngineConfiguration, liveClaude: Bool, liveCodex: Bool
  ) async throws -> QuotaReport {
    try await Task.detached(priority: .utility) {
      var configuration = configuration
      configuration.timeout = min(configuration.timeout, 45)
      let data = try runProcess(
        configuration,
        arguments: configuration.quotaArguments(liveClaude: liveClaude, liveCodex: liveCodex))
      return try QuotaReport.decode(data)
    }.value
  }

  /// Synchronous variant for the background collector, which has no run loop.
  public static func quotaBlocking(
    _ configuration: EngineConfiguration, liveClaude: Bool, liveCodex: Bool
  ) throws -> QuotaReport {
    var configuration = configuration
    configuration.timeout = min(configuration.timeout, 45)
    let data = try runProcess(
      configuration,
      arguments: configuration.quotaArguments(liveClaude: liveClaude, liveCodex: liveCodex))
    return try QuotaReport.decode(data)
  }

  static func runProcess(_ configuration: EngineConfiguration) throws -> Data {
    try runProcess(configuration, arguments: configuration.arguments)
  }

  static func runProcess(_ configuration: EngineConfiguration, arguments: [String]) throws -> Data {
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
    let errors = directory.appendingPathComponent("errors.txt")
    FileManager.default.createFile(
      atPath: errors.path, contents: nil, attributes: [.posixPermissions: 0o600])
    let errorHandle = try FileHandle(forWritingTo: errors)
    defer { try? errorHandle.close() }

    let process = Process()
    process.executableURL = configuration.executable
    process.arguments = arguments
    process.environment = configuration.environment(base: ProcessInfo.processInfo.environment)
    process.currentDirectoryURL = FileManager.default.temporaryDirectory
    process.standardOutput = handle
    process.standardError = errorHandle
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
      throw EngineError.failed(process.terminationStatus, lastLine(of: errors))
    }
    let size = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    guard size > 0, size <= 64_000_000 else { throw EngineError.invalidOutput }
    return try Data(contentsOf: output)
  }

  /// The engine's last error line, without its name prefix, kept short.
  static func lastLine(of file: URL) -> String? {
    guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
    guard let line = text.split(whereSeparator: \.isNewline).last?.trimmingCharacters(in: .whitespaces),
      !line.isEmpty
    else { return nil }
    let message = line.hasPrefix("burnless-engine: ") ? String(line.dropFirst(17)) : line
    return String(message.prefix(200))
  }
}
