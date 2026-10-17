import Foundation

/// Spend periods, in Agent Burn's order.
public enum Period: String, CaseIterable, Identifiable, Sendable {
  case today, yesterday, sinceReset, weekToDate, thisMonth, last7, last30, yearToDate, allTime

  public var id: String { rawValue }

  public var label: String {
    switch self {
    case .today: "Today"
    case .yesterday: "Yesterday"
    case .sinceReset: "Reset to date"
    case .weekToDate: "Week to date"
    case .thisMonth: "This month"
    case .last7: "Last 7 days"
    case .last30: "Last 30 days"
    case .yearToDate: "Year to date"
    case .allTime: "All time"
    }
  }
}

/// Calendar days as `YYYY-MM-DD` keys in one timezone, which is the same
/// timezone the engine used to group events.
public struct DayCalendar: Sendable {
  public let calendar: Calendar

  public init(timeZone: TimeZone = .current) {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    calendar.locale = Locale(identifier: "en_US_POSIX")
    // ISO weeks start on Monday.
    calendar.firstWeekday = 2
    calendar.minimumDaysInFirstWeek = 4
    self.calendar = calendar
  }

  public func key(_ date: Date) -> String {
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
  }

  /// Start of the given day in this calendar's timezone.
  public func date(_ key: String) -> Date? {
    let parts = key.split(separator: "-")
    guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]),
      let day = Int(parts[2])
    else { return nil }
    guard let noon = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))
    else { return nil }
    return calendar.startOfDay(for: noon)
  }

  public func adding(days: Int, to key: String) -> String? {
    guard let start = date(key), let next = calendar.date(byAdding: .day, value: days, to: start)
    else { return nil }
    return self.key(next)
  }

  /// Every day key from `lower` through `upper`, inclusive. Steps by calendar
  /// day, so 23- and 25-hour DST days still produce exactly one key each.
  public func keys(from lower: String, through upper: String) -> [String] {
    guard let start = date(lower), lower <= upper else { return [] }
    var keys: [String] = []
    var offset = 0
    while let next = calendar.date(byAdding: .day, value: offset, to: start) {
      let key = self.key(next)
      if key > upper { break }
      keys.append(key)
      offset += 1
      if offset > 366 * 50 { break }
    }
    return keys
  }
}

public struct TokenBreakdown: Equatable, Sendable {
  public var input: UInt64 = 0
  public var output: UInt64 = 0
  public var cacheWrite: UInt64 = 0
  public var cacheRead: UInt64 = 0
  public var reasoning: UInt64 = 0

  public init() {}

  public var total: UInt64 { input + output + cacheWrite + cacheRead }

  mutating func add(_ row: UsageRow) {
    input += row.inputTokens
    output += row.outputTokens
    cacheWrite += row.cacheWriteTokens
    cacheRead += row.cacheReadTokens
    reasoning += row.reasoningTokens
  }
}

/// Spend of a set of rows. `cost` is the valued part; `unpricedTokens`
/// counts usage the pricing data could not value, which makes `cost` a
/// partial estimate whenever it is above zero.
public struct SpendTotals: Equatable, Sendable {
  public var cost: Double = 0
  public var tokens = TokenBreakdown()
  public var unpricedTokens: UInt64 = 0

  public init() {}

  public var isPartial: Bool { unpricedTokens > 0 }

  mutating func add(_ row: UsageRow) {
    cost += row.costUSD
    tokens.add(row)
    if row.missingPricing { unpricedTokens += row.totalTokens }
  }
}

public struct DayPoint: Identifiable, Equatable, Sendable {
  public var key: String
  public var date: Date
  public var costs: [Harness: Double]
  public var totals: SpendTotals
  /// No source in scope had been read for this day (for example, days after
  /// a stale source's last successful read). Distinct from a day with no use.
  public var isUnknown: Bool

  public var id: String { key }
  public var cost: Double { totals.cost }
}

public struct HarnessSummary: Identifiable, Equatable, Sendable {
  public var harness: Harness
  public var totals: SpendTotals
  public var availability: SourceAvailability
  public var id: Harness { harness }
}

public struct ModelSummary: Identifiable, Equatable, Sendable {
  /// Stable identity: the model name, or `unattributed:<source>`.
  public var id: String
  /// `nil` for usage the source logged without a model.
  public var model: String?
  public var harnesses: [Harness]
  public var totals: SpendTotals
  /// Part of total cost in the selected scope, before any text search.
  public var share: Double
  public var hasInferredModel: Bool

