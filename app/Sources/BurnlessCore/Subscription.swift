import Foundation

/// A subscription plan: the detected identifier, a display name and a
/// monthly price when it is known. Unknown prices stay `nil`, never 0.
public struct SubscriptionPlan: Equatable, Sendable {
  public var name: String?
  public var pricePerMonth: Double?
  /// Raw identifier from local files (Claude tier or Codex plan type), or
  /// the name typed in Settings (Gemini, which logs no plan).
  public var detected: String?
  /// The price comes from the user's override rather than the catalog.
  public var isOverride: Bool
  /// Override text that matched no plan and no price, so it was not applied.
  public var ignoredOverride: String?

  public init(
    name: String? = nil, pricePerMonth: Double? = nil, detected: String? = nil, isOverride: Bool = false,
    ignoredOverride: String? = nil
  ) {
    self.name = name
    self.pricePerMonth = pricePerMonth
    self.detected = detected
    self.isOverride = isOverride
    self.ignoredOverride = ignoredOverride
  }

  /// "Max 20× · $200/mo", "Team · price unknown", "Plan not detected".
  public var label: String {
    switch (name, pricePerMonth) {
    case (let name?, let price?): "\(name) · \(Format.currency(price, wholeDollars: true))/mo"
    case (let name?, nil): "\(name) · price unknown"
    case (nil, let price?): "\(Format.currency(price, wholeDollars: true))/mo"
    case (nil, nil): "Plan not detected"
    }
  }
}

/// Published monthly prices, as in Agent Burn's plan table.
public enum PlanCatalog {
  public static func claude(tier: String?) -> SubscriptionPlan {
    guard let tier, !tier.isEmpty else { return SubscriptionPlan() }
    // Normalized so typed names like "Max 20" or "max_20" match too.
    let value = normalized(tier)
    let known: (String, Double)? =
      value.contains("20x") || value.contains("max20") ? ("Max 20×", 200)
      : value.contains("5x") || value.contains("max5") ? ("Max 5×", 100)
      : value.contains("max") ? ("Max", 100)
      : value.contains("pro") ? ("Pro", 20)
      : nil
    if let known { return SubscriptionPlan(name: known.0, pricePerMonth: known.1, detected: tier) }
    return SubscriptionPlan(name: readable(tier), detected: tier)
  }

  public static func codex(planType: String?) -> SubscriptionPlan {
    guard let planType, !planType.isEmpty else { return SubscriptionPlan() }
    switch normalized(planType) {
    case "plus": return SubscriptionPlan(name: "Plus", pricePerMonth: 20, detected: planType)
    case "pro": return SubscriptionPlan(name: "Pro", pricePerMonth: 200, detected: planType)
    // `prolite` is the $100 Pro tier (5× Plus on Codex), launched April 2026.
    case "prolite": return SubscriptionPlan(name: "Pro 5×", pricePerMonth: 100, detected: planType)
    default: return SubscriptionPlan(name: readable(planType), detected: planType)
    }
  }

  /// Google AI plans that include Gemini CLI. Gemini CLI writes no plan to
  /// disk, so this only resolves a name entered in Settings.
  public static func gemini(plan: String?) -> SubscriptionPlan {
    guard let plan, !plan.isEmpty else { return SubscriptionPlan() }
    switch normalized(plan).replacingOccurrences(of: "googleai", with: "").replacingOccurrences(of: "gemini", with: "") {
    case "plus": return SubscriptionPlan(name: "Google AI Plus", pricePerMonth: 4.99)
    case "pro": return SubscriptionPlan(name: "Google AI Pro", pricePerMonth: 19.99)
    case "ultra": return SubscriptionPlan(name: "Google AI Ultra", pricePerMonth: 249.99)
    default: return SubscriptionPlan()
    }
  }

  /// Applies a user override: a monthly price (`200`, `$20`) or a known plan
  /// name (`max-20x`, `pro`, `plus`). Any other text keeps the detected plan
  /// and is reported in `ignoredOverride`, so a typo never hides it.
  public static func apply(_ override: String, to plan: SubscriptionPlan, harness: Harness)
    -> SubscriptionPlan
  {
    let text = override.trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { return plan }
    if let price = Double(text.replacingOccurrences(of: "$", with: "")), price > 0, price.isFinite {
      return SubscriptionPlan(
        name: plan.name, pricePerMonth: price, detected: plan.detected, isOverride: true)
    }
    var named =
      switch harness {
      case .claude: claude(tier: text)
      case .codex: codex(planType: text)
      case .gemini: gemini(plan: text)
      }
    let known =
      switch harness {
      case .claude, .gemini: named.pricePerMonth != nil
      case .codex: ["plus", "pro", "prolite"].contains(normalized(text))
      }
    guard known else {
      var kept = plan
      kept.ignoredOverride = text
      return kept
    }
    named.detected = plan.detected
    named.isOverride = true
    return named
  }

