import Foundation

/// Deterministic, clearly fake usage for screenshots and UI checks.
///
/// Only used when Burnless is started with `--demo` (or `BURNLESS_DEMO=1`);
/// the app labels it as demo data and never writes it to the cache.
public enum DemoData {
  public static func snapshot(now: Date, days calendar: DayCalendar) -> UsageSnapshot {
    var generator = SeededGenerator(seed: 42)
    var rows: [UsageRow] = []
    let today = calendar.key(now)
    let claudeModels = ["demo-claude-opus", "demo-claude-sonnet", "demo-claude-haiku"]
    let codexModels = ["demo-gpt-large", "demo-gpt-mini"]
    for offset in stride(from: -119, through: 0, by: 1) {
      guard let key = calendar.adding(days: offset, to: today) else { continue }
      let weekday = calendar.calendar.component(.weekday, from: calendar.date(key) ?? now)
      let weekend = weekday == 1 || weekday == 7
      if Double.random(in: 0...1, using: &generator) < (weekend ? 0.55 : 0.12) { continue }
      let scale = (weekend ? 0.4 : 1.0) * (0.6 + Double(120 + offset) / 120)
      for (index, model) in claudeModels.enumerated()
      where Double.random(in: 0...1, using: &generator) < [0.7, 0.9, 0.4][index] {
        let input = UInt64(Double.random(in: 2_000...40_000, using: &generator) * scale)
        let output = UInt64(Double.random(in: 20_000...180_000, using: &generator) * scale)
        let cacheRead = UInt64(Double.random(in: 2_000_000...18_000_000, using: &generator) * scale)
        let cacheWrite = UInt64(Double.random(in: 100_000...900_000, using: &generator) * scale)
        let rate = [15.0, 3.0, 1.0][index]
        let cost =
          (Double(input) * rate + Double(output) * rate * 5 + Double(cacheRead) * rate * 0.1
            + Double(cacheWrite) * rate * 1.25) / 1_000_000
        rows.append(
          UsageRow(
            source: .claude, date: key, model: model, inputTokens: input, outputTokens: output,
            cacheWriteTokens: cacheWrite, cacheReadTokens: cacheRead, costUSD: cost,
            costBreakdown: CostBreakdown(
              input: Double(input) * rate / 1_000_000, output: Double(output) * rate * 5 / 1_000_000,
              cacheWrite: Double(cacheWrite) * rate * 1.25 / 1_000_000,
              cacheRead: Double(cacheRead) * rate * 0.1 / 1_000_000)))
      }
      for (index, model) in codexModels.enumerated()
      where Double.random(in: 0...1, using: &generator) < [0.75, 0.35][index] {
        let input = UInt64(Double.random(in: 200_000...2_500_000, using: &generator) * scale)
        let cacheRead = UInt64(Double(input) * Double.random(in: 3...12, using: &generator))
        let output = UInt64(Double.random(in: 20_000...160_000, using: &generator) * scale)
        let rate = [1.25, 0.25][index]
        let cost =
          (Double(input) * rate + Double(cacheRead) * rate * 0.1 + Double(output) * rate * 8)
          / 1_000_000
        rows.append(
          UsageRow(
            source: .codex, date: key, model: model, inputTokens: input, outputTokens: output,
            cacheReadTokens: cacheRead, reasoningTokens: output / 3, costUSD: cost,
            costBreakdown: CostBreakdown(
              input: Double(input) * rate / 1_000_000, output: Double(output) * rate * 8 / 1_000_000,
              cacheRead: Double(cacheRead) * rate * 0.1 / 1_000_000)))
      }
    }
    // One unpriced model so partial-estimate states are visible in demos.
    if let key = calendar.adding(days: -3, to: today) {
      rows.append(
        UsageRow(
          source: .codex, date: key, model: "demo-unpriced-model", inputTokens: 120_000,
          outputTokens: 8_000, missingPricing: true))
    }
    let sources = Harness.allCases.map { harness in
      SourceSnapshot(
        status: SourceStatus(id: harness, state: .ok, paths: ["Demo data"]), lastSuccess: now,
        isStale: false)
    }
    let images = (0..<10).compactMap { offset -> ImageDay? in
      guard offset % 3 == 0, let key = calendar.adding(days: -offset, to: today) else { return nil }
      return ImageDay(date: key, count: 2 + offset / 3)
    }
    return UsageSnapshot(
      rows: rows, sources: sources,
      pricing: PricingInfo(
        provider: "Demo prices", ccusageRevision: "demo", litellmRevision: "demo",
        snapshotDate: "demo", online: false),
      refreshedAt: now, timezone: calendar.calendar.timeZone.identifier, isDemo: true,
      codexImages: images)
  }
}

