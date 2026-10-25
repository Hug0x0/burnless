import Foundation

/// The sources Burnless reads. Raw values match the engine's `source` ids.
public enum Harness: String, Codable, CaseIterable, Identifiable, Sendable, Comparable {
  case claude, codex, gemini

  public var id: String { rawValue }

  public var name: String {
    switch self {
    case .claude: "Claude Code"
    case .codex: "Codex"
    case .gemini: "Gemini CLI"
    }
  }

  /// Whether Burnless reads a subscription limit meter for this harness.
  /// Gemini CLI saves no limit reading on disk, so it shows usage only.
  public var readsLimits: Bool { self != .gemini }

  public static func < (lhs: Harness, rhs: Harness) -> Bool {
    allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
  }
}

public enum SourceState: String, Codable, Sendable {
  case ok, notFound, error
}

public struct SourceStatus: Codable, Equatable, Sendable {
  public var id: Harness
  public var state: SourceState
  public var paths: [String]
  public var searched: [String]
  public var envVar: String
  public var envOverride: Bool
  public var error: String?

  public init(
    id: Harness, state: SourceState, paths: [String] = [], searched: [String] = [],
    envVar: String = "", envOverride: Bool = false, error: String? = nil
  ) {
    self.id = id
    self.state = state
    self.paths = paths
    self.searched = searched
    self.envVar = envVar
    self.envOverride = envOverride
    self.error = error
  }
}

public struct PricingInfo: Codable, Equatable, Sendable {
  public var provider: String
  public var ccusageRevision: String
  public var litellmRevision: String
  public var snapshotDate: String
  public var online: Bool
  /// Whether current prices were actually downloaded (`nil` from older engines).
  public var onlineFetched: Bool?

  public init(
    provider: String, ccusageRevision: String, litellmRevision: String, snapshotDate: String,
    online: Bool, onlineFetched: Bool? = nil
  ) {
    self.provider = provider
    self.ccusageRevision = ccusageRevision
    self.litellmRevision = litellmRevision
    self.snapshotDate = snapshotDate
    self.online = online
    self.onlineFetched = onlineFetched
  }
}

/// One (source, local date, model) cell from the engine.
///
/// `totalTokens` is exactly input + output + cache write + cache read, with
/// input excluding cached input for both sources.
public struct UsageRow: Codable, Equatable, Sendable {
  public var source: Harness
  /// `YYYY-MM-DD` in the report timezone.
  public var date: String
  /// `nil` when the source logged usage without a model.
  public var model: String?
  public var inputTokens: UInt64
  public var outputTokens: UInt64
  public var cacheWriteTokens: UInt64
  public var cacheReadTokens: UInt64
  public var reasoningTokens: UInt64
  public var totalTokens: UInt64
  /// Known cost only. When `missingPricing` is set, part or all of the
  /// usage could not be valued and this is a lower bound.
  public var costUSD: Double
  public var missingPricing: Bool
  public var inferredModel: Bool
  /// `costUSD` split by token class (`nil` from older engines and caches).
  public var costBreakdown: CostBreakdown?

  public init(
    source: Harness, date: String, model: String?, inputTokens: UInt64 = 0,
    outputTokens: UInt64 = 0, cacheWriteTokens: UInt64 = 0, cacheReadTokens: UInt64 = 0,
    reasoningTokens: UInt64 = 0, costUSD: Double = 0, missingPricing: Bool = false,
    inferredModel: Bool = false, costBreakdown: CostBreakdown? = nil
  ) {
    self.source = source
    self.date = date
    self.model = model
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.cacheWriteTokens = cacheWriteTokens
    self.cacheReadTokens = cacheReadTokens
    self.reasoningTokens = reasoningTokens
    self.totalTokens = inputTokens + outputTokens + cacheWriteTokens + cacheReadTokens
    self.costUSD = costUSD
    self.missingPricing = missingPricing
    self.inferredModel = inferredModel
    self.costBreakdown = costBreakdown
  }
}

/// API-equivalent cost per token class, in USD. The parts add up to the row cost.
public struct CostBreakdown: Codable, Equatable, Sendable {
  public var input: Double
  public var output: Double
  public var cacheWrite: Double
  public var cacheRead: Double

  public init(input: Double = 0, output: Double = 0, cacheWrite: Double = 0, cacheRead: Double = 0) {
    self.input = input
    self.output = output
    self.cacheWrite = cacheWrite
    self.cacheRead = cacheRead
  }
}

/// Codex image generations in sessions that started on `date`.
public struct ImageDay: Codable, Equatable, Sendable {
  public var date: String
  public var count: Int

  public init(date: String, count: Int) {
    self.date = date
    self.count = count
  }
}

/// The JSON document printed by `burnless-engine report`.
public struct EngineReport: Codable, Equatable, Sendable {
  public static let supportedSchemaVersion = 1

  public var schemaVersion: Int
  public var engineVersion: String
  public var generatedAtMs: Int64
  public var timezone: String?
  public var pricing: PricingInfo
  public var sources: [SourceStatus]
  public var rows: [UsageRow]
  /// Codex image generations over the last 30 days (`nil` from older engines).
  public var codexImages: [ImageDay]?

  public init(
    schemaVersion: Int = EngineReport.supportedSchemaVersion, engineVersion: String = "test",
    generatedAtMs: Int64 = 0, timezone: String? = nil, pricing: PricingInfo,
    sources: [SourceStatus], rows: [UsageRow], codexImages: [ImageDay]? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.engineVersion = engineVersion
    self.generatedAtMs = generatedAtMs
    self.timezone = timezone
    self.pricing = pricing
    self.sources = sources
    self.rows = rows
    self.codexImages = codexImages
  }

  /// Decodes and validates an engine report. Rejects other schema versions
  /// instead of guessing at fields whose meaning may have changed.
  public static func decode(_ data: Data) throws -> EngineReport {
    struct Header: Decodable { let schemaVersion: Int }
    let header: Header
    do { header = try JSONDecoder().decode(Header.self, from: data) } catch {
      throw EngineError.invalidOutput
    }
    guard header.schemaVersion == supportedSchemaVersion else {
      throw EngineError.unsupportedSchema(header.schemaVersion)
    }
    do { return try JSONDecoder().decode(EngineReport.self, from: data) } catch {
      throw EngineError.invalidOutput
    }
  }
}

public enum EngineError: LocalizedError, Equatable, Sendable {
  case missing
  /// Exit status and the engine's last error line, if it printed one.
  case failed(Int32, String? = nil)
  case timedOut
  case invalidOutput
  case unsupportedSchema(Int)

  public var errorDescription: String? {
    switch self {
    case .missing:
      "The Burnless engine was not found inside the app. Rebuild Burnless.app with scripts/build-app.sh."
    case .failed(let code, let message):
      "The usage reader exited with status \(code)" + (message.map { ": \($0)" } ?? ".")
    case .timedOut: "Reading usage history took too long and was stopped."
    case .invalidOutput: "The usage reader returned a report Burnless could not read."
    case .unsupportedSchema(let version):
      "The usage reader returned schema \(version); this app reads schema \(EngineReport.supportedSchemaVersion)."
    }
  }
}
