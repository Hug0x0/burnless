// Quota cards adapted from Agent Burn's QuotaSummary, ClaudeAccountView and
// CodexLimitUsageChart (https://github.com/Melvynx/agent-burn, MIT).

import BurnlessCore
import Charts
import SwiftUI

// MARK: - Shared pieces

/// Where a reading comes from and how old it is.
struct QuotaFreshness: View {
  let forecast: Forecast
  let now: Date

  var body: some View {
    let age = now.timeIntervalSince(forecast.observedAt)
    let live = forecast.isLive && age <= 180
    HStack(spacing: 6) {
      Circle().fill(live ? BurnTheme.ahead : age < 3 * 3600 ? .orange.opacity(0.8) : .secondary)
        .frame(width: 7, height: 7)
      Text(live ? "Live" : "Measured \(QuotaText.duration(age)) ago").monospacedDigit()
    }
    .help(quotaSourceHelp(forecast.source) + " Measured " + forecast.observedAt.formatted(date: .abbreviated, time: .standard) + ".")
  }
}

func quotaSourceHelp(_ source: String) -> String {
  switch source {
  case "live": "Read from the provider's usage endpoint with your existing sign-in."
  case "claudeCode": "The meters Claude Code saved on this Mac the last time it checked them."
  case "logs": "The limit Codex logged with your latest Codex request on this Mac."
  default: "Saved reading."
  }
}

struct QuotaRangePicker: View {
  @Binding var range: QuotaChartRange
  var body: some View {
    Picker("Quota chart range", selection: $range) {
      ForEach(QuotaChartRange.allCases) { Text($0.label).tag($0) }
    }
    .labelsHidden()
    .pickerStyle(.menu)
    .controlSize(.small)
    .frame(width: 132)
    .help("Changes only the quota chart. The spend period stays independent.")
  }
}

/// Reads plans and meters now (⇧⌘R).
struct QuotaCheckButton: View {
  @Environment(UsageStore.self) private var store
  var label = false

  var body: some View {
    Button {
      store.checkQuotas(hard: true)
    } label: {
      if label {
        Label("Check now", systemImage: "gauge.with.dots.needle.67percent")
      } else {
        Image(systemName: "gauge.with.dots.needle.67percent")
      }
    }
    .symbolEffect(.pulse, isActive: store.isCheckingQuotas)
    .buttonStyle(.plain)
    .disabled(store.isCheckingQuotas || store.isDemo)
    .help(
      store.settings.liveQuotas
        ? "Check limits now (⇧⌘R). Asks the providers again, even if a live read is paused."
        : "Check limits now (⇧⌘R). Re-reads Claude Code's and Codex's local files.")
    .accessibilityLabel("Check limits now")
  }
}

private func pace(_ delta: Double) -> Color { delta < -0.05 ? BurnTheme.behind : BurnTheme.ahead }

// MARK: - Weekly summary

