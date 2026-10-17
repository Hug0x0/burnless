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
            cacheWriteTokens: cacheWrite, cacheReadTokens: cacheRead, costUSD: cost))
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
            cacheReadTokens: cacheRead, reasoningTokens: output / 3, costUSD: cost))
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
    return UsageSnapshot(
      rows: rows, sources: sources,
      pricing: PricingInfo(
        provider: "Demo prices", ccusageRevision: "demo", litellmRevision: "demo",
        snapshotDate: "demo", online: false),
      refreshedAt: now, timezone: calendar.calendar.timeZone.identifier, isDemo: true)
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