extension DemoData {
  /// Plans, limit meters and a few days of readings, all generated.
  public static func quota(now: Date) -> (report: QuotaReport, history: QuotaHistory) {
    var generator = SeededGenerator(seed: 7)
    let ms = { (date: Date) in date.timeIntervalSince1970 * 1000 }
    let hour: TimeInterval = 3600
    let claudeReset = now.addingTimeInterval(3.6 * 86_400)
    let sessionReset = now.addingTimeInterval(2.3 * hour)
    let codexReset = now.addingTimeInterval(2.9 * 86_400)
    var history = QuotaHistory()

    /// Readings every `step` from the window start, following `curve` (0...1 of
    /// the final value) with small random wobble.
    func record(
      _ series: QuotaSeries, reset: Date, minutes: Double, used: Double, step: TimeInterval,
      curve: (Double) -> Double
    ) {
      let start = reset.addingTimeInterval(-minutes * 60)
      var time = start.addingTimeInterval(step)
      var last = 0.0
      while time <= now {
        let progress = time.timeIntervalSince(start) / now.timeIntervalSince(start)
        let value = min(100, max(last, used * curve(progress) + Double.random(in: 0...0.6, using: &generator)))
        last = value
        history.record(
          QuotaReading(observedAt: time, usedPercent: value, windowMinutes: minutes, resetsAt: reset, source: "live"),
          series: series)
        time = time.addingTimeInterval(step)
      }
      history.record(
        QuotaReading(observedAt: now, usedPercent: used, windowMinutes: minutes, resetsAt: reset, source: "live"),
        series: series)
    }

    record(.claudeWeekly, reset: claudeReset, minutes: 10080, used: 38, step: hour) { pow($0, 1.3) }
    record(.claudeSession, reset: sessionReset, minutes: 300, used: 62, step: 600) { pow($0, 0.8) }
    record(.codexWeekly, reset: codexReset, minutes: 10080, used: 64, step: hour) { $0 < 0.5 ? $0 * 0.7 : 0.35 + ($0 - 0.5) * 1.3 }

    let days = (0..<7).reversed().compactMap { offset -> LimitUsageDay? in
      let date = now.addingTimeInterval(-Double(offset) * 86_400)
      let parts = date.formatted(.iso8601.year().month().day())
      let cli = Double.random(in: 2...9, using: &generator)
      let desktop = Double.random(in: 0...5, using: &generator)
      let web = Double.random(in: 0...2, using: &generator)
      return LimitUsageDay(
        date: parts, usedPercent: cli + desktop + web,
        surfaces: [
          LimitUsageSurface(surface: "cli", usedPercent: cli),
          LimitUsageSurface(surface: "desktop_app", usedPercent: desktop),
          LimitUsageSurface(surface: "web", usedPercent: web),
        ],
        models: [
          LimitUsageModel(model: "demo-gpt-large", speed: "standard", usedPercent: cli + web),
          LimitUsageModel(model: "demo-gpt-mini", speed: "standard", usedPercent: desktop),
        ])
    }
    let report = QuotaReport(
      generatedAtMs: ms(now),
      claude: ClaudeQuota(
        planTier: "default_claude_max_5x",
        account: ClaudeAccount(
          source: "live", observedAtMs: ms(now),
          session: LimitWindow(usedPercent: 62, windowMinutes: 300, resetsAtMs: ms(sessionReset)),
          weekly: LimitWindow(usedPercent: 38, windowMinutes: 10080, resetsAtMs: ms(claudeReset)),
          scoped: [ScopedLimit(name: "Demo Opus", usedPercent: 47, resetsAtMs: ms(claudeReset))],
          extra: ExtraUsage(enabled: true, usedUSD: 12.4, limitUSD: 50)),
        live: LiveStatus(state: .ok)),
      codex: CodexQuota(
        planType: "plus",
        snapshot: CodexSnapshot(
          source: "live", observedAtMs: ms(now),
          weekly: LimitWindow(usedPercent: 64, windowMinutes: 10080, resetsAtMs: ms(codexReset)),
          short: LimitWindow(usedPercent: 18, windowMinutes: 300, resetsAtMs: ms(now.addingTimeInterval(3 * hour))),
          resetCreditsAvailable: 1),
        limitUsageDaily: days, live: LiveStatus(state: .ok)))
    return (report, history)
  }
}

/// Small deterministic PRNG (SplitMix64) so demo data is identical each run.
struct SeededGenerator: RandomNumberGenerator {
  private var state: UInt64
  init(seed: UInt64) { state = seed }
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var value = state
    value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
    value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
    return value ^ (value >> 31)
  }
}
