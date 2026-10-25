import Foundation
import Testing

@testable import BurnlessCore

func reading(
  _ observed: String, used: Double, reset: String, minutes: Double = 10080, source: String = "live"
) -> QuotaReading {
  QuotaReading(
    observedAt: at(observed), usedPercent: used, windowMinutes: minutes, resetsAt: at(reset),
    source: source)
}

@Suite struct QuotaReportTests {
  let json = """
    {"schemaVersion":1,"engineVersion":"0.2.0","generatedAtMs":1792259828046,
     "claude":{"planTier":"default_claude_max_20x",
       "account":{"source":"claudeCode","observedAtMs":1792245336888,
         "session":{"usedPercent":3.0,"windowMinutes":300,"resetsAtMs":1792258199714},
         "weekly":{"usedPercent":10.0,"windowMinutes":10080,"resetsAtMs":1792447199714},
         "scoped":[{"name":"Fable","usedPercent":0.0,"resetsAtMs":1792447200000}],"extra":null},
       "live":{"state":"off","retryAfterSeconds":null}},
     "codex":{"planType":"prolite",
       "snapshot":{"source":"logs","observedAtMs":1792243539890,
         "weekly":{"usedPercent":12.5,"windowMinutes":10080,"resetsAtMs":1792683187000},
         "short":null,"resetCreditsAvailable":null},
       "limitUsageDaily":[],"live":{"state":"off","retryAfterSeconds":null}}}
    """

  @Test func decodesEngineQuotaOutput() throws {
    let report = try QuotaReport.decode(Data(json.utf8))
    #expect(report.claude.planTier == "default_claude_max_20x")
    #expect(report.claude.account?.scoped.first?.name == "Fable")
    #expect(report.codex.snapshot?.weekly?.usedPercent == 12.5)
    #expect(report.codex.live.state == .off)
  }

  @Test func turnsMetersIntoReadings() throws {
    let readings = try QuotaReport.decode(Data(json.utf8)).readings
    #expect(readings.count == 3)
    #expect(readings[.claudeSession]?.windowMinutes == 300)
    #expect(readings[.claudeWeekly]?.source == "claudeCode")
    #expect(readings[.codexWeekly]?.remaining == 87.5)
    #expect(readings[.codexShort] == nil)
  }

  @Test func rejectsOtherSchemas() {
    #expect(throws: EngineError.unsupportedSchema(2)) {
      try QuotaReport.decode(Data(#"{"schemaVersion":2}"#.utf8))
    }
    #expect(throws: EngineError.invalidOutput) { try QuotaReport.decode(Data("nope".utf8)) }
  }

  @Test func meterWithoutResetTimeIsNotARecordedReading() {
    var report = QuotaReport()
    report.codex.snapshot = CodexSnapshot(
      source: "logs", observedAtMs: 1,
      weekly: LimitWindow(usedPercent: 10, windowMinutes: 10080, resetsAtMs: nil))
    #expect(report.readings.isEmpty)
  }
}

@Suite struct ForecastTests {
  // Weekly window from Oct 13 00:00 to Oct 20 00:00 UTC, read halfway.
  let half = Forecast(
    reading: reading("2026-10-16T12:00:00Z", used: 70, reset: "2026-10-20T00:00:00Z"))

  @Test func projectsTheObservedPace() {
    #expect(half.start == at("2026-10-13T00:00:00Z"))
    #expect(half.elapsed == 0.5)
    #expect(half.remaining == 30)
    #expect(half.projectedUse == 140)
    #expect(half.runsOut)
    // 100 / 140 of the window: 5 days.
    #expect(half.projectedEnd == at("2026-10-18T00:00:00Z"))
    #expect(abs(half.daysEarly - 2) < 1e-9)
    // 30% over the 3.5 days left.
    #expect(abs(half.dailyAllowance - 30 / 3.5) < 1e-9)
    #expect(abs(half.paceDelta - -20) < 1e-9)
  }