/// Remaining share, pace and the facts of one weekly window.
struct QuotaSummaryPanel: View {
  let forecast: Forecast
  let now: Date
  var estimate: QuotaValueEstimate? = nil
  var resetCredits: Int? = nil
  var resets: [QuotaReset] = []

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Weekly quota").font(.system(size: 13, weight: .semibold))
      VStack(alignment: .leading, spacing: 9) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text(QuotaText.percentOneDecimal(forecast.remaining))
            .font(.system(size: 38, weight: .semibold, design: .rounded)).monospacedDigit()
            .contentTransition(.numericText()).animation(.snappy, value: forecast.remaining)
            .lineLimit(1).minimumScaleFactor(0.7)
          Text("remaining").font(.system(size: 13)).foregroundStyle(.secondary).fixedSize()
        }
        .accessibilityElement(children: .combine)
        if let text = QuotaText.pace(forecast.paceDelta) {
          StatusBadge(text: text, color: pace(forecast.paceDelta))
            .help("Remaining now minus an even pace until reset.")
        }
        ShareBar(value: forecast.remaining / 100, tint: pace(forecast.paceDelta), height: 5)
      }
      VStack(spacing: 8) {
        fact(
          "Reset in", QuotaText.duration(forecast.reset.timeIntervalSince(now)),
          detail: resetDetail, help: "Time left in this weekly limit window.")
        fact(
          "Used", QuotaText.percentOneDecimal(forecast.usedPercent),
          detail: "since " + forecast.start.formatted(.dateTime.month(.abbreviated).day()),
          help: "The current weekly limit started at this time.")
        fact(
          "Daily", QuotaText.percentOneDecimal(forecast.dailyAllowance) + "\u{00A0}/ day",
          help: "Remaining limit divided by the days until reset.")
        if let estimate {
          fact(
            "Avg $ / %", Format.currency(estimate.dollarsPerPercent) + " / %",
            detail: estimate.tokensPerDollar.map { Format.tokens(UInt64($0)) + " / $" },
            help: "API-equivalent spend this window divided by the share of the limit it used.")
        }
        if let resetCredits {
          fact("Resets", "\(resetCredits)", detail: "banked", help: "Codex rate-limit resets you can redeem now.")
        }
        if !resets.isEmpty {
          let scheduled = resets.filter(\.scheduled).count
          fact(
            "Recorded resets", "\(resets.count)",
            detail: scheduled == resets.count ? "scheduled" : "\(resets.count - scheduled) mid-window",
            help: "Resets seen in Burnless's readings. A mid-window reset is a manual reset or a provider correction.")
        }
      }
      .padding(.horizontal, 10).padding(.vertical, 9)
      .background(BurnTheme.hover, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var resetDetail: String {
    forecast.reset.timeIntervalSince(now) < 6 * 86_400
      ? forecast.reset.formatted(.dateTime.weekday(.abbreviated).hour().minute())
      : forecast.reset.formatted(.dateTime.month(.abbreviated).day())
  }

  private func fact(_ title: String, _ value: String, detail: String? = nil, help: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Text(title).foregroundStyle(.secondary).lineLimit(1).fixedSize()
      Spacer(minLength: 6)
      Text(value).font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
        .lineLimit(1).fixedSize()
      if let detail {
        Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
          .lineLimit(1).minimumScaleFactor(0.8)
      }
    }
    .font(.system(size: 12))
    .help(help)
    .accessibilityElement(children: .combine)
  }
}

// MARK: - Codex

struct CodexQuotaCard: View {
  @Environment(UsageStore.self) private var store

  var body: some View {
    @Bindable var settings = store.settings
    let plan = store.plan(for: .codex)
    let now = store.clock
    VStack(alignment: .leading, spacing: 16) {
      CardHeader(
        title: "Codex " + (plan.name ?? "account"), symbol: "gauge.with.dots.needle.33percent",
        tint: BurnTheme.color(for: .codex)
      ) {
        HStack(spacing: 12) {
          if let price = plan.pricePerMonth { Text(Format.currency(price, wholeDollars: true) + " / month").monospacedDigit() }
          if let forecast = store.weekly(.codex) { QuotaFreshness(forecast: forecast, now: now) }
          QuotaRangePicker(range: $settings.quotaChartRange)
          QuotaCheckButton()
        }
      }
      if let forecast = store.weekly(.codex) {
        if forecast.hasReset(at: now) {
          ResetPlaceholder(reset: forecast.reset, now: now)
        } else {
          ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 24) {
              summary(forecast).frame(width: 236, alignment: .leading)
              chart(forecast)
            }
            VStack(alignment: .leading, spacing: 18) {
              summary(forecast)
              chart(forecast)
            }
          }
        }
        if let short = store.forecast(.codexShort), !short.hasReset(at: now) {
          ClaudeMeterRow(
            title: shortTitle(short), used: short.usedPercent, tint: BurnTheme.color(for: .codex),
            detail: "resets in " + QuotaText.duration(short.reset.timeIntervalSince(now)))
        }
      } else {
        QuotaUnavailable(harness: .codex)
      }
    }
    .burnCard(padding: 18)
  }

  private func summary(_ forecast: Forecast) -> some View {
    QuotaSummaryPanel(
      forecast: forecast, now: store.clock, estimate: store.cycle(.codex)?.estimate,
      resetCredits: store.quota?.codex.snapshot?.resetCreditsAvailable,
      resets: store.resets(.codexWeekly))
  }

  private func chart(_ forecast: Forecast) -> some View {
    QuotaChartView(
      forecast: forecast, samples: store.samples(.codexWeekly, range: store.settings.quotaChartRange),
      color: BurnTheme.color(for: .codex), range: store.settings.quotaChartRange, now: store.clock)
  }

  private func shortTitle(_ forecast: Forecast) -> String {
    let hours = Int((forecast.duration / 3600).rounded())
    return "\(hours)-hour limit"
  }
}