  static func normalized(_ value: String) -> String {
    value.lowercased().filter { $0.isLetter || $0.isNumber }
  }

  /// `default_claude_team` → `Team`, `enterprise` → `Enterprise`.
  static func readable(_ value: String) -> String {
    let words = value.split { $0 == "_" || $0 == "-" || $0 == " " }
      .filter { !["default", "claude"].contains($0.lowercased()) }
    let text = words.map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined(separator: " ")
    return text.isEmpty ? value : text
  }
}

/// Token class of a cost.
public enum TokenClass: String, CaseIterable, Identifiable, Sendable {
  case input, output, cacheWrite, cacheRead

  public var id: String { rawValue }
  public var label: String {
    switch self {
    case .input: "Input"
    case .output: "Output"
    case .cacheWrite: "Cache write"
    case .cacheRead: "Cache read"
    }
  }
}

public struct SpendCategory: Identifiable, Equatable, Sendable {
  public var kind: TokenClass
  public var tokens: UInt64
  public var cost: Double
  public var costShare: Double
  public var tokenShare: Double
  public var id: TokenClass { kind }
}

public struct WeekSpend: Identifiable, Equatable, Sendable {
  public var start: Date
  public var key: String
  public var cost: Double
  public var id: String { key }
}

/// Subscription value of a harness, from local usage and the plan price.
public struct SubscriptionValue: Equatable, Sendable {
  /// API-equivalent spend over the last 30 days.
  public var apiEquivalent: SpendTotals
  public var plan: SubscriptionPlan

  /// API-equivalent value divided by what the plan costs.
  public var valueMultiple: Double? {
    guard let price = plan.pricePerMonth, price > 0, apiEquivalent.cost > 0 else { return nil }
    return apiEquivalent.cost / price
  }
  /// API-equivalent value minus the plan price.
  public var subsidy: Double? { plan.pricePerMonth.map { apiEquivalent.cost - $0 } }
  /// How much cheaper the plan is than paying API prices for the same usage.
  public var discountPercent: Double? {
    guard let price = plan.pricePerMonth, apiEquivalent.cost > 0 else { return nil }
    return max(0, 1 - price / apiEquivalent.cost) * 100
  }
}

/// What a full limit window is worth at API prices, extrapolated from the
/// current window's spend and used share.
public struct QuotaValueEstimate: Equatable, Sendable {
  public static let daysPerMonth = 30.4375

  public var cycleSpend: Double
  public var cycleTokens: UInt64
  public var fullQuotaValue: Double
  public var monthlyValue: Double
  /// Usage at reset at the current pace, capped at 999%.
  public var projectedUsePercent: Double
  public var valueMultiple: Double?
  /// API-equivalent dollars per percent of the limit.
  public var dollarsPerPercent: Double
  public var tokensPerPercent: Double?
  public var tokensPerDollar: Double?

  public static func make(
    cycleSpend: Double, cycleTokens: UInt64, forecast: Forecast, price: Double?
  ) -> QuotaValueEstimate? {
    guard forecast.usedPercent > 0, forecast.elapsed > 0, cycleSpend > 0 else { return nil }
    let windowDays = forecast.duration / 86_400
    let full = cycleSpend / (forecast.usedPercent / 100)
    let monthly = full * (daysPerMonth / windowDays)
    return QuotaValueEstimate(
      cycleSpend: cycleSpend, cycleTokens: cycleTokens, fullQuotaValue: full,
      monthlyValue: monthly,
      projectedUsePercent: min(999, forecast.usedPercent / forecast.elapsed),
      valueMultiple: price.flatMap { $0 > 0 ? monthly / $0 : nil },
      dollarsPerPercent: cycleSpend / forecast.usedPercent,
      tokensPerPercent: cycleTokens > 0 ? Double(cycleTokens) / forecast.usedPercent : nil,
      tokensPerDollar: cycleTokens > 0 ? Double(cycleTokens) / cycleSpend : nil)
  }
}

public enum SubscriptionMath {
  public static let imagePriceEstimate = 0.15

  static func rows(_ snapshot: UsageSnapshot?, _ harness: Harness) -> [UsageRow] {
    (snapshot?.rows ?? []).filter { $0.source == harness }
  }

  /// Totals over the last `days` days, today included.
  public static func trailing(
    _ snapshot: UsageSnapshot?, harness: Harness, days: Int = 30, now: Date, calendar: DayCalendar
  ) -> SpendTotals {
    let today = calendar.key(now)
    let lower = calendar.adding(days: -(days - 1), to: today) ?? today
    var totals = SpendTotals()
    for row in rows(snapshot, harness) where row.date >= lower && row.date <= today {
      totals.add(row)
    }
    return totals
  }

