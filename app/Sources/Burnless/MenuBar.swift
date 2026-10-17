// Menu bar extra adapted from Agent Burn's MenuPopover, OverviewView and
// CompactHarnessView (https://github.com/Melvynx/agent-burn, MIT).

import BurnlessCore
import SwiftUI

struct MenuBarLabel: View {
  let remaining: Double?
  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: "flame.fill")
      Text(remaining.map { "\(Int($0.rounded(.down)))%" } ?? "Burn").monospacedDigit()
    }
    .accessibilityLabel("Burnless " + (remaining.map { "\(Int($0)) percent left" } ?? ""))
  }
}

enum PopoverTab: String, CaseIterable, Identifiable {
  case general, codex, claude
  var id: String { rawValue }
  var label: String {
    switch self {
    case .general: "General"
    case .codex: "Codex"
    case .claude: "Claude"
    }
  }
  var harness: Harness? {
    switch self {
    case .general: nil
    case .codex: .codex
    case .claude: .claude
    }
  }
}

struct MenuPopover: View {
  @Environment(UsageStore.self) private var store
  @Environment(\.openWindow) private var openWindow
  @State private var tab = PopoverTab.general

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high)
          .frame(width: 26, height: 26).accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 1) {
          Text("Burnless").font(.system(size: 13, weight: .semibold))
          Text(
            store.settings.menuBarQuota.name + " "
              + (store.remaining(store.settings.menuBarQuota).map { "\(Int($0.rounded(.down)))% left" } ?? "limit not read")
          )
          .font(.system(size: 11)).foregroundStyle(BurnTheme.quotaMuted).monospacedDigit()
        }
        Spacer()
        if store.isLoading || store.isCheckingQuotas {
          ProgressView().controlSize(.small).accessibilityLabel("Updating usage")
        }
      }
      .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 14)
      PopoverTabs(selection: $tab).padding(.horizontal, 14).padding(.bottom, 14)
      ScrollView {
        Group {
          switch tab {
          case .general: CompactOverview(select: { tab = $0 })
          case .codex: CompactHarness(harness: .codex)
          case .claude: CompactHarness(harness: .claude)
          }
        }
        .id(tab)
        .transition(.opacity.combined(with: .offset(y: 6)))
        .padding(.horizontal, 14).padding(.bottom, 16)
      }
      .scrollIndicators(.never)
      .frame(height: 470)
      .animation(.smooth(duration: 0.25), value: tab)
      Divider()
      VStack(spacing: 10) {
        PopoverFooter()
        HStack(spacing: 8) {
          Button {
            store.route = tab.harness.map(Route.harness) ?? .overview
            openWindow(id: "dashboard")
            NSApp.activate(ignoringOtherApps: true)
          } label: {
            Label("Open dashboard", systemImage: "macwindow").frame(maxWidth: .infinity)
          }
          .buttonStyle(PopoverPillButtonStyle())
          SettingsLink { Image(systemName: "gearshape") }
            .buttonStyle(PopoverPillButtonStyle(square: true))
            .help("Settings").accessibilityLabel("Settings")
          Button {
            NSApp.terminate(nil)
          } label: {
            Label("Quit", systemImage: "power")
          }
          .buttonStyle(PopoverPillButtonStyle())
          .help("Quit Burnless")
        }
      }
      .padding(.horizontal, 14).padding(.vertical, 12)
    }
    .frame(width: 440)
    .background(.regularMaterial)
    .tint(BurnTheme.ember)
  }
}

private struct PopoverTabs: View {
  @Binding var selection: PopoverTab
  @Namespace private var pill

