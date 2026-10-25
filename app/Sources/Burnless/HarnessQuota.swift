// Subscription limits in the layout of Agent Burn's site screenshots and its
// HarnessView (https://github.com/Melvynx/agent-burn, MIT): a large remaining
// share, a one-line verdict, the facts of the window and the quota chart.

import BurnlessCore
import SwiftUI

/// Whether the limit lasts until it resets, in Agent Burn's words.
struct QuotaOutlook: Equatable {
  enum Tone { case good, ahead, reached }
  let tone: Tone
  let headline: String
  let detail: String

  static func make(_ forecast: Forecast) -> QuotaOutlook {
    if forecast.remaining <= 0 {
      return QuotaOutlook(
        tone: .reached, headline: "Limit reached",
        detail: "It resets " + forecast.reset.formatted(.dateTime.weekday(.abbreviated).hour().minute()) + ".")
    }
    guard forecast.projectedUse != nil else {
      return QuotaOutlook(
        tone: .good, headline: "Room to keep building",
        detail: "A forecast will appear once this window has recorded usage.")
    }
    if forecast.runsOut {
      let early = QuotaText.duration(forecast.reset.timeIntervalSince(forecast.projectedEnd))
      return QuotaOutlook(
        tone: .ahead, headline: "A little ahead of pace",
        detail: "At this pace, the limit may run out \(early) before it resets.")
    }
    return QuotaOutlook(
      tone: .good, headline: "Room to keep building",
      detail: "Your current pace should carry you through the reset.")
  }

  var color: Color {
    switch tone {
    case .good: BurnTheme.ahead
    case .ahead: .orange
    case .reached: BurnTheme.behind
    }
  }

  var symbol: String {
    switch tone {
    case .good: "checkmark.circle"
    case .ahead: "gauge.with.dots.needle.67percent"
    case .reached: "xmark.octagon"
    }
  }
}

struct QuotaOutlookLabel: View {
  let outlook: QuotaOutlook
  var compact = false
  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Label(outlook.headline, systemImage: outlook.symbol)
        .font(.system(size: compact ? 14 : 13, weight: .medium))
        .foregroundStyle(outlook.color)
      Text(outlook.detail)
        .font(.system(size: compact ? 13 : 12)).foregroundStyle(compact ? BurnTheme.quotaMuted : BurnTheme.muted)
        .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .combine)
  }
}

/// "64 % remaining", the site's headline number.
struct RemainingHeadline: View {
  let remaining: Double
  var title: String? = nil
  var size: CGFloat = 64
  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(remaining.formatted(.number.precision(.fractionLength(0))))
        .font(.system(size: size, weight: .medium)).monospacedDigit()
        .contentTransition(.numericText()).animation(.snappy, value: remaining)
        .lineLimit(1)
      Text("% remaining").font(.system(size: size * 0.27)).foregroundStyle(BurnTheme.muted)
        .lineLimit(1).fixedSize()
      if let title {
        Spacer(minLength: 8)
        Text(title).font(.system(size: 13)).foregroundStyle(BurnTheme.muted).lineLimit(1)
      }
    }
    .accessibilityElement(children: .combine)
  }
}

/// One limit window on a harness page: headline and facts on the left, the
/// chart on the right.
struct QuotaHero: View {
  @Environment(UsageStore.self) private var store
  let title: String
  let series: QuotaSeries
  let harness: Harness
  /// Weekly windows follow the chart range setting; sessions stay until reset.
  var followsRange = true
  /// Stacks the chart under the details so two heroes fit side by side.
  var stacked = false
  /// Lets a grid place the details and chart in separate rows.
  var part = Part.all

  enum Part { case all, details, chart }

  var body: some View {
    if let forecast = store.forecast(series) {
      switch part {
      case .details: details(forecast).frame(maxWidth: .infinity, alignment: .topLeading)
      case .chart: chart(forecast)
      case .all:
        let layout = stacked
          ? AnyLayout(VStackLayout(alignment: .leading, spacing: 18))
          : AnyLayout(HStackLayout(alignment: .top, spacing: 36))
        layout {
          details(forecast)
            .frame(maxWidth: stacked ? .infinity : 300, alignment: .leading)
          chart(forecast)
        }
      }
    }
  }