struct QuotaUnavailable: View {
  @Environment(UsageStore.self) private var store
  let harness: Harness

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(store.quota == nil ? "Reading limits…" : "Limit not available yet")
        .font(.system(size: 15, weight: .semibold))
      Text(message).font(.system(size: 12)).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
  }

  private var message: String {
    if let error = store.quotaError { return error }
    switch harness {
    case .codex:
      return store.settings.liveQuotas
        ? "Sign in to Codex and run a request, then check again."
        : "Codex logs its weekly limit with each request. Run Codex once, or turn on live limits in Settings → Quotas."
    case .claude:
      return store.settings.liveQuotas
        ? "Sign in to Claude Code, then check again."
        : "Claude Code saves its limits when it checks them (for example with /usage). Or turn on live limits in Settings → Quotas."
    }
  }
}

private struct ResetPlaceholder: View {
  let reset: Date
  let now: Date
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text("100%").font(.system(size: 38, weight: .semibold, design: .rounded))
        Text("remaining").foregroundStyle(.secondary)
      }
      Text(
        "The limit reset \(reset.formatted(.relative(presentation: .named, unitsStyle: .wide))). A new window starts with your next request."
      )
      .font(.system(size: 12)).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

// MARK: - Claude

/// One sentence that says whether both limits last until they reset.
struct QuotaVerdict: Equatable {
  let atRisk: Bool
  let headline: String
  let detail: String

  /// Session run-outs come first because they lock you out soonest.
  static func make(session: Forecast?, weekly: Forecast?, now: Date) -> QuotaVerdict? {
    if let session, let verdict = runOut(session, name: "Session", now: now) { return verdict }
    if let weekly, let verdict = runOut(weekly, name: "Weekly limit", now: now) { return verdict }
    guard session != nil || weekly != nil else { return nil }
    return QuotaVerdict(
      atRisk: false, headline: "On track.",
      detail: session != nil && weekly != nil
        ? "At this pace both limits last until they reset." : "At this pace the limit lasts until it resets.")
  }

  private static func runOut(_ forecast: Forecast, name: String, now: Date) -> QuotaVerdict? {
    let reset = label(forecast.reset, forecast)
    if forecast.remaining <= 0 {
      return QuotaVerdict(atRisk: true, headline: "\(name) reached.", detail: "It resets \(reset).")
    }
    guard forecast.runsOut else { return nil }
    let left = max(60, forecast.reset.timeIntervalSince(max(now, forecast.observedAt)))
    let rate =
      forecast.duration <= 86_400
      ? "Slow to \(QuotaText.percent((forecast.remaining / (left / 3600) * 10).rounded() / 10))/h"
      : "Keep under \(QuotaText.percent((forecast.remaining / (left / 86_400) * 10).rounded() / 10))/day"
    return QuotaVerdict(
      atRisk: true, headline: "\(name) runs out ≈ \(label(forecast.projectedEnd, forecast)).",
      detail: "\(rate) to last until the \(reset) reset.")
  }

  private static func label(_ date: Date, _ forecast: Forecast) -> String {
    forecast.duration <= 86_400
      ? date.formatted(date: .omitted, time: .shortened)
      : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
  }
}