  var body: some View {
    HStack(spacing: 2) {
      ForEach(PopoverTab.allCases) { tab in
        let active = selection == tab
        Button {
          withAnimation(.snappy(duration: 0.28)) { selection = tab }
        } label: {
          HStack(spacing: 5) {
            if let harness = tab.harness {
              HarnessBadge(harness: harness, size: 13)
            } else {
              Image(systemName: "square.grid.2x2").font(.system(size: 10, weight: .semibold))
            }
            Text(tab.label)
          }
          .font(.system(size: 12, weight: active ? .semibold : .medium))
          .foregroundStyle(active ? Color.primary : BurnTheme.quotaMuted)
          .frame(maxWidth: .infinity).padding(.vertical, 6)
          .background {
            if active {
              RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(BurnTheme.card)
                .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                .matchedGeometryEffect(id: "pill", in: pill)
            }
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
      }
    }
    .padding(3)
    .background(BurnTheme.track, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }
}

private struct PopoverFooter: View {
  @Environment(UsageStore.self) private var store
  var body: some View {
    HStack(spacing: 7) {
      Circle().fill(store.lastError == nil ? Color.green : BurnTheme.ember).frame(width: 5, height: 5)
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
    .font(.system(size: 11)).foregroundStyle(BurnTheme.quotaMuted)
  }
}

private struct PopoverPillButtonStyle: ButtonStyle {
  var square = false
  func makeBody(configuration: Configuration) -> some View {
    PopoverPill(configuration: configuration, square: square)
  }
}

private struct PopoverPill: View {
  let configuration: ButtonStyle.Configuration
  let square: Bool
  @State private var hovering = false
  var body: some View {
    configuration.label
      .font(.system(size: 12, weight: .medium))
      .padding(.horizontal, square ? 0 : 12).padding(.vertical, 8)
      .frame(width: square ? 34 : nil)
      .background(
        hovering || configuration.isPressed ? BurnTheme.track : BurnTheme.hover,
        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(BurnTheme.cardStroke, lineWidth: 1))
      .scaleEffect(configuration.isPressed ? 0.97 : 1)
      .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
      .onHover { hovering = $0 }
      .animation(.easeOut(duration: 0.12), value: hovering)
  }
}

/// General tab: spend, tokens, limits left, busiest harnesses and top models.
private struct CompactOverview: View {
  @Environment(UsageStore.self) private var store
  let select: (PopoverTab) -> Void

  var body: some View {
    @Bindable var store = store
    let dashboard = store.dashboard(for: nil)
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Overview").font(.system(size: 15, weight: .semibold))
        Spacer()
        Picker("Period", selection: $store.period) {
          ForEach(Period.allCases) { Text($0.label).tag($0) }
        }
        .labelsHidden().frame(width: 130).controlSize(.small)
      }
      .padding(.horizontal, 4)
      if store.snapshot == nil {
        Text(store.isLoading ? "Reading your local usage…" : "No usage report yet.")
          .font(.system(size: 13)).foregroundStyle(BurnTheme.quotaMuted)
          .frame(maxWidth: .infinity, minHeight: 160).burnCard(padding: 12, radius: 12)
      } else {
        HStack(spacing: 10) {
          MetricTile(
            title: "Spend", value: Format.spend(dashboard.totals), detail: "API-equivalent · \(store.period.label)",
            symbol: "dollarsign"
          )
          .burnCard(padding: 12, radius: 12)
          MetricTile(
            title: "Tokens", value: Format.tokens(dashboard.totals.tokens.total),
            detail: "Input, output and cache", symbol: "square.stack.3d.up.fill", tint: .blue
          )
          .burnCard(padding: 12, radius: 12)
        }
        quotas
        busiest(dashboard)
        if !dashboard.models.isEmpty {
          VStack(alignment: .leading, spacing: 10) {
            CardHeader(title: "Top models", symbol: "cpu", tint: .purple) { Text("\(dashboard.models.count) models") }
            ForEach(Array(dashboard.models.prefix(3))) { model in
              HStack(spacing: 10) {
                Text(model.displayName).lineLimit(1).help(model.displayName)
                Spacer()
                Text(Format.tokens(model.tokenCount)).foregroundStyle(BurnTheme.quotaMuted)
                Text(Format.spend(model.totals)).fontWeight(.medium).frame(minWidth: 72, alignment: .trailing)
              }
              .font(.system(size: 12)).monospacedDigit()
            }
          }
          .burnCard(padding: 12, radius: 12)
        }
        Label("API-equivalent usage estimates token value, not your subscription bill.", systemImage: "info.circle")
          .font(.system(size: 11)).foregroundStyle(BurnTheme.quotaMuted)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 4)
      }
    }
  }

  @ViewBuilder private var quotas: some View {
    let items = Harness.allCases.compactMap { harness in store.remaining(harness).map { (harness, $0) } }
    if !items.isEmpty {
      VStack(alignment: .leading, spacing: 10) {
        CardHeader(title: "Quota remaining", symbol: "gauge.with.dots.needle.67percent", tint: .green)
        HStack(spacing: 8) {
          ForEach(items, id: \.0) { harness, remaining in
            Button {
              withAnimation(.snappy) { select(harness == .codex ? .codex : .claude) }
            } label: {
              VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 5) {
                  HarnessBadge(harness: harness, size: 14)
                  Text(harness == .claude ? "Claude" : "Codex").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(BurnTheme.quotaMuted)
                }
                Text(QuotaText.percentOneDecimal(remaining))
                  .font(.system(size: 19, weight: .semibold, design: .rounded)).monospacedDigit()
                  .contentTransition(.numericText())
                ShareBar(value: remaining / 100, tint: BurnTheme.tone(remaining: remaining), height: 4)
              }
              .padding(9)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(BurnTheme.hover, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
              .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(harness.name) \(Int(remaining)) percent remaining")
          }
        }
      }
      .burnCard(padding: 12, radius: 12)
    }
  }

  private func busiest(_ dashboard: Dashboard) -> some View {
    let top = max(dashboard.harnesses.map(\.totals.cost).max() ?? 0, 0.01)
    return VStack(alignment: .leading, spacing: 6) {
      CardHeader(title: "Busiest agents", symbol: "flame.fill") { Text(store.period.label) }
        .padding(.bottom, 4)
      ForEach(dashboard.harnesses.sorted { $0.totals.cost > $1.totals.cost }) { summary in
        Button {
          withAnimation(.snappy) { select(summary.harness == .codex ? .codex : .claude) }
        } label: {
          HStack(spacing: 10) {
            HarnessBadge(harness: summary.harness, size: 22)
            VStack(alignment: .leading, spacing: 5) {
              HStack {
                Text(summary.harness.name).font(.system(size: 12, weight: .medium))
                Spacer()
                Text(Format.tokens(summary.totals.tokens.total)).font(.system(size: 11))
                  .foregroundStyle(BurnTheme.quotaMuted)
                Text(Format.spend(summary.totals)).font(.system(size: 12, weight: .semibold))
                  .frame(minWidth: 72, alignment: .trailing)
              }
              ShareBar(value: summary.totals.cost / top, tint: BurnTheme.color(for: summary.harness), height: 4)
            }
          }
          .monospacedDigit()
        }
        .buttonStyle(.plain)
        .hoverRow()
        .padding(.horizontal, -8)
      }
    }
    .burnCard(padding: 12, radius: 12)
  }
}

/// Harness tab: weekly limit with its chart and the usage details.
private struct CompactHarness: View {
  @Environment(UsageStore.self) private var store
  let harness: Harness
  @State private var showsDetails = false