  private func details(_ forecast: Forecast) -> some View {
    let now = store.clock
    return VStack(alignment: .leading, spacing: 16) {
          HStack(spacing: 8) {
            Text(title).font(.system(size: 13)).foregroundStyle(BurnTheme.muted)
            Spacer(minLength: 4)
            QuotaFreshness(forecast: forecast, now: now)
              .font(.system(size: 11)).foregroundStyle(BurnTheme.muted)
          }
          if forecast.hasReset(at: now) {
            NoReadingSinceReset(harness: harness, reset: forecast.reset)
          } else {
            RemainingHeadline(remaining: forecast.remaining)
            if forecast.isStale(at: now) { StaleReading(harness: harness, forecast: forecast) }
            QuotaOutlookLabel(outlook: .make(forecast))
            QuotaFacts(forecast: forecast, series: series, harness: harness)
          }
    }
  }

  private func chart(_ forecast: Forecast) -> some View {
    @Bindable var settings = store.settings
    let now = store.clock
    let range = followsRange ? settings.quotaChartRange : .untilReset
    return VStack(alignment: .trailing, spacing: 8) {
      if followsRange { QuotaRangePicker(range: $settings.quotaChartRange) }
      if !forecast.hasReset(at: now) {
        QuotaChartView(
          forecast: forecast, samples: store.samples(series, range: range),
          color: BurnTheme.color(for: harness), range: range, now: now, height: stacked ? 200 : 240)
      }
    }
    .frame(maxWidth: .infinity)
  }
}

/// Reset time, recorded resets, suggested pace and value per percent.
struct QuotaFacts: View {
  @Environment(UsageStore.self) private var store
  let forecast: Forecast
  let series: QuotaSeries
  let harness: Harness