  @Test func flagsOldReadingsAsStale() {
    #expect(!half.isStale(at: at("2026-10-16T17:59:00Z")))
    #expect(half.isStale(at: at("2026-10-16T18:01:00Z")))
    let session = Forecast(
      reading: reading("2026-10-16T12:00:00Z", used: 10, reset: "2026-10-16T15:00:00Z", minutes: 300))
    #expect(!session.isStale(at: at("2026-10-16T12:29:00Z")))
    #expect(session.isStale(at: at("2026-10-16T12:31:00Z")))
  }

  @Test func aSlowPaceLastsUntilReset() {
    let slow = Forecast(
      reading: reading("2026-10-16T12:00:00Z", used: 20, reset: "2026-10-20T00:00:00Z"))
    #expect(!slow.runsOut)
    #expect(slow.projectedEnd == slow.reset)
    #expect(slow.projectedRemaining == 60)
    #expect(slow.paceDelta == 30)
  }

  @Test func aPassedResetMeansAFullLimit() {
    #expect(half.remaining(at: at("2026-10-19T23:00:00Z")) == 30)
    #expect(half.remaining(at: at("2026-10-20T00:00:01Z")) == 100)
  }

  @Test func untilResetChartStartsFullAtTheWindowStart() {
    let samples = QuotaChart.samples(
      [QuotaSample(date: at("2026-10-15T00:00:00Z"), remaining: 60)], range: .untilReset,
      forecast: half, now: at("2026-10-16T12:00:00Z"))
    #expect(samples.first == QuotaSample(date: at("2026-10-13T00:00:00Z"), remaining: 100))
    #expect(samples.count == 2)
  }

  @Test func paceSegmentsSplitWhereRemainingCrossesEvenPace() {
    let samples = [
      QuotaSample(date: at("2026-10-13T00:00:00Z"), remaining: 100),
      QuotaSample(date: at("2026-10-14T00:00:00Z"), remaining: 95),
      QuotaSample(date: at("2026-10-16T12:00:00Z"), remaining: 30),
    ]
    let segments = QuotaChart.deltaSegments(samples: samples, forecast: half)
    #expect(segments.map(\.ahead) == [true, false])
    #expect(segments[0].points.last == segments[1].points.first)
  }

  @Test func paceText() {
    #expect(QuotaText.pace(0.01) == "On pace")
    #expect(QuotaText.pace(10) == "+10 pts ahead")
    #expect(QuotaText.pace(-2.5) == "−2.5 pts behind")
    #expect(QuotaText.duration(2 * 3600 + 5 * 60) == "2h 05m")
    #expect(QuotaText.duration(26 * 3600) == "1d 2h")
  }
}

@Suite struct QuotaHistoryTests {
  @Test func keepsOnlyNewerReadings() {
    var history = QuotaHistory()
    let first = reading("2026-10-16T10:00:00Z", used: 10, reset: "2026-10-20T00:00:00Z")
    let added = history.record(first, series: .codexWeekly)
    // Claude Code's cache and Codex logs return the same reading on every poll.
    let repeated = history.record(first, series: .codexWeekly)
    let older = history.record(
      reading("2026-10-16T09:00:00Z", used: 5, reset: "2026-10-20T00:00:00Z"), series: .codexWeekly)
    #expect(added)
    #expect(!repeated)
    #expect(!older)
    #expect(history.all(.codexWeekly).count == 1)
  }

  @Test func hidesAWeeklyOverCountUntilConfirmed() {
    var history = QuotaHistory()
    history.record(reading("2026-10-16T10:00:00Z", used: 49, reset: "2026-10-20T00:00:00Z"), series: .codexWeekly)
    history.record(reading("2026-10-16T10:01:00Z", used: 99, reset: "2026-10-20T00:00:30Z"), series: .codexWeekly)
    #expect(history.current(.codexWeekly)?.usedPercent == 49)
    #expect(history.samples(.codexWeekly).map(\.remaining) == [51])
  }

  @Test func laterLowerReadingsProveEarlierOverCounts() {
    var history = QuotaHistory()
    for (time, used) in [("10:00", 40.0), ("11:00", 90.0), ("12:00", 45.0)] {
      history.record(
        reading("2026-10-16T\(time):00Z", used: used, reset: "2026-10-20T00:00:00Z"),
        series: .codexWeekly)
    }
    #expect(history.consistent(.codexWeekly).map(\.usedPercent) == [40, 45])
  }