  var body: some View {
    let plan = store.plan(for: harness)
    let now = store.clock
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 14) {
        HStack(spacing: 8) {
          HarnessBadge(harness: harness, size: 22)
          Text(harness.name).font(.system(size: 13, weight: .semibold))
          Spacer()
          Text(plan.name ?? "Subscription")
            .font(.system(size: 11, weight: .medium)).foregroundStyle(BurnTheme.quotaMuted).lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(BurnTheme.track, in: Capsule())
        }
        if let forecast = store.weekly(harness), !forecast.hasReset(at: now) {
          HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
              Text("Weekly remaining").font(.system(size: 12)).foregroundStyle(BurnTheme.quotaMuted)
              Text(QuotaText.percentOneDecimal(forecast.remaining))
                .font(.system(size: 44, weight: .semibold, design: .rounded)).monospacedDigit()
                .contentTransition(.numericText()).lineLimit(1).minimumScaleFactor(0.7)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
              if let text = QuotaText.pace(forecast.paceDelta) {
                StatusBadge(text: text, color: forecast.paceDelta < -0.05 ? BurnTheme.behind : BurnTheme.ahead)
              }
              Text("Reset in " + QuotaText.duration(forecast.reset.timeIntervalSince(now)))
                .font(.system(size: 12)).foregroundStyle(BurnTheme.quotaMuted)
              Text(forecast.reset.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                .font(.system(size: 12)).foregroundStyle(BurnTheme.quotaMuted).monospacedDigit()
              if harness == .codex, let credits = store.quota?.codex.snapshot?.resetCreditsAvailable {
                Text(credits == 1 ? "1 reset" : "\(credits) resets").font(.system(size: 12, weight: .medium))
              }
            }
          }
          ShareBar(
            value: forecast.remaining / 100,
            tint: forecast.paceDelta < -0.05 ? BurnTheme.behind : BurnTheme.ahead, height: 5)
          QuotaChartView(
            forecast: forecast,
            samples: store.samples(harness == .claude ? .claudeWeekly : .codexWeekly, range: .untilReset),
            color: BurnTheme.color(for: harness), range: .untilReset, now: now, height: 176, compact: true)
          if let session = store.forecast(harness == .claude ? .claudeSession : .codexShort), !session.hasReset(at: now) {
            HStack {
              Text(harness == .claude ? "5-hour session" : "\(Int((session.duration / 3600).rounded()))-hour limit")
                .foregroundStyle(BurnTheme.quotaMuted)
              Spacer()
              Text(QuotaText.percent(session.remaining.rounded()) + " remaining").monospacedDigit()
            }
            .font(.system(size: 12))
          }
        } else {
          VStack(alignment: .leading, spacing: 8) {
            Text(store.quota == nil ? "Reading limits…" : "Limit not read yet").font(.system(size: 20, weight: .semibold))
            QuotaUnavailable(harness: harness)
          }
          .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        }
      }
      .burnCard(padding: 14, radius: 12)

