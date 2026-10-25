import Foundation

/// The JSON document printed by `burnless-engine quota`.
public struct QuotaReport: Codable, Equatable, Sendable {
  public static let supportedSchemaVersion = 1

  public var schemaVersion: Int
  public var engineVersion: String
  public var generatedAtMs: Double
  public var claude: ClaudeQuota
  public var codex: CodexQuota

  public init(
    schemaVersion: Int = QuotaReport.supportedSchemaVersion, engineVersion: String = "test",
    generatedAtMs: Double = 0, claude: ClaudeQuota = ClaudeQuota(),
    codex: CodexQuota = CodexQuota()
  ) {
    self.schemaVersion = schemaVersion
    self.engineVersion = engineVersion
    self.generatedAtMs = generatedAtMs
    self.claude = claude
    self.codex = codex
  }

  public static func decode(_ data: Data) throws -> QuotaReport {
    struct Header: Decodable { let schemaVersion: Int }
    let header: Header
    do { header = try JSONDecoder().decode(Header.self, from: data) } catch {
      throw EngineError.invalidOutput
    }
    guard header.schemaVersion == supportedSchemaVersion else {
      throw EngineError.unsupportedSchema(header.schemaVersion)
    }
    do { return try JSONDecoder().decode(QuotaReport.self, from: data) } catch {
      throw EngineError.invalidOutput
    }
  }
}

/// A limit window as reported: share used, length and reset time.
public struct LimitWindow: Codable, Equatable, Sendable {
  public var usedPercent: Double
  public var windowMinutes: Double
  public var resetsAtMs: Double?

  public init(usedPercent: Double, windowMinutes: Double, resetsAtMs: Double?) {
    self.usedPercent = usedPercent
    self.windowMinutes = windowMinutes
    self.resetsAtMs = resetsAtMs
  }

  public var resetsAt: Date? { resetsAtMs.map { Date(timeIntervalSince1970: $0 / 1000) } }
}

public enum LiveState: String, Codable, Sendable {
  case off, ok, noSignIn, signInExpired, unauthorized, rateLimited, failed
}

public struct LiveStatus: Codable, Equatable, Sendable {
  public var state: LiveState
  public var retryAfterSeconds: Double?

  public init(state: LiveState = .off, retryAfterSeconds: Double? = nil) {
    self.state = state
    self.retryAfterSeconds = retryAfterSeconds
  }
}

public struct ClaudeQuota: Codable, Equatable, Sendable {
  /// Account rate-limit tier from `~/.claude.json`, e.g. `default_claude_max_20x`.
  public var planTier: String?
  public var account: ClaudeAccount?
  public var live: LiveStatus

  public init(planTier: String? = nil, account: ClaudeAccount? = nil, live: LiveStatus = LiveStatus()) {
    self.planTier = planTier
    self.account = account
    self.live = live
  }
}

public struct ClaudeAccount: Codable, Equatable, Sendable {
  /// `claudeCode` (the cache Claude Code keeps) or `live`.
  public var source: String
  public var observedAtMs: Double
  public var session: LimitWindow?
  public var weekly: LimitWindow?
  public var scoped: [ScopedLimit]
  public var extra: ExtraUsage?

  public init(
    source: String, observedAtMs: Double, session: LimitWindow? = nil, weekly: LimitWindow? = nil,
    scoped: [ScopedLimit] = [], extra: ExtraUsage? = nil
  ) {
    self.source = source
    self.observedAtMs = observedAtMs
    self.session = session
    self.weekly = weekly
    self.scoped = scoped
    self.extra = extra
  }

  public var observedAt: Date { Date(timeIntervalSince1970: observedAtMs / 1000) }
}

public struct ScopedLimit: Codable, Equatable, Sendable, Identifiable {
  public var name: String
  public var usedPercent: Double
  public var resetsAtMs: Double?
  public var id: String { name }

  public init(name: String, usedPercent: Double, resetsAtMs: Double? = nil) {
    self.name = name
    self.usedPercent = usedPercent
    self.resetsAtMs = resetsAtMs
  }
}