  var body: some View {
    let short = forecast.duration <= 86_400
    let resets = store.resets(series)
    VStack(spacing: 11) {
      row("Resets around", "clock", forecast.reset.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
      if short {
        let hours = max(1 / 60, forecast.reset.timeIntervalSince(max(store.clock, forecast.observedAt)) / 3600)
        row("Suggested pace", "speedometer", QuotaText.percentOneDecimal(forecast.remaining / hours) + "\u{00A0}/ hour", tint: BurnTheme.color(for: harness))
      } else {
        row("Suggested pace", "speedometer", QuotaText.percentOneDecimal(forecast.dailyAllowance) + "\u{00A0}/ day", tint: BurnTheme.color(for: harness))
        row("Recorded resets", "arrow.counterclockwise", resetSummary(resets))
          .help("Resets seen in Burnless's readings. A mid-window reset is a manual reset or a provider correction.")
        if harness == .codex, let credits = store.quota?.codex.snapshot?.resetCreditsAvailable {
          row("Banked resets", "arrow.uturn.backward.circle", "\(credits)")
            .help("Codex rate-limit resets you can redeem now.")
        }
        if let estimate = store.cycle(harness)?.estimate {
          row("Avg $ / %", "dollarsign.circle", Format.currency(estimate.dollarsPerPercent) + " / %")
            .help("API-equivalent spend this window divided by the share of the limit it used.")
        }
      }
    }
    .font(.system(size: 12)).monospacedDigit()
    .padding(14)
    .background(BurnTheme.inset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }

  private func resetSummary(_ resets: [QuotaReset]) -> String {
    if resets.isEmpty { return "None yet" }
    let scheduled = resets.filter(\.scheduled).count
    return scheduled == resets.count ? "\(resets.count) scheduled" : "\(scheduled) scheduled · \(resets.count - scheduled) possible"
  }

  private func row(_ title: String, _ symbol: String, _ value: String, tint: Color? = nil) -> some View {
    HStack {
      Label(title, systemImage: symbol).foregroundStyle(BurnTheme.muted)
      Spacer(minLength: 8)
      Text(value).foregroundStyle(tint ?? .primary).lineLimit(1)
    }
    .accessibilityElement(children: .combine)
  }
}

/// The subscription block at the top of a harness page.
struct HarnessQuotaCard: View {
  @Environment(UsageStore.self) private var store
  let harness: Harness

  var body: some View {
    let plan = store.plan(for: harness)
    let now = store.clock
    let value = SubscriptionMath.value(store.snapshot, harness: harness, plan: plan, now: now, calendar: store.calendar)
    let weekly = store.weekly(harness)
    let session = harness == .claude ? store.forecast(.claudeSession) : nil
    VStack(alignment: .leading, spacing: 24) {
      HStack(alignment: .top, spacing: 20) {
        SpendMetric(title: "Total spend", value: Format.spend(value.apiEquivalent), detail: "Past 30 days · API-equivalent")
        SpendMetric(
          title: "Monthly plan", value: plan.pricePerMonth.map { Format.currency($0) } ?? "Unknown",
          detail: plan.ignoredOverride != nil
            ? "Override not recognized · see Settings"
            : plan.name.map { $0 + (plan.isOverride ? " · set in Settings" : "") } ?? "Not detected")
        SpendMetric(title: "Subscription value", value: value.valueMultiple.map(Format.multiple) ?? "—", detail: "Usage / monthly price")
        Spacer(minLength: 0)
        VStack(alignment: .trailing, spacing: 10) {
          StatusBadge(text: status.text, color: status.color)
          QuotaCheckButton(label: true).font(.system(size: 12)).foregroundStyle(BurnTheme.muted)
        }
      }
      if let notice = liveNotice { Notice(message: notice, kind: .warning) }
      if weekly == nil && session == nil {
        Rectangle().fill(BurnTheme.line).frame(height: 1)
        QuotaUnavailable(harness: harness)
          .frame(minHeight: harness.readsLimits ? 90 : nil)
      } else {
        Rectangle().fill(BurnTheme.line).frame(height: 1)
        let weeklySeries: QuotaSeries = harness == .claude ? .claudeWeekly : .codexWeekly
        if weekly != nil && session != nil {
          // Two grid rows keep both charts on the same baseline.
          Grid(alignment: .topLeading, horizontalSpacing: 28, verticalSpacing: 18) {
            GridRow {
              QuotaHero(title: "Weekly limit", series: weeklySeries, harness: harness, stacked: true, part: .details)
              divider
              QuotaHero(title: "5-hour session", series: .claudeSession, harness: harness, followsRange: false, stacked: true, part: .details)
            }
            GridRow(alignment: .bottom) {
              QuotaHero(title: "Weekly limit", series: weeklySeries, harness: harness, stacked: true, part: .chart)
              divider
              QuotaHero(title: "5-hour session", series: .claudeSession, harness: harness, followsRange: false, stacked: true, part: .chart)
            }
          }
        } else if weekly != nil {
          QuotaHero(title: "Weekly limit", series: weeklySeries, harness: harness)
        } else {
          QuotaHero(title: "5-hour session", series: .claudeSession, harness: harness, followsRange: false)
        }
      }
      secondary(now: now)
    }
    .burnCard(padding: 22)
  }

  private var divider: some View {
    Rectangle().fill(BurnTheme.line).frame(width: 1).frame(maxHeight: .infinity)
  }

  private var status: (text: String, color: Color) {
    guard harness.readsLimits else { return ("Usage only", .secondary) }
    if store.quotaError != nil { return ("Needs attention", .orange) }
    guard let forecast = store.weekly(harness) ?? store.forecast(.claudeSession) else { return ("Not read yet", .secondary) }
    return forecast.isLive ? ("Live", BurnTheme.ahead) : ("Local snapshot", BurnTheme.color(for: harness))
  }

  @ViewBuilder private func secondary(now: Date) -> some View {
    let rows = secondaryRows(now: now)
    if !rows.isEmpty {
      VStack(spacing: 12) {
        ForEach(rows.indices, id: \.self) { rows[$0] }
      }
    }
  }

  private func secondaryRows(now: Date) -> [AnyView] {
    var rows: [AnyView] = []
    let tint = BurnTheme.color(for: harness)
    if harness == .codex, let short = store.forecast(.codexShort), !short.hasReset(at: now) {
      rows.append(AnyView(ClaudeMeterRow(
        title: "\(Int((short.duration / 3600).rounded()))-hour limit", used: short.usedPercent, tint: tint,
        detail: "resets in " + QuotaText.duration(short.reset.timeIntervalSince(now)))))
    }
    if harness == .claude, let account = store.quota?.claude.account {
      for limit in account.scoped {
        rows.append(AnyView(ClaudeMeterRow(title: limit.name + " · weekly", used: limit.usedPercent, tint: tint)))
      }
      if let extra = account.extra, extra.isRelevant {
        rows.append(AnyView(ClaudeMeterRow(
          title: "Extra usage", used: extra.resolvedUsedPercent, tint: tint,
          value: extra.usedUSD.map { used in
            extra.limitUSD.map { Format.currency(max(0, $0 - used)) + " left" } ?? Format.currency(used) + " used"
          },
          detail: extra.limitUSD.map { "of " + Format.currency($0) + " limit" })))
      }
    }
    return rows
  }

  private var liveNotice: String? {
    guard harness == .claude, store.settings.liveQuotas, let live = store.quota?.claude.live else { return nil }
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