  public var displayName: String {
    if let model { return model }
    return "Unattributed" + (harnesses.count == 1 ? " (\(harnesses[0].name))" : "")
  }
  public var cost: Double { totals.cost }
  public var tokenCount: UInt64 { totals.tokens.total }
}

/// Everything the dashboard shows for one harness filter and period.
public struct Dashboard: Equatable, Sendable {
  public var harness: Harness?
  public var period: Period
  public var lowerKey: String
  public var upperKey: String
  public var totals: SpendTotals
  /// Distinct days with recorded usage over all available history, for the
  /// selected harness (or the union of both). Independent of `period`.
  public var daysRecorded: Int
  public var days: [DayPoint]
  public var harnesses: [HarnessSummary]
  public var models: [ModelSummary]
  /// Sources in scope that currently contribute no data.
  public var unavailable: [Harness]
  /// Sources in scope shown from an older successful read.
  public var stale: [Harness]

  public var scope: [Harness] { harness.map { [$0] } ?? Harness.allCases }
  public var hasAnyHistory: Bool { daysRecorded > 0 }
  public var hasUsageInPeriod: Bool { totals.tokens.total > 0 || totals.cost > 0 }
  public var unattributedTokens: UInt64 {
    models.filter { $0.model == nil }.reduce(0) { $0 + $1.tokenCount }
  }
  public var hasInferredModels: Bool { models.contains { $0.hasInferredModel } }

  /// `resetStart` is the start of the current limit window, used by
  /// `sinceReset`; without one that period falls back to the last 7 days.
  public static func compute(
    snapshot: UsageSnapshot?, harness: Harness?, period: Period, now: Date,
    days calendar: DayCalendar, resetStart: Date? = nil
  ) -> Dashboard {
    let scope = harness.map { [$0] } ?? Harness.allCases
    let rows = (snapshot?.rows ?? []).filter { scope.contains($0.source) }
    let today = calendar.key(now)

    let recorded = Set(rows.filter { $0.totalTokens > 0 || $0.costUSD > 0 }.map(\.date))
    let lower: String
    var upper = today
    switch period {
    case .today: lower = today
    case .yesterday:
      lower = calendar.adding(days: -1, to: today) ?? today
      upper = lower
    case .sinceReset:
      lower = resetStart.map { min(calendar.key($0), today) } ?? calendar.adding(days: -6, to: today) ?? today
    case .weekToDate:
      lower = calendar.calendar.dateInterval(of: .weekOfYear, for: now).map { calendar.key($0.start) } ?? today
    case .thisMonth: lower = String(today.prefix(7)) + "-01"
    case .last7: lower = calendar.adding(days: -6, to: today) ?? today
    case .last30: lower = calendar.adding(days: -29, to: today) ?? today
    case .yearToDate: lower = String(today.prefix(4)) + "-01-01"
    case .allTime:
      lower = min(recorded.min() ?? today, today)
      // Rows dated after today (a clock change) stay visible in All time only.
      upper = max(recorded.max() ?? today, today)
    }
    let inRange = rows.filter { $0.date >= lower && $0.date <= upper }

    // Days after a stale source's last read are unknown, not idle.
    var knownThrough: [Harness: String] = [:]
    var unavailable: [Harness] = []
    var stale: [Harness] = []
    for source in scope {
      switch snapshot?.availability(source) ?? .failed("Not read yet") {
      case .live: knownThrough[source] = upper
      case .stale(let lastSuccess, _):
        knownThrough[source] = calendar.key(lastSuccess)
        stale.append(source)
      case .notFound, .failed: unavailable.append(source)
      }
    }

    var totals = SpendTotals()
    var byDay: [String: (costs: [Harness: Double], totals: SpendTotals)] = [:]
    var byHarness: [Harness: SpendTotals] = [:]
    var byModel: [String: (row: ModelSummary, harnesses: Set<Harness>)] = [:]
    for row in inRange {
      totals.add(row)
      byDay[row.date, default: ([:], SpendTotals())].costs[row.source, default: 0] += row.costUSD
      byDay[row.date, default: ([:], SpendTotals())].totals.add(row)
      byHarness[row.source, default: SpendTotals()].add(row)
      let id = row.model ?? "unattributed:\(row.source.rawValue)"
      var entry =
        byModel[id]
        ?? (
          ModelSummary(
            id: id, model: row.model, harnesses: [], totals: SpendTotals(), share: 0,
            hasInferredModel: false), []
        )
      entry.row.totals.add(row)
      entry.row.hasInferredModel = entry.row.hasInferredModel || row.inferredModel
      entry.harnesses.insert(row.source)
      byModel[id] = entry
    }

    let points = calendar.keys(from: lower, through: upper).compactMap { key -> DayPoint? in
      guard let date = calendar.date(key) else { return nil }
      let day = byDay[key]
      let known = scope.contains { source in knownThrough[source].map { key <= $0 } ?? false }
      return DayPoint(
        key: key, date: date, costs: day?.costs ?? [:], totals: day?.totals ?? SpendTotals(),
        isUnknown: !known && day == nil)
    }

    let harnesses = scope.map { source in
      HarnessSummary(
        harness: source, totals: byHarness[source] ?? SpendTotals(),
        availability: snapshot?.availability(source) ?? .failed("Not read yet"))
    }

    let models = byModel.values.map { entry -> ModelSummary in
      var summary = entry.row
      summary.harnesses = entry.harnesses.sorted()
      summary.share = totals.cost > 0 ? summary.totals.cost / totals.cost : 0
      return summary
    }
    .sorted { ($0.cost, $0.tokenCount, $1.id) > ($1.cost, $1.tokenCount, $0.id) }

    return Dashboard(
      harness: harness, period: period, lowerKey: lower, upperKey: upper, totals: totals,
      daysRecorded: recorded.count, days: points, harnesses: harnesses, models: models,
      unavailable: unavailable, stale: stale)
  }
}