  @Test func detectsScheduledAndMidWindowResets() {
    var history = QuotaHistory()
    history.record(reading("2026-10-19T22:00:00Z", used: 80, reset: "2026-10-20T00:00:00Z"), series: .claudeWeekly)
    history.record(reading("2026-10-20T01:00:00Z", used: 1, reset: "2026-10-27T00:00:00Z"), series: .claudeWeekly)
    history.record(reading("2026-10-22T01:00:00Z", used: 60, reset: "2026-10-27T00:00:00Z"), series: .claudeWeekly)
    history.record(reading("2026-10-22T02:00:00Z", used: 0, reset: "2026-10-27T00:00:00Z"), series: .claudeWeekly)
    let resets = history.resets(.claudeWeekly)
    // The last drop to 0 within one window reads as an over-count of the
    // 60% reading, which is dropped, so only the scheduled reset remains.
    #expect(resets.count == 1)
    #expect(resets.first?.scheduled == true)
  }

  @Test func ignoresReplaysOfASupersededWindow() {
    var history = QuotaHistory()
    history.record(reading("2026-10-19T22:00:00Z", used: 80, reset: "2026-10-20T00:00:00Z"), series: .codexWeekly)
    history.record(reading("2026-10-20T01:00:00Z", used: 2, reset: "2026-10-27T00:00:00Z"), series: .codexWeekly)
    history.record(reading("2026-10-20T01:01:00Z", used: 81, reset: "2026-10-20T00:00:00Z"), series: .codexWeekly)
    #expect(history.consistent(.codexWeekly).map(\.usedPercent) == [80, 2])
    #expect(history.current(.codexWeekly)?.usedPercent == 2)
  }

  @Test func fileCommitsMergeAndKeepABackup() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = QuotaHistoryFile(directory: directory)
    try file.commit([.codexWeekly: reading("2026-10-16T10:00:00Z", used: 10, reset: "2026-10-20T00:00:00Z")], now: at("2026-10-16T10:00:00Z"))
    try file.commit([.claudeSession: reading("2026-10-16T10:00:00Z", used: 3, reset: "2026-10-16T12:00:00Z", minutes: 300)], now: at("2026-10-16T10:00:00Z"))
    let loaded = try #require(file.load())
    #expect(loaded.all(.codexWeekly).count == 1)
    #expect(loaded.all(.claudeSession).count == 1)
    #expect(FileManager.default.fileExists(atPath: file.backupURL.path))
    // A corrupt main file falls back to the backup.
    try Data("{".utf8).write(to: file.url)
    #expect(file.load()?.all(.codexWeekly).count == 1)
  }
}

@Suite struct PlanTests {
  @Test func mapsClaudeTiers() {
    #expect(PlanCatalog.claude(tier: "default_claude_max_20x").label == "Max 20× · $200/mo")
    #expect(PlanCatalog.claude(tier: "default_claude_max_5x").pricePerMonth == 100)
    #expect(PlanCatalog.claude(tier: "default_claude_pro").name == "Pro")
    #expect(PlanCatalog.claude(tier: "default_claude_team").name == "Team")
    #expect(PlanCatalog.claude(tier: "default_claude_team").pricePerMonth == nil)
    #expect(PlanCatalog.claude(tier: nil).label == "Plan not detected")
  }

  @Test func mapsCodexPlansWithoutInventingPrices() {
    #expect(PlanCatalog.codex(planType: "plus").pricePerMonth == 20)
    #expect(PlanCatalog.codex(planType: "pro").pricePerMonth == 200)
    #expect(PlanCatalog.codex(planType: "prolite").label == "Pro 5× · $100/mo")
    #expect(PlanCatalog.codex(planType: "team").label == "Team · price unknown")
  }

  @Test func resolvesGeminiPlansOnlyFromSettings() {
    #expect(PlanCatalog.apply("plus", to: SubscriptionPlan(), harness: .gemini).label == "Google AI Plus · $4.99/mo")
    #expect(PlanCatalog.apply("Google AI Pro", to: SubscriptionPlan(), harness: .gemini).pricePerMonth == 19.99)
    #expect(PlanCatalog.apply("ultra", to: SubscriptionPlan(), harness: .gemini).isOverride)
    // An unknown name does not invent a plan; a price still works.
    #expect(PlanCatalog.apply("team", to: SubscriptionPlan(), harness: .gemini).name == nil)
    #expect(PlanCatalog.apply("10", to: SubscriptionPlan(), harness: .gemini).pricePerMonth == 10)
    #expect(!Harness.gemini.readsLimits)
  }