      DisclosureGroup("Usage details", isExpanded: $showsDetails) {
        let value = SubscriptionMath.value(store.snapshot, harness: harness, plan: plan, now: now, calendar: store.calendar)
        let cycle = store.cycle(harness)
        VStack(alignment: .leading, spacing: 12) {
          detail("API-equivalent · 30 days", Format.spend(value.apiEquivalent))
          if let price = plan.pricePerMonth { detail("Monthly plan", Format.currency(price, wholeDollars: true)) }
          if let multiple = value.valueMultiple { detail("Subscription value", Format.multiple(multiple)) }
          if let forecast = cycle?.forecast {
            detail("Suggested daily pace", QuotaText.percentOneDecimal(forecast.dailyAllowance) + "\u{00A0}/ day")
          }
          if let estimate = cycle?.estimate {
            detail("Avg $ / %", Format.currency(estimate.dollarsPerPercent) + " / %")
            if let rate = estimate.tokensPerDollar { detail("Avg tokens / $", Format.tokens(UInt64(rate)) + " / $") }
          }
          ForEach(Array(store.dashboard(for: harness).models.prefix(2))) { model in
            detail(model.displayName, Format.spend(model.totals))
          }
        }
        .padding(.top, 12)
      }
      .font(.system(size: 12, weight: .medium)).tint(BurnTheme.quotaMuted)
      .burnCard(padding: 12, radius: 12)
    }
  }

  private func detail(_ title: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(title).foregroundStyle(BurnTheme.quotaMuted).lineLimit(1)
      Spacer(minLength: 12)
      Text(value).monospacedDigit().lineLimit(1)
    }
    .font(.system(size: 12))
  }
}