public struct ExtraUsage: Codable, Equatable, Sendable {
  public var enabled: Bool
  public var usedUSD: Double?
  public var limitUSD: Double?
  public var usedPercent: Double?

  public init(enabled: Bool, usedUSD: Double? = nil, limitUSD: Double? = nil, usedPercent: Double? = nil) {
    self.enabled = enabled
    self.usedUSD = usedUSD
    self.limitUSD = limitUSD
    self.usedPercent = usedPercent
  }

  /// Extra usage is noise until it is switched on or has actually been spent.
  public var isRelevant: Bool { enabled || (usedUSD ?? 0) > 0 }

  public var resolvedUsedPercent: Double? {
    if let usedPercent { return min(100, max(0, usedPercent)) }
    guard let used = usedUSD, let limit = limitUSD, limit > 0 else { return nil }
    return min(100, max(0, used / limit * 100))
  }
}

public struct CodexQuota: Codable, Equatable, Sendable {
  public var planType: String?
  public var snapshot: CodexSnapshot?
  public var limitUsageDaily: [LimitUsageDay]
  public var live: LiveStatus

  public init(
    planType: String? = nil, snapshot: CodexSnapshot? = nil, limitUsageDaily: [LimitUsageDay] = [],
    live: LiveStatus = LiveStatus()
  ) {
    self.planType = planType
    self.snapshot = snapshot
    self.limitUsageDaily = limitUsageDaily
    self.live = live
  }
}

public struct CodexSnapshot: Codable, Equatable, Sendable {
  /// `logs` (Codex session files) or `live`.
  public var source: String
  public var observedAtMs: Double?
  public var weekly: LimitWindow?
  public var short: LimitWindow?
  public var resetCreditsAvailable: Int?

  public init(
    source: String, observedAtMs: Double?, weekly: LimitWindow? = nil, short: LimitWindow? = nil,
    resetCreditsAvailable: Int? = nil
  ) {
    self.source = source
    self.observedAtMs = observedAtMs
    self.weekly = weekly
    self.short = short
    self.resetCreditsAvailable = resetCreditsAvailable
  }

  public var observedAt: Date? { observedAtMs.map { Date(timeIntervalSince1970: $0 / 1000) } }
}

public struct LimitUsageDay: Codable, Equatable, Sendable, Identifiable {
  public var date: String
  public var usedPercent: Double
  public var surfaces: [LimitUsageSurface]
  public var models: [LimitUsageModel]
  public var id: String { date }

  public init(
    date: String, usedPercent: Double, surfaces: [LimitUsageSurface] = [],
    models: [LimitUsageModel] = []
  ) {
    self.date = date
    self.usedPercent = usedPercent
    self.surfaces = surfaces
    self.models = models
  }
}

public struct LimitUsageSurface: Codable, Equatable, Sendable {
  public var surface: String
  public var usedPercent: Double

  public init(surface: String, usedPercent: Double) {
    self.surface = surface
    self.usedPercent = usedPercent
  }
}

public struct LimitUsageModel: Codable, Equatable, Sendable {
  public var model: String
  public var speed: String?
  public var usedPercent: Double

  public init(model: String, speed: String? = nil, usedPercent: Double) {
    self.model = model
    self.speed = speed
    self.usedPercent = usedPercent
  }
}

// MARK: - Readings

/// The limit meters Burnless tracks over time.
public enum QuotaSeries: String, Codable, CaseIterable, Sendable {
  case claudeWeekly = "claude"
  case claudeSession = "claude-session"
  case codexWeekly = "codex"
  case codexShort = "codex-short"

  public var harness: Harness {
    switch self {
    case .claudeWeekly, .claudeSession: .claude
    case .codexWeekly, .codexShort: .codex
    }
  }
}

/// One observation of a limit meter.
public struct QuotaReading: Codable, Equatable, Sendable {
  public var observedAt: Date
  public var usedPercent: Double
  public var windowMinutes: Double
  public var resetsAt: Date
  /// `logs`, `claudeCode` or `live`.
  public var source: String