public enum Granularity: String, CaseIterable, Identifiable, Sendable {
  case day, week, month

  public var id: String { rawValue }
  public var label: String {
    switch self {
    case .day: "Day"
    case .week: "Week"
    case .month: "Month"
    }
  }
  public var title: String {
    switch self {
    case .day: "Daily spend"
    case .week: "Weekly spend"
    case .month: "Monthly spend"
    }
  }

  /// Default for a span of days, as in Agent Burn.
  public static func automatic(days: Int) -> Granularity {
    if days > 182 { return .month }
    if days > 62 { return .week }
    return .day
  }
}

public struct SpendBucket: Identifiable, Equatable, Sendable {
  public var start: Date
  /// Exclusive end of the bucket.
  public var end: Date
  public var firstKey: String
  public var lastKey: String
  public var costs: [Harness: Double]
  public var totals: SpendTotals
  /// Every day in the bucket is unknown.
  public var isUnknown: Bool
  /// Some day in the bucket is unknown.
  public var hasUnknownDays: Bool

  public var id: String { firstKey }
  public var cost: Double { totals.cost }
}

public func spendBuckets(
  _ days: [DayPoint], granularity: Granularity, calendar: DayCalendar
) -> [SpendBucket] {
  let cal = calendar.calendar
  var buckets: [SpendBucket] = []
  for day in days {
    let start: Date
    let end: Date
    switch granularity {
    case .day:
      start = day.date
      end = cal.date(byAdding: .day, value: 1, to: start) ?? start
    case .week:
      let interval = cal.dateInterval(of: .weekOfYear, for: day.date)
      start = interval?.start ?? day.date
      end = interval?.end ?? day.date
    case .month:
      let interval = cal.dateInterval(of: .month, for: day.date)
      start = interval?.start ?? day.date
      end = interval?.end ?? day.date
    }
    if let last = buckets.last, last.start == start {
      var bucket = last
      bucket.lastKey = day.key
      for (source, cost) in day.costs { bucket.costs[source, default: 0] += cost }
      bucket.totals.cost += day.totals.cost
      bucket.totals.unpricedTokens += day.totals.unpricedTokens
      bucket.totals.tokens.input += day.totals.tokens.input
      bucket.totals.tokens.output += day.totals.tokens.output
      bucket.totals.tokens.cacheWrite += day.totals.tokens.cacheWrite
      bucket.totals.tokens.cacheRead += day.totals.tokens.cacheRead
      bucket.totals.tokens.reasoning += day.totals.tokens.reasoning
      bucket.isUnknown = bucket.isUnknown && day.isUnknown
      bucket.hasUnknownDays = bucket.hasUnknownDays || day.isUnknown
      buckets[buckets.count - 1] = bucket
    } else {
      buckets.append(
        SpendBucket(
          start: start, end: end, firstKey: day.key, lastKey: day.key, costs: day.costs,
          totals: day.totals, isUnknown: day.isUnknown, hasUnknownDays: day.isUnknown))
    }
  }
  return buckets
}
