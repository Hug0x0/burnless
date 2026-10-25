// Menu bar extra adapted from Agent Burn's MenuPopover and HarnessView, in the
// layout of its site screenshots (https://github.com/Melvynx/agent-burn, MIT).

import BurnlessCore
import SwiftUI

struct MenuBarLabel: View {
  let remaining: Double?
  /// An old reading is marked "~" rather than shown as current.
  var stale = false
  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: "flame.fill")
      Text(remaining.map { (stale ? "~" : "") + "\(Int($0.rounded(.down)))%" } ?? "Burn").monospacedDigit()
    }
    .accessibilityLabel(
      "Burnless " + (remaining.map { "\(Int($0)) percent left" + (stale ? ", last reading may be out of date" : "") } ?? ""))
  }
}

enum PopoverTab: String, CaseIterable, Identifiable {
  case general, claude, codex, gemini
  var id: String { rawValue }
  var label: String {
    switch self {
    case .general: "General"
    case .codex: "Codex"
    case .claude: "Claude"
    case .gemini: "Gemini"
    }
  }
  var harness: Harness? {
    switch self {
    case .general: nil
    case .codex: .codex
    case .claude: .claude
    case .gemini: .gemini
    }
  }
}

struct MenuPopover: View {
  @Environment(UsageStore.self) private var store
  @Environment(\.openWindow) private var openWindow
  @State private var tab =
    PopoverTab(rawValue: ProcessInfo.processInfo.environment["BURNLESS_POPOVER_TAB"] ?? "") ?? .general

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Image(systemName: "flame.fill").font(.system(size: 18)).foregroundStyle(BurnTheme.accent)
          .accessibilityHidden(true)
        Text("Burnless").font(.system(size: 17, weight: .semibold)).foregroundStyle(BurnTheme.accent)
        Spacer()
        if store.isLoading || store.isCheckingQuotas {
          ProgressView().controlSize(.small).accessibilityLabel("Updating usage")
        }
        SettingsLink {
          Image(systemName: "gearshape").font(.system(size: 15))
        }
        .buttonStyle(.plain).foregroundStyle(BurnTheme.quotaMuted)
        .help("Settings").accessibilityLabel("Settings")
      }
      .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 14)
      Picker("Tab", selection: $tab.animation(.snappy(duration: 0.25))) {
        ForEach(PopoverTab.allCases) { Text($0.label).tag($0) }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .controlSize(.large)
      .fixedSize()
      .padding(.bottom, 16)
      ScrollView {
        Group {
          switch tab {
          case .general: CompactOverview(select: { tab = $0 })
          case .codex: CompactHarness(harness: .codex)
          case .claude: CompactHarness(harness: .claude)
          case .gemini: CompactHarness(harness: .gemini)
          }
        }
        .id(tab)
        .transition(.opacity.combined(with: .offset(y: 6)))
        .padding(.horizontal, 22).padding(.bottom, 18)
      }
      .scrollIndicators(.never)
      .frame(height: 520)
      Divider()
      VStack(spacing: 12) {
        PopoverFooter()
        HStack(spacing: 10) {
          Button {
            store.route = tab.harness.map(Route.harness) ?? .overview
            openWindow(id: "dashboard")
            NSApp.activate(ignoringOtherApps: true)
          } label: {
            HStack {
              Text("Open dashboard")
              Spacer()
              Image(systemName: "arrow.up.right")
            }
          }
          .buttonStyle(PopoverPillButtonStyle())
          Button {
            NSApp.terminate(nil)
          } label: {
            Image(systemName: "power").font(.system(size: 15))
          }
          .buttonStyle(.plain).foregroundStyle(BurnTheme.quotaMuted)
          .frame(width: 34)
          .help("Quit Burnless").accessibilityLabel("Quit Burnless")
        }
      }
      .padding(.horizontal, 18).padding(.vertical, 14)
    }
    .frame(width: 440)
    .background(.regularMaterial)
  }
}

private struct PopoverFooter: View {
  @Environment(UsageStore.self) private var store
  var body: some View {
    HStack(spacing: 7) {
      Circle().fill(store.lastError == nil ? Color.green : Color.orange).frame(width: 6, height: 6)
      if store.isDemo {
        Text("Demo data").foregroundStyle(BurnTheme.warning)
      } else if let date = store.snapshot?.refreshedAt {
        Text("Updated")
        Text(date, style: .relative)
        Text("ago")
      } else {
        Text("Waiting for usage")
      }
      Spacer()
      QuotaCheckButton()
      Button {
        store.refreshAll()
      } label: {
        Image(systemName: "arrow.clockwise").symbolEffect(.pulse, isActive: store.isLoading)
      }
      .buttonStyle(.plain).disabled(store.isLoading || store.isDemo)
      .help("Refresh usage and limits (⌘R)").accessibilityLabel("Refresh usage")
    }
    .font(.system(size: 13)).foregroundStyle(BurnTheme.quotaMuted)
    .padding(.horizontal, 4)
  }
}