  public init(
    observedAt: Date, usedPercent: Double, windowMinutes: Double, resetsAt: Date, source: String
  ) {
    self.observedAt = observedAt
    self.usedPercent = usedPercent
    self.windowMinutes = windowMinutes
    self.resetsAt = resetsAt
    self.source = source
  }

  public var duration: TimeInterval { max(60, windowMinutes * 60) }
  /// Start of the limit window this reading belongs to.
  public var windowStart: Date { resetsAt.addingTimeInterval(-duration) }
  public var remaining: Double { max(0, min(100, 100 - usedPercent)) }

  public var isValid: Bool {
    usedPercent.isFinite && usedPercent >= 0 && windowMinutes.isFinite && windowMinutes > 0
      && observedAt.timeIntervalSince1970.isFinite
  }

  init?(_ window: LimitWindow?, observedAt: Date?, source: String) {
    guard let window, let observedAt, let resetsAt = window.resetsAt else { return nil }
    self.init(
      observedAt: observedAt, usedPercent: min(100, window.usedPercent),
      windowMinutes: window.windowMinutes, resetsAt: resetsAt, source: source)
    guard isValid else { return nil }
  }
}

extension QuotaReport {
  /// Every meter in this report as a reading, keyed by series.
  public var readings: [QuotaSeries: QuotaReading] {
    var readings: [QuotaSeries: QuotaReading] = [:]
    if let account = claude.account {
      readings[.claudeWeekly] = QuotaReading(
        account.weekly, observedAt: account.observedAt, source: account.source)
      readings[.claudeSession] = QuotaReading(
        account.session, observedAt: account.observedAt, source: account.source)
    }
    if let snapshot = codex.snapshot {
      readings[.codexWeekly] = QuotaReading(
        snapshot.weekly, observedAt: snapshot.observedAt, source: snapshot.source)
      readings[.codexShort] = QuotaReading(
        snapshot.short, observedAt: snapshot.observedAt, source: snapshot.source)
    }
    return readings
  }
}

// MARK: - Forecast

/// One limit window projected forward from its latest reading.
///
/// Adapted from Agent Burn's `Forecast`
/// (https://github.com/Melvynx/agent-burn, MIT): even pace spreads the limit
/// across the window; the forecast extends the observed burn rate to reset.
public struct Forecast: Equatable, Sendable {
  public var usedPercent: Double
  public var duration: TimeInterval
  public var reset: Date
  public var observedAt: Date
  public var source: String

  public init(reading: QuotaReading) {
    usedPercent = max(0, min(100, reading.usedPercent))
    duration = reading.duration
    reset = reading.resetsAt
    observedAt = reading.observedAt
    source = reading.source
  }

  public init(usedPercent: Double, duration: TimeInterval, reset: Date, observedAt: Date, source: String = "live") {
    self.usedPercent = max(0, min(100, usedPercent))
    self.duration = max(60, duration)
    self.reset = reset
    self.observedAt = observedAt
    self.source = source
  }

  public var isLive: Bool { source == "live" }
  public var start: Date { reset.addingTimeInterval(-duration) }
  public var remaining: Double { max(0, min(100, 100 - usedPercent)) }
  /// Share of the window that had passed when the reading was taken.
  public var elapsed: Double { max(0, min(1, observedAt.timeIntervalSince(start) / duration)) }
  /// The window ended after this reading, so its value no longer applies.
  public func hasReset(at now: Date) -> Bool { now >= reset }
  /// The reading is old enough that usage since may have moved it: six
  /// hours for a weekly window, half an hour for a 5-hour session.
  public func isStale(at now: Date) -> Bool {
    now.timeIntervalSince(observedAt) > max(1_800, duration / 28)
  }
  /// Remaining once a reset has passed: a new window starts full.
  public func remaining(at now: Date) -> Double { hasReset(at: now) ? 100 : remaining }