struct VerdictBanner: View {
  let verdict: QuotaVerdict
  var body: some View {
    let tone = verdict.atRisk ? BurnTheme.behind : BurnTheme.ahead
    HStack(spacing: 10) {
      Image(systemName: verdict.atRisk ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
        .font(.system(size: 14)).foregroundStyle(tone)
      (Text(verdict.headline).fontWeight(.semibold).foregroundStyle(verdict.atRisk ? tone : .primary)
        + Text(" " + verdict.detail).foregroundStyle(.secondary))
        .font(.system(size: 13)).monospacedDigit()
        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 14).padding(.vertical, 11)
    .background(tone.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .accessibilityElement(children: .combine)
  }
}

struct ClaudeAccountCard: View {
  @Environment(UsageStore.self) private var store

  var body: some View {
    let plan = store.plan(for: .claude)
    let now = store.clock
    let weekly = store.forecast(.claudeWeekly)
    let session = store.forecast(.claudeSession)
    let account = store.quota?.claude.account
    VStack(alignment: .leading, spacing: 16) {
      CardHeader(
        title: "Claude " + (plan.name ?? "account"), symbol: "gauge.with.dots.needle.33percent",
        tint: BurnTheme.color(for: .claude)
      ) {
        HStack(spacing: 12) {
          if let price = plan.pricePerMonth { Text(Format.currency(price, wholeDollars: true) + " / month").monospacedDigit() }
          if let latest = weekly ?? session { QuotaFreshness(forecast: latest, now: now) }
          QuotaCheckButton(label: true)
        }
      }
      if let notice = liveNotice { Notice(message: notice, kind: .warning) }
      if let verdict = QuotaVerdict.make(
        session: session.flatMap { $0.hasReset(at: now) ? nil : $0 },
        weekly: weekly.flatMap { $0.hasReset(at: now) ? nil : $0 }, now: now)
      {
        VerdictBanner(verdict: verdict)
      }
      if weekly != nil || session != nil {
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .top, spacing: 14) { panels(session: session, weekly: weekly) }
          VStack(spacing: 14) { panels(session: session, weekly: weekly) }
        }
      } else {
        QuotaUnavailable(harness: .claude)
      }
      if let account, !account.scoped.isEmpty || account.extra?.isRelevant == true {
        Divider()
        secondary(account)
      }
    }
    .burnCard(padding: 18)
  }

  @ViewBuilder private func panels(session: Forecast?, weekly: Forecast?) -> some View {
    LimitPanel(
      title: "5-hour session", forecast: session,
      samples: store.samples(.claudeSession, range: .untilReset), now: store.clock,
      tint: BurnTheme.color(for: .claude))
    LimitPanel(
      title: "Weekly", forecast: weekly, samples: store.samples(.claudeWeekly, range: .untilReset),
      now: store.clock, tint: BurnTheme.color(for: .claude))
  }

  private func secondary(_ account: ClaudeAccount) -> some View {
    let count = account.scoped.count + (account.extra?.isRelevant == true ? 1 : 0)
    return LazyVGrid(
      columns: Array(repeating: GridItem(.flexible(), spacing: 28, alignment: .top), count: min(2, max(1, count))),
      alignment: .leading, spacing: 14
    ) {
      ForEach(account.scoped) { limit in
        ClaudeMeterRow(title: limit.name + " · weekly", used: limit.usedPercent, tint: BurnTheme.color(for: .claude))
      }
      if let extra = account.extra, extra.isRelevant {
        ClaudeMeterRow(
          title: "Extra usage", used: extra.resolvedUsedPercent, tint: BurnTheme.color(for: .claude),
          value: extra.usedUSD.map { used in
            extra.limitUSD.map { Format.currency(max(0, $0 - used)) + " left" } ?? Format.currency(used) + " used"
          },
          detail: extra.limitUSD.map { "of " + Format.currency($0) + " limit" })
      }
    }
  }

  private var liveNotice: String? {
    guard store.settings.liveQuotas, let live = store.quota?.claude.live else { return nil }
    switch live.state {
    case .signInExpired:
      return "Claude Code's sign-in has expired. Burnless never renews it; open Claude Code to sign in again. Showing the last saved meters."
    case .unauthorized:
      return "Anthropic refused Claude Code's sign-in. Run claude and use /login. Showing the last saved meters."
    case .noSignIn:
      return "No Claude Code sign-in could be read (the Keychain request may have been denied). Showing the meters Claude Code saved."
    case .rateLimited:
      return "Anthropic is rate limiting usage checks. Burnless retries later and shows the last saved meters."
    case .off, .ok, .failed: return nil
    }
  }
}

/// One limit: remaining, pace delta, reset countdown and an until-reset chart.
struct LimitPanel: View {
  let title: String
  let forecast: Forecast?
  let samples: [QuotaSample]
  let now: Date
  let tint: Color