private struct PopoverPillButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    PopoverPill(configuration: configuration)
  }
}

private struct PopoverPill: View {
  let configuration: ButtonStyle.Configuration
  @State private var hovering = false
  var body: some View {
    configuration.label
      .font(.system(size: 15, weight: .medium))
      .padding(.horizontal, 14).padding(.vertical, 10)
      .frame(maxWidth: .infinity)
      .background(
        hovering || configuration.isPressed ? BurnTheme.track : BurnTheme.hover,
        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
      .scaleEffect(configuration.isPressed ? 0.98 : 1)
      .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      .onHover { hovering = $0 }
      .animation(.easeOut(duration: 0.12), value: hovering)
  }
}

/// Two headline numbers side by side, as in the site's popover.
private struct PopoverMetric: View {
  let title: String
  let value: String
  let detail: String
  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title).font(.system(size: 13)).foregroundStyle(BurnTheme.quotaMuted)
      Text(value).font(.system(size: 28, weight: .semibold)).monospacedDigit()
        .lineLimit(1).minimumScaleFactor(0.6)
        .contentTransition(.numericText())
      Text(detail).font(.system(size: 12)).foregroundStyle(BurnTheme.quotaMuted).lineLimit(1)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }
}

/// General tab: spend, tokens, limits left and the harnesses.
private struct CompactOverview: View {
  @Environment(UsageStore.self) private var store
  let select: (PopoverTab) -> Void

  var body: some View {
    @Bindable var store = store
    let dashboard = store.dashboard(for: nil)
    VStack(alignment: .leading, spacing: 22) {
      HStack(spacing: 12) {
        OverviewMark(size: 34)
        VStack(alignment: .leading, spacing: 2) {
          Text("All harnesses").font(.system(size: 20, weight: .semibold))
          Text("Usage from your logs").font(.system(size: 13)).foregroundStyle(BurnTheme.quotaMuted)
        }
        Spacer()
        Picker("Period", selection: $store.period) {
          ForEach(Period.allCases) { Text($0.label).tag($0) }
        }
        .labelsHidden().fixedSize()
      }
      if store.snapshot == nil {
        Text(store.isLoading ? "Reading your local usage…" : "No usage report yet.")
          .font(.system(size: 14)).foregroundStyle(BurnTheme.quotaMuted)
          .frame(maxWidth: .infinity, minHeight: 160)
      } else {
        HStack(alignment: .top, spacing: 16) {
          PopoverMetric(title: "Total spend", value: Format.spend(dashboard.totals), detail: store.periodLabel(for: nil) + " · API-equivalent")
          PopoverMetric(title: "Tokens", value: Format.tokens(dashboard.totals.tokens.total), detail: "Input, output and cache")
        }
        VStack(alignment: .leading, spacing: 14) {
          Text("Weekly limit remaining").font(.system(size: 13)).foregroundStyle(BurnTheme.quotaMuted)
          ForEach(Harness.allCases.filter(\.readsLimits)) { harness in
            Button {
              withAnimation(.snappy) { select(PopoverTab(rawValue: harness.rawValue) ?? .general) }
            } label: {
              quotaRow(harness)
            }
            .buttonStyle(.plain)
          }
        }
        VStack(alignment: .leading, spacing: 12) {
          Text("By harness").font(.system(size: 13)).foregroundStyle(BurnTheme.quotaMuted)
          ForEach(dashboard.harnesses.sorted { $0.totals.cost > $1.totals.cost }) { summary in
            HStack(spacing: 12) {
              HarnessBadge(harness: summary.harness, size: 32)
              VStack(alignment: .leading, spacing: 2) {
                Text(summary.harness.name).font(.system(size: 14, weight: .semibold))
                Text(Format.tokens(summary.totals.tokens.total) + " tokens").font(.system(size: 12))
                  .foregroundStyle(BurnTheme.quotaMuted)
              }
              Spacer()
              Text(summary.availability.hasData ? Format.spend(summary.totals) : "—")
                .font(.system(size: 14, weight: .semibold))
            }
            .monospacedDigit()
            .accessibilityElement(children: .combine)
          }
        }
        Text("Spend is API-equivalent usage, not your subscription bill.")
          .font(.system(size: 12)).foregroundStyle(BurnTheme.quotaMuted)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func quotaRow(_ harness: Harness) -> some View {
    let remaining = store.remaining(harness)
    return VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 10) {
        HarnessBadge(harness: harness, size: 22)
        Text(harness.name).font(.system(size: 14, weight: .medium))
        Spacer()
        Text(remaining.map { (store.isStale(harness) ? "~" : "") + $0.formatted(.number.precision(.fractionLength(0))) + "%" } ?? "—")
          .font(.system(size: 17, weight: .semibold)).monospacedDigit()
          .foregroundStyle(store.isStale(harness) ? BurnTheme.quotaMuted : .primary)
          .help(store.isStale(harness) ? "Last reading may be out of date." : "")
          .contentTransition(.numericText())
      }
      ShareBar(value: (remaining ?? 0) / 100, tint: BurnTheme.tone(remaining: remaining ?? 0), height: 5)
    }
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(harness.name) " + (remaining.map { "\(Int($0)) percent remaining" } ?? "limit not read"))
  }
}

/// Harness tab: spend and plan, the weekly limit with its chart, and details.
private struct CompactHarness: View {
  @Environment(UsageStore.self) private var store
  let harness: Harness

