import Foundation

/// What a source contributes to the dashboard right now.
public enum SourceAvailability: Equatable, Sendable {
  /// Read successfully on the latest refresh.
  case live
  /// The latest read failed; rows come from the last successful read.
  case stale(lastSuccess: Date, reason: String)
  /// No history folder exists at the configured or default location.
  case notFound
  /// The read failed and no earlier data exists.
  case failed(String)

  public var hasData: Bool {
    switch self {
    case .live, .stale: true
    case .notFound, .failed: false
    }
  }
}

public struct SourceSnapshot: Codable, Equatable, Sendable {
  public var status: SourceStatus
  /// Last time this source was read successfully.
  public var lastSuccess: Date?
  /// True when the rows kept for this source predate the latest status.
  public var isStale: Bool

  public var availability: SourceAvailability {
    if isStale, let lastSuccess {
      return .stale(lastSuccess: lastSuccess, reason: reason)
    }
    switch status.state {
    case .ok: return .live
    case .notFound: return .notFound
    case .error: return .failed(reason)
    }
  }

  private var reason: String {
    switch status.state {
    case .ok: "Up to date"
    case .notFound: "History folder not found"
    case .error: status.error ?? "History could not be read"
    }
  }
}

/// Merged, persisted state: the latest good rows for each source.
public struct UsageSnapshot: Codable, Equatable, Sendable {
  public static let cacheVersion = 1

  public var cacheVersion: Int
  public var rows: [UsageRow]
  public var sources: [SourceSnapshot]
  public var pricing: PricingInfo?
  public var refreshedAt: Date
  public var timezone: String?
  /// Set only for generated demonstration data, which is never cached.
  public var isDemo: Bool

  public init(
    rows: [UsageRow], sources: [SourceSnapshot], pricing: PricingInfo?, refreshedAt: Date,
    timezone: String?, isDemo: Bool = false
  ) {
    self.cacheVersion = Self.cacheVersion
    self.rows = rows
    self.sources = sources
    self.pricing = pricing
    self.refreshedAt = refreshedAt
    self.timezone = timezone
    self.isDemo = isDemo
  }

  public func source(_ harness: Harness) -> SourceSnapshot? {
    sources.first { $0.status.id == harness }
  }

  public func availability(_ harness: Harness) -> SourceAvailability {
    source(harness)?.availability ?? .failed("Not read yet")
  }

  /// Combines a fresh engine report with the previous snapshot.
  ///
  /// Each refresh replaces a source's rows wholesale (the engine always
  /// reports full history), so repeated refreshes can never duplicate usage.
  /// A source that fails or disappears keeps its last good rows, marked stale.
  public static func merging(
    _ report: EngineReport, previous: UsageSnapshot?, now: Date
  ) -> UsageSnapshot {
    var rows: [UsageRow] = []
    var sources: [SourceSnapshot] = []
    for harness in Harness.allCases {
      let status =
        report.sources.first { $0.id == harness }
        ?? SourceStatus(id: harness, state: .error, error: "Missing from the engine report")
      let fresh = report.rows.filter { $0.source == harness }
      let previousSource = previous?.source(harness)
      let previousRows = previous?.rows.filter { $0.source == harness } ?? []
      if status.state == .ok {
        rows += fresh
        sources.append(SourceSnapshot(status: status, lastSuccess: now, isStale: false))
      } else if !previousRows.isEmpty, let lastSuccess = previousSource?.lastSuccess {
        rows += previousRows
        sources.append(SourceSnapshot(status: status, lastSuccess: lastSuccess, isStale: true))
      } else {
        sources.append(SourceSnapshot(status: status, lastSuccess: nil, isStale: false))
      }
    }
    return UsageSnapshot(
      rows: rows, sources: sources, pricing: report.pricing, refreshedAt: now,
      timezone: report.timezone)
  }
}

/// Atomic JSON cache in `~/Library/Application Support/Burnless/`.
///
/// Holds only aggregated rows (dates, model names, token counts, costs);
/// never prompts or conversation text. The previous valid file is kept as
/// `.bak` and used if the main file is unreadable.
public struct SnapshotCache: Sendable {
  public let directory: URL
  public var fileURL: URL { directory.appendingPathComponent("usage-cache.json") }
  public var backupURL: URL { directory.appendingPathComponent("usage-cache.json.bak") }

  public init(directory: URL) {
    self.directory = directory
  }

  public static var standard: SnapshotCache {
    let base =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(
        "Library/Application Support")
    return SnapshotCache(directory: base.appendingPathComponent("Burnless", isDirectory: true))
  }

  public func load() -> UsageSnapshot? {
    for url in [fileURL, backupURL] {
      guard let data = try? Data(contentsOf: url),
        let snapshot = try? Self.decoder.decode(UsageSnapshot.self, from: data),
        snapshot.cacheVersion == UsageSnapshot.cacheVersion, !snapshot.isDemo
      else { continue }
      return snapshot
    }
    return nil
  }

  public func save(_ snapshot: UsageSnapshot) throws {
    guard !snapshot.isDemo else { return }
    let manager = FileManager.default
    try manager.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let data = try Self.encoder.encode(snapshot)
    // Keep the last file that decodes as the backup before replacing it.
    if let current = try? Data(contentsOf: fileURL),
      (try? Self.decoder.decode(UsageSnapshot.self, from: current)) != nil
    {
      try current.write(to: backupURL, options: .atomic)
    }
    try data.write(to: fileURL, options: .atomic)
  }

  private static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }

  private static var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