  private var hasReset: Bool { forecast?.hasReset(at: now) ?? false }
  private var remaining: Double? { forecast.map { $0.remaining(at: now) } }
  private var atRisk: Bool {
    guard let forecast, !hasReset else { return false }
    return forecast.remaining <= 0 || forecast.runsOut
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 6) {
          Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.6)
            .foregroundStyle(.secondary)
          Spacer(minLength: 8)
          if let forecast {
            Group {
              if hasReset {
                Text("Reset")
              } else {
                Text("Resets in ")
                  + Text(QuotaText.duration(forecast.reset.timeIntervalSince(now))).fontWeight(.semibold)
                  .foregroundStyle(.primary)
              }
            }
            .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
            .lineLimit(1).fixedSize()
            .help("Resets " + forecast.reset.formatted(date: .abbreviated, time: .shortened))
          }
        }
        HStack(alignment: .center, spacing: 8) {
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(remaining.map(QuotaText.percent) ?? "—")
              .font(.system(size: 40, weight: .semibold, design: .rounded)).monospacedDigit()
              .contentTransition(.numericText()).animation(.snappy, value: remaining)
            Text("left").font(.system(size: 14)).foregroundStyle(.secondary)
          }
          .lineLimit(1).minimumScaleFactor(0.7)
          .accessibilityElement(children: .combine)
          Spacer(minLength: 8)
          if let forecast, !hasReset {
            Text(QuotaText.pace(forecast.paceDelta) ?? "")
              .font(.system(size: 12, weight: .semibold)).monospacedDigit()
              .foregroundStyle(pace(forecast.paceDelta))
              .padding(.horizontal, 8).padding(.vertical, 4)
              .background(pace(forecast.paceDelta).opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
              .fixedSize()
              .help("Remaining now minus an even pace until reset.")
          }
        }
      }
      if let forecast, !hasReset {
        QuotaChartView(
          forecast: forecast, samples: samples, color: tint, range: .untilReset, now: now, height: 150,
          minimal: true)
      } else {
        VStack(alignment: .leading, spacing: 10) {
          Spacer(minLength: 0)
          if let remaining { ShareBar(value: remaining / 100, tint: tint, height: 6) }
          Text(
            hasReset
              ? "Limit reset. A new window starts with your next request."
              : "No reading of this limit yet."
          )
          .font(.system(size: 11)).foregroundStyle(.secondary)
          Spacer(minLength: 0)
        }
        .frame(height: 150)
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(BurnTheme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(atRisk ? BurnTheme.behind.opacity(0.28) : BurnTheme.cardStroke))
  }
}

/// Model-scoped limits and extra usage: title, detail, a thin bar and the value.
struct ClaudeMeterRow: View {
  let title: String
  let used: Double?
  var tint: Color = BurnTheme.ember
  var value: String? = nil
  var detail: String? = nil

  private var remaining: Double? { used.map { max(0, min(100, 100 - $0)) } }

  var body: some View {
    HStack(spacing: 16) {
      Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1).fixedSize()
      if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
      Group {
        if let remaining {
          ShareBar(value: remaining / 100, tint: remaining < 15 ? BurnTheme.behind : tint, height: 6)
        } else {
          Spacer(minLength: 0)
        }
      }
      .frame(minWidth: 48, maxWidth: .infinity)
      .layoutPriority(-1)
      Group {
        if let value {
          Text(value).fontWeight(.semibold)
        } else {
          Text(remaining.map(QuotaText.percent) ?? "—").fontWeight(.semibold)
            + Text(" left").foregroundStyle(.secondary)
        }
      }
      .font(.system(size: 13)).monospacedDigit()
      .lineLimit(1).fixedSize()
    }
    .accessibilityElement(children: .combine)
  }
}

// MARK: - Codex weekly limit per day

enum LimitUsageGrouping: String, CaseIterable, Identifiable {
  case surface, model
  var id: String { rawValue }
  var label: String { self == .surface ? "Surface" : "Model" }
}

func limitUsageSurfaceLabel(_ surface: String) -> String {
  switch surface {
  case "cli": "CLI"
  case "exec": "Exec"
  case "desktop_app": "Desktop app"
  case "work_desktop": "Desktop app (work)"
  case "vscode": "IDE extension"
  case "jetbrains": "JetBrains"
  case "web": "Cloud"
  case "work_web": "Cloud (work)"
  case "mobile": "Mobile"
  case "work_mobile": "Mobile (work)"
  case "github": "GitHub"
  case "github_code_review": "Code review"
  case "slack": "Slack"
  case "linear": "Linear"
  case "sdk": "SDK"
  default: "Other"
  }
}

struct CodexLimitUsageChart: View {
  let days: [LimitUsageDay]
  @State private var grouping = LimitUsageGrouping.surface
  @State private var selected: Date?