  var body: some View {
    let plan = store.plan(for: harness)
    let now = store.clock
    let value = SubscriptionMath.value(store.snapshot, harness: harness, plan: plan, now: now, calendar: store.calendar)
    VStack(alignment: .leading, spacing: 22) {
      HStack(spacing: 14) {
        HarnessBadge(harness: harness, size: 40)
        VStack(alignment: .leading, spacing: 2) {
          Text(harness.name).font(.system(size: 22, weight: .semibold))
          Text(plan.name ?? "Subscription").font(.system(size: 14)).foregroundStyle(BurnTheme.quotaMuted)
        }
        Spacer()
        let status = store.quotaStatus(harness)
        StatusBadge(text: status.text, color: status.color)
      }
      HStack(alignment: .top, spacing: 16) {
        PopoverMetric(title: "30-day spend", value: Format.spend(value.apiEquivalent), detail: "API-equivalent")
        PopoverMetric(
          title: "Monthly plan", value: plan.pricePerMonth.map { Format.currency($0) } ?? "Unknown",
          detail: store.planDetail(harness))
      }
      if let forecast = store.weekly(harness) {
        let series: QuotaSeries = harness == .claude ? .claudeWeekly : .codexWeekly
        let samples = store.samples(series, range: .untilReset)
        VStack(alignment: .leading, spacing: 16) {
          if forecast.hasReset(at: now) {
            NoReadingSinceReset(harness: harness, reset: forecast.reset, compact: true)
          } else {
            RemainingHeadline(remaining: forecast.remaining, title: "Weekly limit")
            if forecast.isStale(at: now) { StaleReading(harness: harness, forecast: forecast, compact: true) }
            QuotaOutlookLabel(outlook: .make(forecast), compact: true)
            QuotaChartView(
              forecast: forecast, samples: samples, color: BurnTheme.color(for: harness),
              range: .untilReset, now: now, height: 200, compact: true)
            if samples.count < 3 {
              Text("Your quota history builds as Burnless refreshes.")
                .font(.system(size: 13)).foregroundStyle(BurnTheme.quotaMuted)
            }
          }
        }
        details(forecast: forecast, now: now)
      } else {
        VStack(alignment: .leading, spacing: 8) {
          if harness.readsLimits {
            Text(store.quota == nil ? "Reading limits…" : "Limit not read yet").font(.system(size: 20, weight: .semibold))
          }
          QuotaUnavailable(harness: harness)
        }
      }
    }
  }

  @ViewBuilder private func details(forecast: Forecast, now: Date) -> some View {
    VStack(spacing: 10) {
      if let session = store.forecast(harness == .claude ? .claudeSession : .codexShort), !session.hasReset(at: now) {
        detail(
          harness == .claude ? "5-hour session" : "\(Int((session.duration / 3600).rounded()))-hour limit",
          QuotaText.percent(session.remaining.rounded()) + " remaining")
      }
      if !forecast.hasReset(at: now) {
        detail("Resets in", QuotaText.duration(forecast.reset.timeIntervalSince(now)))
        detail("Suggested pace", QuotaText.percentOneDecimal(forecast.dailyAllowance(at: now)) + "\u{00A0}/ day")
      }
      if harness == .codex, let credits = store.quota?.codex.snapshot?.resetCreditsAvailable {
        detail("Banked resets", "\(credits)")
      }
      if let estimate = store.cycle(harness)?.estimate {
        detail("Avg $ / %", Format.currency(estimate.dollarsPerPercent) + " / %")
      }
    }
  }

  private func detail(_ title: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(title).foregroundStyle(BurnTheme.quotaMuted).lineLimit(1)
      Spacer(minLength: 12)
      Text(value).monospacedDigit().lineLimit(1)
    }
    .font(.system(size: 13))
  }
}
