import Foundation
import Testing

@testable import BurnlessCore

let paris = DayCalendar(timeZone: TimeZone(identifier: "Europe/Paris")!)
let testPricing = PricingInfo(
  provider: "test", ccusageRevision: "rev", litellmRevision: "rev", snapshotDate: "2026-10-17",
  online: false)

func at(_ iso: String) -> Date {
  try! Date(iso, strategy: .iso8601)
}

func snapshot(
  _ rows: [UsageRow], claude: SourceState = .ok, codex: SourceState = .ok, now: Date
) -> UsageSnapshot {
  let report = EngineReport(
    pricing: testPricing,
    sources: [SourceStatus(id: .claude, state: claude), SourceStatus(id: .codex, state: codex)],
    rows: rows)
  return UsageSnapshot.merging(report, previous: nil, now: now)
}

func row(
  _ source: Harness, _ date: String, _ model: String?, tokens: UInt64 = 100, cost: Double = 1,
  missing: Bool = false
) -> UsageRow {
  UsageRow(
    source: source, date: date, model: model, inputTokens: tokens / 2, outputTokens: tokens / 4,
    cacheWriteTokens: tokens / 8, cacheReadTokens: tokens - tokens / 2 - tokens / 4 - tokens / 8,
    costUSD: cost, missingPricing: missing)
}

@Suite struct PeriodTests {
  let now = at("2026-10-17T15:00:00+02:00")
  let rows = [
    row(.claude, "2026-10-17", "a"),
    row(.claude, "2026-10-11", "a"),
    row(.claude, "2026-10-10", "a"),
    row(.codex, "2026-10-01", "b"),
    row(.codex, "2026-09-18", "b"),
    row(.codex, "2026-09-17", "b"),
    row(.codex, "2026-01-05", "b"),
  ]

  func dashboard(_ period: Period, _ harness: Harness? = nil) -> Dashboard {
    Dashboard.compute(
      snapshot: snapshot(rows, now: now), harness: harness, period: period, now: now, days: paris)
  }

  @Test func rangesAreInclusiveOfToday() {
    #expect(dashboard(.today).days.map(\.key) == ["2026-10-17"])
    #expect(dashboard(.today).totals.cost == 1)
    #expect(dashboard(.last7).lowerKey == "2026-10-11")
    #expect(dashboard(.last7).days.count == 7)
    #expect(dashboard(.last7).totals.cost == 2)
    #expect(dashboard(.last30).lowerKey == "2026-09-18")
    #expect(dashboard(.last30).days.count == 30)
    #expect(dashboard(.last30).totals.cost == 5)
    #expect(dashboard(.thisMonth).lowerKey == "2026-10-01")
    #expect(dashboard(.thisMonth).totals.cost == 4)
    #expect(dashboard(.allTime).lowerKey == "2026-01-05")
    #expect(dashboard(.allTime).totals.cost == 7)
  }

  @Test func chronologyIsContinuousWithIdleDays() {
    let days = dashboard(.last30).days
    #expect(days.count == 30)
    #expect(days.filter { $0.cost > 0 }.count == 5)
    #expect(days.allSatisfy { !$0.isUnknown })
    #expect(zip(days, days.dropFirst()).allSatisfy { $0.key < $1.key })
  }

  @Test func daysRecordedIgnoresPeriodAndUsesUnion() {
    #expect(dashboard(.today).daysRecorded == 7)
    #expect(dashboard(.allTime).daysRecorded == 7)
    #expect(dashboard(.today, .claude).daysRecorded == 3)
    #expect(dashboard(.today, .codex).daysRecorded == 4)
  }

  @Test func daysRecordedCountsSharedDatesOnce() {
    let shared = [row(.claude, "2026-10-17", "a"), row(.codex, "2026-10-17", "b")]
    let result = Dashboard.compute(
      snapshot: snapshot(shared, now: now), harness: nil, period: .today, now: now, days: paris)
    #expect(result.daysRecorded == 1)
  }

  @Test func harnessFilterRestrictsEverything() {
    let codex = dashboard(.allTime, .codex)
    #expect(codex.totals.cost == 4)
    #expect(codex.models.map(\.id) == ["b"])
    #expect(codex.harnesses.map(\.harness) == [.codex])
    #expect(codex.days.allSatisfy { $0.costs[.claude] == nil })
  }
}

@Suite struct ConsistencyTests {
  let now = at("2026-10-17T12:00:00Z")

  @Test func chartCardsAndTableAgree() {
    let rows = [
      row(.claude, "2026-10-15", "opus", tokens: 1000, cost: 3.5),
      row(.claude, "2026-10-15", nil, tokens: 40, cost: 0, missing: true),
      row(.claude, "2026-10-16", "sonnet", tokens: 500, cost: 0.75),
      row(.codex, "2026-10-16", "gpt", tokens: 9000, cost: 2.25),
      row(.codex, "2026-10-17", "unknown-x", tokens: 70, cost: 0, missing: true),
    ]
    let result = Dashboard.compute(
      snapshot: snapshot(rows, now: now), harness: nil, period: .last7, now: now, days: paris)
    let chartCost = result.days.reduce(0) { $0 + $1.cost }
    let harnessCost = result.harnesses.reduce(0) { $0 + $1.totals.cost }
    let modelCost = result.models.reduce(0) { $0 + $1.cost }
    #expect(abs(chartCost - result.totals.cost) < 1e-9)
    #expect(abs(harnessCost - result.totals.cost) < 1e-9)
    #expect(abs(modelCost - result.totals.cost) < 1e-9)
    let modelTokens = result.models.reduce(UInt64(0)) { $0 + $1.tokenCount }
    let harnessTokens = result.harnesses.reduce(UInt64(0)) { $0 + $1.totals.tokens.total }
    #expect(modelTokens == result.totals.tokens.total)
    #expect(harnessTokens == result.totals.tokens.total)
    #expect(result.totals.tokens.total == 10_610)
    let shares = result.models.reduce(0) { $0 + $1.share }
    #expect(abs(shares - 1) < 1e-9)
  }