  private struct Segment: Identifiable {
    let date: Date
    let day: String
    let series: String
    let percent: Double
    var id: String { day + series }
  }

  private static let calendar: DayCalendar = DayCalendar(timeZone: TimeZone(identifier: "UTC")!)

  /// The five largest series over the period; the rest are folded into Other.
  private var segments: [Segment] {
    let perDay = days.map { day in
      (
        day,
        grouping == .surface
          ? day.surfaces.map { (limitUsageSurfaceLabel($0.surface), $0.usedPercent) }
          : day.models.map { ($0.speed == "fast" ? $0.model + " fast" : $0.model, $0.usedPercent) }
      )
    }
    var totals: [String: Double] = [:]
    for (_, values) in perDay { for (series, percent) in values { totals[series, default: 0] += percent } }
    let kept = Set(
      totals.filter { $0.key != "Other" }.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        .prefix(5).map(\.key))
    return perDay.flatMap { day, values -> [Segment] in
      guard let date = Self.calendar.date(day.date) else { return [] }
      var grouped: [String: Double] = [:]
      for (series, percent) in values { grouped[kept.contains(series) ? series : "Other", default: 0] += percent }
      return grouped.filter { $0.value > 0 }.sorted { $0.key < $1.key }.map {
        Segment(date: date, day: day.date, series: $0.key, percent: $0.value)
      }
    }
  }

  private var order: [String] {
    var totals: [String: Double] = [:]
    for segment in segments { totals[segment.series, default: 0] += segment.percent }
    return totals.sorted { lhs, rhs in
      if lhs.key == "Other" { return false }
      if rhs.key == "Other" { return true }
      return lhs.value > rhs.value
    }.map(\.key)
  }

  private var selectedDay: LimitUsageDay? {
    guard let selected else { return nil }
    let key = Self.calendar.key(selected)
    return days.first { $0.date == key }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        IconBadge(symbol: "chart.bar.doc.horizontal", tint: BurnTheme.color(for: .codex))
        Text("Weekly limit used per day").font(.system(size: 13, weight: .semibold))
        Picker("Group by", selection: $grouping) {
          ForEach(LimitUsageGrouping.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented).frame(width: 160).labelsHidden()
        Spacer()
        Text(selectedDay.map(tooltip) ?? "\(percent(days.reduce(0) { $0 + $1.usedPercent })) over \(days.count) days")
          .font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
      Chart {
        ForEach(segments) { segment in
          BarMark(x: .value("Day", segment.date, unit: .day), y: .value("Weekly limit", segment.percent))
            .foregroundStyle(by: .value("Series", segment.series))
            .accessibilityLabel(segment.day + " " + segment.series)
            .accessibilityValue(percent(segment.percent))
        }
        if let selected {
          RuleMark(x: .value("Day", selected, unit: .day)).foregroundStyle(.secondary.opacity(0.4))
        }
      }
      .chartForegroundStyleScale(domain: order)
      .chartXSelection(value: WindowCapture.isActive ? .constant(nil) : $selected)
      .chartYAxis {
        AxisMarks(position: .leading) { value in
          AxisGridLine()
          AxisValueLabel { if let number = value.as(Double.self) { Text(percent(number)) } }
        }
      }
      .chartXAxis {
        AxisMarks(values: .automatic(desiredCount: 6)) { _ in
          AxisValueLabel(format: .dateTime.month(.abbreviated).day())
        }
      }
      .chartLegend(position: .bottom, alignment: .leading)
      .frame(height: 210)
      Text("Share of the weekly limit used each day, as reported by ChatGPT's Codex usage page (live limits).")
        .font(.caption).foregroundStyle(.secondary)
    }
  }

  private func tooltip(_ day: LimitUsageDay) -> String {
    let parts =
      grouping == .surface
      ? day.surfaces.prefix(3).map { "\(limitUsageSurfaceLabel($0.surface)) \(percent($0.usedPercent))" }
      : day.models.prefix(3).map { "\($0.model) \(percent($0.usedPercent))" }
    return ([day.date + " · " + percent(day.usedPercent)] + parts).joined(separator: " · ")
  }

  private func percent(_ value: Double) -> String {
    value.formatted(.number.locale(Locale(identifier: "en_US")).precision(.fractionLength(value < 10 ? 1 : 0))) + "%"
  }
}