  /// Usage at reset if the observed pace continues. None in the first 3% of
  /// a window (at least 15 minutes): 1% two minutes after a reset is not a
  /// pace worth projecting.
  public var projectedUse: Double? {
    guard usedPercent > 0, elapsed * duration >= max(900, duration * 0.03) else { return nil }
    return usedPercent / elapsed
  }
  public var daysEarly: Double {
    guard let projectedUse, projectedUse > 100 else { return 0 }
    return duration * (1 - 100 / projectedUse) / 86_400
  }
  /// Remaining share per day that lasts exactly until reset, counted from
  /// the reading.
  public var dailyAllowance: Double { dailyAllowance(at: observedAt) }
  /// The same from `now` when the reading is older: the days left shrink
  /// even though usage since is unknown.
  public func dailyAllowance(at now: Date) -> Double {
    remaining / max(1.0 / 1440, reset.timeIntervalSince(max(now, observedAt)) / 86_400)
  }
  public var projectedEnd: Date {
    guard let projectedUse, projectedUse > 100 else { return reset }
    return start.addingTimeInterval(duration * 100 / projectedUse)
  }
  public var projectedRemaining: Double { max(0, 100 - (projectedUse ?? 0)) }
  public var runsOut: Bool { projectedEnd < reset }

  /// Remaining on an even pace at `date`.
  public func idealRemaining(at date: Date) -> Double {
    max(0, min(100, 100 * (1 - date.timeIntervalSince(start) / duration)))
  }

  /// Remaining minus even pace at the reading, in percentage points.
  public var paceDelta: Double { remaining - idealRemaining(at: observedAt) }
}

public struct QuotaSample: Codable, Equatable, Sendable {
  public var date: Date
  public var remaining: Double

  public init(date: Date, remaining: Double) {
    self.date = date
    self.remaining = remaining
  }
}

public struct QuotaReset: Equatable, Sendable {
  public var date: Date
  /// Near the end of one window and the start of the next, rather than a
  /// mid-window jump (a manual reset or a provider correction).
  public var scheduled: Bool
}

// MARK: - History

/// Readings over time, used for the quota charts, reset detection and the
/// over-count filter. Holds only percentages and times.
///
/// The cycle and over-count rules follow Agent Burn's `QuotaHistory`
/// (https://github.com/Melvynx/agent-burn, MIT).
public struct QuotaHistory: Codable, Equatable, Sendable {
  public static let version = 1
  public static let retention: TimeInterval = 120 * 86_400

  public var version = QuotaHistory.version
  public var readings: [String: [QuotaReading]] = [:]

  public init() {}

  public func all(_ series: QuotaSeries) -> [QuotaReading] { readings[series.rawValue] ?? [] }

  public func latest(_ series: QuotaSeries) -> QuotaReading? { all(series).last }

  /// Adds a reading that is newer than the latest one for its series.
  @discardableResult
  public mutating func record(_ reading: QuotaReading, series: QuotaSeries) -> Bool {
    guard reading.isValid,
      reading.observedAt > (latest(series)?.observedAt ?? .distantPast)
    else { return false }
    readings[series.rawValue, default: []].append(reading)
    return true
  }

  public mutating func prune(now: Date) {
    let cutoff = now.addingTimeInterval(-Self.retention)
    for (key, list) in readings {
      readings[key] = Array(list.drop { $0.observedAt < cutoff }.suffix(50_000))
    }
  }

  /// The newest reading safe to show: the last consistent one, so neither an
  /// unconfirmed over-count nor a replay of a superseded window.
  public func current(_ series: QuotaSeries) -> QuotaReading? { consistent(series).last }

  private static func isRecent(_ reading: QuotaReading, to newest: QuotaReading) -> Bool {
    newest.observedAt.timeIntervalSince(reading.observedAt) <= 1800
      && abs(reading.windowStart.timeIntervalSince(newest.windowStart)) <= 300
  }

  private static func isOverCount(_ reading: QuotaReading, floor: Double) -> Bool {
    reading.windowMinutes >= 2 * 24 * 60 && reading.usedPercent > floor * 1.5 + 3
  }