  @Test func passesTheGeminiFolderToTheEngine() {
    let configuration = EngineConfiguration(
      executable: URL(fileURLWithPath: "/bin/true"), geminiDirectory: "/tmp/gemini")
    #expect(configuration.environment(base: [:])["GEMINI_DATA_DIR"] == "/tmp/gemini")
    #expect(EngineConfiguration(executable: URL(fileURLWithPath: "/bin/true")).environment(base: [:])["GEMINI_DATA_DIR"] == nil)
  }

  @Test func appliesOverrides() {
    let lite = PlanCatalog.codex(planType: "prolite")
    let priced = PlanCatalog.apply("$90", to: lite, harness: .codex)
    #expect(priced.name == "Pro 5×")
    #expect(priced.pricePerMonth == 90)
    #expect(priced.isOverride)
    #expect(PlanCatalog.apply("max-20x", to: SubscriptionPlan(), harness: .claude).pricePerMonth == 200)
    for typed in ["max20", "Max 20", "max_20"] {
      #expect(PlanCatalog.apply(typed, to: SubscriptionPlan(), harness: .claude).pricePerMonth == 200)
    }
    #expect(PlanCatalog.apply("Max 5", to: SubscriptionPlan(), harness: .claude).name == "Max 5×")
    #expect(PlanCatalog.apply("  ", to: lite, harness: .codex) == lite)
    #expect(PlanCatalog.apply("-5", to: lite, harness: .codex).pricePerMonth == 100)
  }

  @Test func anUnknownOverrideKeepsTheDetectedPlan() {
    let max = PlanCatalog.claude(tier: "default_claude_max_20x")
    let typo = PlanCatalog.apply("h", to: max, harness: .claude)
    #expect(typo.name == "Max 20×")
    #expect(typo.pricePerMonth == 200)
    #expect(!typo.isOverride)
    #expect(typo.ignoredOverride == "h")
    #expect(PlanCatalog.apply("pro", to: max, harness: .claude).ignoredOverride == nil)
    #expect(PlanCatalog.apply("prolite", to: SubscriptionPlan(), harness: .codex).name == "Pro 5×")
    #expect(PlanCatalog.apply("-5", to: max, harness: .claude).ignoredOverride == "-5")
  }
}

@Suite struct SubscriptionMathTests {
  let now = at("2026-10-17T15:00:00+02:00")

  @Test func valueComparesThirtyDaysWithThePlanPrice() {
    let rows = [row(.claude, "2026-10-17", "a", cost: 300), row(.claude, "2026-09-10", "a", cost: 999)]
    let value = SubscriptionMath.value(
      snapshot(rows, now: now), harness: .claude,
      plan: PlanCatalog.claude(tier: "default_claude_max_20x"), now: now, calendar: paris)
    #expect(value.apiEquivalent.cost == 300)
    #expect(value.valueMultiple == 1.5)
    #expect(value.subsidy == 100)
    #expect(abs((value.discountPercent ?? 0) - 100.0 / 3) < 1e-9)
    let unknown = SubscriptionValue(apiEquivalent: value.apiEquivalent, plan: SubscriptionPlan(name: "Pro Lite"))
    #expect(unknown.valueMultiple == nil)
    #expect(unknown.subsidy == nil)
  }

  @Test func spendMixUsesTheEngineSplit() {
    var priced = row(.codex, "2026-10-17", "m", tokens: 800, cost: 10)
    priced.costBreakdown = CostBreakdown(input: 2, output: 7, cacheWrite: 0, cacheRead: 1)
    let mix = SubscriptionMath.spendMix(snapshot([priced], now: now), harness: .codex, now: now, calendar: paris)
    let output = mix.first(where: { $0.kind == .output })
    #expect(output?.cost == 7)
    #expect(output?.costShare == 0.7)
    let shares = mix.map(\.tokenShare).reduce(0, +)
    #expect(abs(shares - 1) < 1e-9)
  }