  public static func value(
    _ snapshot: UsageSnapshot?, harness: Harness, plan: SubscriptionPlan, now: Date,
    calendar: DayCalendar
  ) -> SubscriptionValue {
    SubscriptionValue(
      apiEquivalent: trailing(snapshot, harness: harness, now: now, calendar: calendar), plan: plan)
  }

  /// Spend split by token class over the last `days` days. Rows from older
  /// caches without a split fall back to token weights.
  public static func spendMix(
    _ snapshot: UsageSnapshot?, harness: Harness, days: Int = 30, now: Date, calendar: DayCalendar
  ) -> [SpendCategory] {
    let today = calendar.key(now)
    let lower = calendar.adding(days: -(days - 1), to: today) ?? today
    var tokens: [TokenClass: UInt64] = [:]
    var costs: [TokenClass: Double] = [:]
    for row in rows(snapshot, harness) where row.date >= lower && row.date <= today {
      let counts: [TokenClass: UInt64] = [
        .input: row.inputTokens, .output: row.outputTokens, .cacheWrite: row.cacheWriteTokens,
        .cacheRead: row.cacheReadTokens,
      ]
      for (kind, count) in counts { tokens[kind, default: 0] += count }
      if let split = row.costBreakdown {
        costs[.input, default: 0] += split.input
        costs[.output, default: 0] += split.output
        costs[.cacheWrite, default: 0] += split.cacheWrite
        costs[.cacheRead, default: 0] += split.cacheRead
      } else if row.totalTokens > 0 {
        for (kind, count) in counts {
          costs[kind, default: 0] += row.costUSD * Double(count) / Double(row.totalTokens)
        }
      }
    }
    let totalCost = costs.values.reduce(0, +)
    let totalTokens = tokens.values.reduce(0, +)
    return TokenClass.allCases.compactMap { kind in
      let count = tokens[kind] ?? 0
      let cost = costs[kind] ?? 0
      guard count > 0 || cost > 0 else { return nil }
      return SpendCategory(
        kind: kind, tokens: count, cost: cost,
        costShare: totalCost > 0 ? cost / totalCost : 0,
        tokenShare: totalTokens > 0 ? Double(count) / Double(totalTokens) : 0)
    }
  }

  /// Spend per ISO week (Monday start) over the last `weeks` weeks.
  public static func weeklyTrend(
    _ snapshot: UsageSnapshot?, harness: Harness, weeks: Int = 8, now: Date, calendar: DayCalendar
  ) -> [WeekSpend] {
    let cal = calendar.calendar
    guard let thisWeek = cal.dateInterval(of: .weekOfYear, for: now)?.start else { return [] }
    let starts = (0..<weeks).reversed().compactMap {
      cal.date(byAdding: .weekOfYear, value: -$0, to: thisWeek)
    }
    var costs: [String: Double] = [:]
    for row in rows(snapshot, harness) {
      guard let day = calendar.date(row.date),
        let start = cal.dateInterval(of: .weekOfYear, for: day)?.start
      else { continue }
      costs[calendar.key(start), default: 0] += row.costUSD
    }
    return starts.map { start in
      let key = calendar.key(start)
      return WeekSpend(start: start, key: key, cost: costs[key] ?? 0)
    }
  }

  /// Spend and tokens since a window start, prorating the first day by the
  /// share of it the window covers (daily rows carry no time of day).
  public static func cycleSpend(
    _ snapshot: UsageSnapshot?, harness: Harness, since start: Date, now: Date, calendar: DayCalendar
  ) -> (cost: Double, tokens: UInt64) {
    let firstKey = calendar.key(start)
    let dayStart = calendar.calendar.startOfDay(for: start)
    let dayEnd = calendar.calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
    let span = dayEnd.timeIntervalSince(dayStart)
    let fraction = span > 0 ? max(0, min(1, dayEnd.timeIntervalSince(start) / span)) : 1
    var cost = 0.0
    var tokens = 0.0
    for row in rows(snapshot, harness) where row.date >= firstKey && row.date <= calendar.key(now) {
      let weight = row.date == firstKey ? fraction : 1
      cost += row.costUSD * weight
      tokens += Double(row.totalTokens) * weight
    }
    return (cost, UInt64(tokens.rounded()))
  }

  /// Daily spend from a window start through today, one point per day.
  public static func cycleDays(
    _ snapshot: UsageSnapshot?, harness: Harness, since start: Date, now: Date, calendar: DayCalendar
  ) -> [(key: String, date: Date, cost: Double)] {
    var costs: [String: Double] = [:]
    for row in rows(snapshot, harness) { costs[row.date, default: 0] += row.costUSD }
    return calendar.keys(from: calendar.key(start), through: calendar.key(now)).compactMap { key in
      calendar.date(key).map { (key, $0, costs[key] ?? 0) }
    }
  }

  public static func imageCount(_ snapshot: UsageSnapshot?) -> Int? {
    snapshot?.codexImages.map { $0.reduce(0) { $0 + $1.count } }
  }
}