  /// Readings without replays of superseded windows or over-counts. Usage
  /// never falls within one window, so a later, lower reading of the same
  /// window proves the higher ones before it were over-counts.
  public func consistent(_ series: QuotaSeries) -> [QuotaReading] {
    var kept: [(reading: QuotaReading, segment: Int)] = []
    var starts: [Date] = []
    for reading in all(series) {
      let start = reading.windowStart
      if let last = starts.last, abs(start.timeIntervalSince(last)) <= 300 {
        kept.append((reading, starts.count - 1))
      } else if starts.contains(where: { abs(start.timeIntervalSince($0)) <= 300 }) {
        continue
      } else {
        starts.append(start)
        kept.append((reading, starts.count - 1))
      }
    }
    var lowestLater: [Int: Double] = [:]
    var consistent: [QuotaReading] = []
    for (reading, segment) in kept.reversed() {
      if let floor = lowestLater[segment], reading.usedPercent > floor + 1 { continue }
      lowestLater[segment] = min(reading.usedPercent, lowestLater[segment] ?? reading.usedPercent)
      consistent.append(reading)
    }
    var chronological = Array(consistent.reversed())
    if let newest = chronological.last,
      let floor = consistent.prefix(while: { Self.isRecent($0, to: newest) }).map(\.usedPercent).min()
    {
      while let last = chronological.last, Self.isOverCount(last, floor: floor) {
        chronological.removeLast()
      }
    }
    return chronological
  }

  public func samples(_ series: QuotaSeries) -> [QuotaSample] { Self.samples(consistent(series)) }

  public static func samples(_ points: [QuotaReading]) -> [QuotaSample] {
    points.map { QuotaSample(date: $0.observedAt, remaining: $0.remaining) }
  }

  public func resets(_ series: QuotaSeries) -> [QuotaReset] { Self.resets(consistent(series)) }

  /// Jumps in remaining between consecutive consistent readings.
  public static func resets(_ points: [QuotaReading]) -> [QuotaReset] {
    var found: [QuotaReset] = []
    for (previous, reading) in zip(points, points.dropFirst())
    where reading.remaining > previous.remaining + 1 {
      let newWindow = reading.windowStart.timeIntervalSince(previous.windowStart) > 300
      found.append(QuotaReset(date: reading.observedAt, scheduled: newWindow))
    }
    return found
  }
}

/// `quota-history.json` (+ `.bak`) next to the usage cache. The app and the
/// background collector both write it, so commits merge under a file lock.
public struct QuotaHistoryFile: Sendable {
  public let directory: URL
  public var url: URL { directory.appendingPathComponent("quota-history.json") }
  public var backupURL: URL { directory.appendingPathComponent("quota-history.json.bak") }
  private var lockURL: URL { directory.appendingPathComponent("quota-history.lock") }

  public init(directory: URL) {
    self.directory = directory
  }

  public static var standard: QuotaHistoryFile { QuotaHistoryFile(directory: SnapshotCache.standard.directory) }

  public func load() -> QuotaHistory? {
    for candidate in [url, backupURL] {
      guard let data = try? Data(contentsOf: candidate),
        let history = try? Self.decoder.decode(QuotaHistory.self, from: data),
        history.version == QuotaHistory.version
      else { continue }
      return history
    }
    return nil
  }

  /// Merges readings into the latest history on disk and saves it.
  @discardableResult
  public func commit(_ readings: [QuotaSeries: QuotaReading], now: Date = .now) throws -> QuotaHistory {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
    defer { close(descriptor) }
    flock(descriptor, LOCK_EX)
    defer { flock(descriptor, LOCK_UN) }
    var history = load() ?? QuotaHistory()
    var changed = false
    for series in QuotaSeries.allCases {
      if let reading = readings[series], history.record(reading, series: series) { changed = true }
    }
    guard changed else { return history }
    history.prune(now: now)
    let data = try Self.encoder.encode(history)
    if let current = try? Data(contentsOf: url),
      (try? Self.decoder.decode(QuotaHistory.self, from: current)) != nil
    {
      try current.write(to: backupURL, options: .atomic)
    }
    try data.write(to: url, options: .atomic)
    return history
  }

  private static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    return encoder
  }

  private static var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    return decoder
  }
}