  @Test func unknownPricesMakeTotalsPartialInsteadOfZero() {
    let rows = [
      row(.codex, "2026-10-17", "priced", tokens: 100, cost: 2),
      row(.codex, "2026-10-17", "mystery", tokens: 50, cost: 0, missing: true),
    ]
    let result = Dashboard.compute(
      snapshot: snapshot(rows, now: now), harness: nil, period: .today, now: now, days: paris)
    #expect(result.totals.cost == 2)
    #expect(result.totals.isPartial)
    #expect(result.totals.unpricedTokens == 50)
    #expect(Format.spend(result.totals) == "$2.00+")
    let mystery = result.models.first { $0.id == "mystery" }!
    #expect(mystery.totals.isPartial)
    #expect(mystery.share == 0)
  }

  @Test func onlyUnpricedUsageStillShowsTokens() {
    let rows = [row(.codex, "2026-10-17", "mystery", tokens: 50, cost: 0, missing: true)]
    let result = Dashboard.compute(
      snapshot: snapshot(rows, now: now), harness: nil, period: .today, now: now, days: paris)
    #expect(result.hasUsageInPeriod)
    #expect(result.totals.isPartial)
    #expect(result.daysRecorded == 1)
  }

  @Test func unattributedUsageIsSeparatedPerSource() {
    let rows = [
      row(.claude, "2026-10-17", nil, tokens: 10, cost: 0, missing: true),
      row(.codex, "2026-10-17", nil, tokens: 20, cost: 0, missing: true),
    ]
    let result = Dashboard.compute(
      snapshot: snapshot(rows, now: now), harness: nil, period: .today, now: now, days: paris)
    #expect(Set(result.models.map(\.displayName)) == ["Unattributed (Claude Code)", "Unattributed (Codex)"])
    #expect(result.unattributedTokens == 30)
  }

  @Test func sharesAreRelativeToScopeTotalBeforeSearch() {
    let rows = [
      row(.claude, "2026-10-17", "a", cost: 3),
      row(.claude, "2026-10-17", "b", cost: 1),
    ]
    let result = Dashboard.compute(
      snapshot: snapshot(rows, now: now), harness: .claude, period: .today, now: now, days: paris)
    #expect(result.models.map(\.share) == [0.75, 0.25])
    #expect(result.models.first?.id == "a")
  }
}

@Suite struct CalendarTests {
  @Test func springForwardDayIsOneKey() {
    let keys = paris.keys(from: "2026-03-28", through: "2026-03-30")
    #expect(keys == ["2026-03-28", "2026-03-29", "2026-03-30"])
  }

  @Test func fallBackDayIsOneKey() {
    let keys = paris.keys(from: "2026-10-24", through: "2026-10-26")
    #expect(keys == ["2026-10-24", "2026-10-25", "2026-10-26"])
  }

  @Test func dayKeyUsesCalendarTimezone() {
    let instant = at("2026-03-10T23:30:00Z")
    #expect(paris.key(instant) == "2026-03-11")
    #expect(DayCalendar(timeZone: TimeZone(identifier: "America/New_York")!).key(instant) == "2026-03-10")
  }

  @Test func last30AcrossDstHas30Days() {
    let now = at("2026-11-05T09:00:00+01:00")
    let result = Dashboard.compute(
      snapshot: snapshot([], now: now), harness: nil, period: .last30, now: now, days: paris)
    #expect(result.days.count == 30)
    #expect(result.days.first?.key == "2026-10-07")
    #expect(Set(result.days.map(\.key)).count == 30)
  }

  @Test func weeksStartOnMonday() {
    let now = at("2026-10-17T12:00:00Z")  // Saturday
    let rows = [row(.claude, "2026-10-12", "a", cost: 1), row(.claude, "2026-10-11", "a", cost: 2)]
    let result = Dashboard.compute(
      snapshot: snapshot(rows, now: now), harness: nil, period: .last7, now: now, days: paris)
    let weeks = spendBuckets(result.days, granularity: .week, calendar: paris)
    #expect(weeks.map(\.firstKey) == ["2026-10-11", "2026-10-12"])
    #expect(weeks.map(\.cost) == [2, 1])
    let months = spendBuckets(result.days, granularity: .month, calendar: paris)
    #expect(months.count == 1)
    #expect(months[0].cost == 3)
  }

  @Test func automaticGranularity() {
    #expect(Granularity.automatic(days: 30) == .day)
    #expect(Granularity.automatic(days: 90) == .week)
    #expect(Granularity.automatic(days: 400) == .month)
  }
}