  @Test func cycleSpendProratesTheFirstDay() {
    let rows = [row(.claude, "2026-10-15", "a", cost: 24), row(.claude, "2026-10-16", "a", cost: 10)]
    // The window starts at 18:00 Paris time, a quarter of the first day remains.
    let start = at("2026-10-15T18:00:00+02:00")
    let cycle = SubscriptionMath.cycleSpend(
      snapshot(rows, now: now), harness: .claude, since: start, now: now, calendar: paris)
    #expect(abs(cycle.cost - 16) < 1e-9)
  }

  @Test func cycleSpendStopsAtAnOlderReading() {
    let rows = [
      row(.claude, "2026-10-13", "a", cost: 10), row(.claude, "2026-10-14", "a", cost: 10),
      row(.claude, "2026-10-15", "a", cost: 10),
    ]
    // Read at 06:00 Paris on the 14th: a quarter of that day, none of the 15th.
    let cycle = SubscriptionMath.cycleSpend(
      snapshot(rows, now: now), harness: .claude, since: at("2026-10-13T00:00:00+02:00"),
      through: at("2026-10-14T06:00:00+02:00"), now: now, calendar: paris)
    #expect(abs(cycle.cost - 12.5) < 1e-9)
  }

  @Test func quotaValueExtrapolatesTheWindow() throws {
    let forecast = Forecast(reading: reading("2026-10-16T12:00:00Z", used: 25, reset: "2026-10-20T00:00:00Z"))
    let estimate = try #require(
      QuotaValueEstimate.make(cycleSpend: 50, cycleTokens: 1_000_000, forecast: forecast, price: 200))
    #expect(estimate.fullQuotaValue == 200)
    #expect(abs(estimate.monthlyValue - 200 * 30.4375 / 7) < 1e-9)
    #expect(estimate.projectedUsePercent == 50)
    #expect(estimate.dollarsPerPercent == 2)
    #expect(QuotaValueEstimate.make(cycleSpend: 0, cycleTokens: 0, forecast: forecast, price: nil) == nil)
  }

  @Test func weeklyTrendHasOneBucketPerWeek() {
    let rows = [row(.codex, "2026-10-13", "m", cost: 2), row(.codex, "2026-10-17", "m", cost: 3)]
    let trend = SubscriptionMath.weeklyTrend(snapshot(rows, now: now), harness: .codex, weeks: 3, now: now, calendar: paris)
    #expect(trend.map(\.key) == ["2026-09-28", "2026-10-05", "2026-10-12"])
    #expect(trend.last?.cost == 5)
  }
}

@Suite struct ExtraPeriodTests {
  let now = at("2026-10-17T15:00:00+02:00")
  let rows = [
    row(.claude, "2026-10-17", "a"), row(.claude, "2026-10-16", "a"), row(.claude, "2026-10-12", "a"),
    row(.codex, "2026-01-01", "b"), row(.codex, "2025-12-31", "b"),
  ]

  func dashboard(_ period: Period, reset: Date? = nil) -> Dashboard {
    Dashboard.compute(
      snapshot: snapshot(rows, now: now), harness: nil, period: period, now: now, days: paris,
      resetStart: reset)
  }

  @Test func yesterdayIsOneDay() {
    #expect(dashboard(.yesterday).days.map(\.key) == ["2026-10-16"])
    #expect(dashboard(.yesterday).totals.cost == 1)
  }

  @Test func weekToDateStartsOnMonday() {
    #expect(dashboard(.weekToDate).lowerKey == "2026-10-12")
    #expect(dashboard(.weekToDate).totals.cost == 3)
  }

  @Test func yearToDateStartsOnJanuaryFirst() {
    #expect(dashboard(.yearToDate).lowerKey == "2026-01-01")
    #expect(dashboard(.yearToDate).totals.cost == 4)
  }

  @Test func sinceResetFollowsTheLimitWindow() {
    #expect(dashboard(.sinceReset, reset: at("2026-10-16T09:00:00+02:00")).lowerKey == "2026-10-16")
    #expect(dashboard(.sinceReset).lowerKey == "2026-10-11")
  }
}
