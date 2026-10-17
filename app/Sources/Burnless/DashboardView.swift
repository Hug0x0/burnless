// Dashboard composition follows Agent Burn's NativeUsageView
// (https://github.com/Melvynx/agent-burn, MIT): metrics on top, spend and
// By harness in the middle, models below.

import BurnlessCore
import SwiftUI

struct DashboardView: View {
  @Environment(UsageStore.self) private var store
  let harness: Harness?

  var body: some View {
    let dashboard = store.dashboard(for: harness)
    VStack(alignment: .leading, spacing: 14) {
      notices(dashboard)
      if store.snapshot == nil {
        placeholder
      } else if !dashboard.hasAnyHistory {
        noHistory(dashboard)
      } else {
        MetricStrip(dashboard: dashboard)
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .top, spacing: 14) {
            chartCard(dashboard).frame(minWidth: 480)
            if harness == nil { ByHarnessCard(dashboard: dashboard).frame(width: 280) }
          }
          .fixedSize(horizontal: false, vertical: true)
          VStack(spacing: 14) {
            chartCard(dashboard)
            if harness == nil { ByHarnessCard(dashboard: dashboard) }
          }
        }
        ModelsCard(dashboard: dashboard)
        TokenBreakdownCard(totals: dashboard.totals)
        footnote(dashboard)
      }
    }
  }

  private func chartCard(_ dashboard: Dashboard) -> some View {
    @Bindable var store = store
    return SpendChart(dashboard: dashboard, calendar: store.calendar, granularity: $store.granularity)
      .burnCard()
  }

  @ViewBuilder private func notices(_ dashboard: Dashboard) -> some View {
    if store.isDemo {
      Notice(
        message: "Demo mode: every number on this screen is generated sample data, not your usage.",
        kind: .warning, symbol: "theatermasks")
    }
    if let error = store.lastError {
      Notice(
        message: store.snapshot == nil
          ? error : "\(error) Showing the last saved data.",
        kind: .warning)
    }
    ForEach(dashboard.stale, id: \.self) { source in
      if case .stale(let lastSuccess, let reason) = store.snapshot?.availability(source) {
        Notice(
          message:
            "\(source.name) could not be read (\(reason)). Showing data saved \(lastSuccess.formatted(.relative(presentation: .named)))."
          , kind: .warning)
      }
    }
    if dashboard.harness == nil, dashboard.unavailable.count == 1, let source = dashboard.unavailable.first,
      dashboard.hasAnyHistory
    {
      Notice(message: "\(source.name): \(availabilityText(store.snapshot?.availability(source))). Totals include \(Harness.allCases.first { $0 != source }!.name) only.")
    }
  }

  private var placeholder: some View {
    ContentUnavailableView {
      if store.isLoading || !store.didLoad {
        Label("Reading local history…", systemImage: "hourglass")
      } else {
        Label("No usage report", systemImage: "chart.bar.xaxis")
      }
    } description: {
      Text(
        store.isLoading || !store.didLoad
          ? "Burnless is reading your Claude Code and Codex logs on this Mac."
          : "Check the source folders in Settings, then refresh.")
    }
    .frame(maxWidth: .infinity, minHeight: 420)
  }

  private func noHistory(_ dashboard: Dashboard) -> some View {
    VStack(spacing: 16) {
      ContentUnavailableView {
        Label("No history detected", systemImage: "folder.badge.questionmark")
      } description: {
        Text(
          dashboard.scope.map { "\($0.name): \(availabilityText(store.snapshot?.availability($0)))" }
            .joined(separator: "\n"))
      } actions: {
        Button("Open Settings") { store.route = .settings }
      }
    }
    .frame(maxWidth: .infinity, minHeight: 420)
  }

  private func footnote(_ dashboard: Dashboard) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Label(
        "API-equivalent usage estimates token value, not your subscription bill.",
        systemImage: "info.circle")
      Spacer()
      if let first = store.calendar.date(dashboard.lowerKey),
        let last = store.calendar.date(dashboard.upperKey)
      {
        Text(
          first.formatted(.dateTime.month(.abbreviated).day().year()) + " – "
            + last.formatted(.dateTime.month(.abbreviated).day().year()))
      }
    }
    .font(.caption).foregroundStyle(.secondary)
  }
}

func availabilityText(_ availability: SourceAvailability?) -> String {
  switch availability {
  case .live: "read successfully"
  case .stale(_, let reason): "showing saved data (\(reason))"
  case .notFound: "history folder not found"
  case .failed(let reason): "could not be read (\(reason))"
  case nil: "not read yet"
  }
}

private struct MetricStrip: View {
  let dashboard: Dashboard
  @State private var showTokens = false

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: 16) {
        spend
        Divider()
        tokens
        Divider()
        rate
        Divider()
        models
        Divider()
        days
      }
      Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 14) {
        GridRow {
          spend
          tokens
        }
        GridRow {
          rate
          models
        }
        GridRow { days }
      }
    }
    .fixedSize(horizontal: false, vertical: true)
    .burnCard(padding: 16)
  }

  private var spend: some View {
    MetricTile(
      title: "Total spend", value: Format.spend(dashboard.totals),
      detail: dashboard.totals.isPartial ? "API-equivalent value · partial" : "API-equivalent value",
      symbol: "dollarsign"
    )
    .help(
      dashboard.totals.isPartial
        ? "Known value only. \(Format.fullTokens(dashboard.totals.unpricedTokens)) tokens use models without a price in the pricing snapshot, so the full API-equivalent value is higher."
        : "Estimated cost of these tokens at public API prices.")
  }

  private var tokens: some View {
    MetricTile(
      title: "Tokens", value: Format.tokens(dashboard.totals.tokens.total),
      detail: "Input, output and cache", symbol: "square.stack.3d.up.fill", tint: .blue
    ) {
      Button {
        showTokens.toggle()
      } label: {
        Image(systemName: "info.circle")
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .help("Show token breakdown")
      .accessibilityLabel("Show token breakdown")
      .popover(isPresented: $showTokens, arrowEdge: .bottom) {
        TokenPopover(tokens: dashboard.totals.tokens)
      }
    }
  }

  /// Agent Burn's "Avg tokens / $": priced tokens per known dollar.
  private var rate: some View {
    let priced = dashboard.totals.tokens.total - dashboard.totals.unpricedTokens
    let value = dashboard.totals.cost > 0 && priced > 0 ? Double(priced) / dashboard.totals.cost : nil
    return MetricTile(
      title: "Avg tokens / $", value: value.map { Format.tokens(UInt64($0.rounded())) + " / $" } ?? "—",
      detail: dashboard.period.label, symbol: "gauge.with.dots.needle.50percent", tint: .green
    )
    .help("Tokens with a known price divided by their API-equivalent spend.")
  }

  private var models: some View {
    MetricTile(
      title: "Models", value: dashboard.models.filter { $0.model != nil }.count.formatted(),
      detail: dashboard.harness?.name ?? "Across all harnesses", symbol: "cpu", tint: .purple
    )
    .help("Distinct models observed in this period's local history.")
  }

  private var days: some View {
    MetricTile(
      title: "Days recorded", value: dashboard.daysRecorded.formatted(), detail: "All time",
      symbol: "calendar", tint: .green
    )
    .help("Distinct days with recorded usage in all available history. Not affected by the period filter.")
  }
}

private struct TokenPopover: View {
  let tokens: TokenBreakdown
  var body: some View {
    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
      ForEach(tokenParts(tokens), id: \.label) { part in
        GridRow {
          HStack(spacing: 6) {
            Circle().fill(part.color).frame(width: 7, height: 7)
            Text(part.label)
          }
          Text(Format.fullTokens(part.value)).gridColumnAlignment(.trailing)
        }
      }
      Divider()
      GridRow {
        Text("Total").fontWeight(.semibold)
        Text(Format.fullTokens(tokens.total)).fontWeight(.semibold)
      }
      if tokens.reasoning > 0 {
        GridRow {
          Text("of which reasoning (Codex)").foregroundStyle(.secondary)
          Text(Format.fullTokens(tokens.reasoning)).foregroundStyle(.secondary)
        }
      }
    }
    .font(.system(size: 12)).monospacedDigit()
    .padding(14)
  }
}

func tokenParts(_ tokens: TokenBreakdown) -> [(label: String, value: UInt64, color: Color)] {
  [
    ("Input", tokens.input, .blue),
    ("Output", tokens.output, BurnTheme.ember),
    ("Cache write", tokens.cacheWrite, .purple),
    ("Cache read", tokens.cacheRead, .teal),
  ]
}

private struct ByHarnessCard: View {
  @Environment(UsageStore.self) private var store
  let dashboard: Dashboard

  var body: some View {
    let top = max(dashboard.harnesses.map(\.totals.cost).max() ?? 0, 0.01)
    VStack(alignment: .leading, spacing: 10) {
      CardHeader(title: "By harness", symbol: "square.split.2x1.fill") {
        Text("\(dashboard.harnesses.filter { $0.availability.hasData }.count) of 2 available")
      }
      VStack(spacing: 2) {
        ForEach(dashboard.harnesses.sorted { $0.totals.cost > $1.totals.cost }) { summary in
          Button {
            store.route = .harness(summary.harness)
          } label: {
            HStack(spacing: 10) {
              HarnessBadge(harness: summary.harness, size: 26)
              VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                  Text(summary.harness.name).font(.system(size: 12, weight: .medium))
                  Spacer()
                  Text(summary.availability.hasData ? Format.spend(summary.totals) : "—")
                    .font(.system(size: 12, weight: .semibold))
                }
                ShareBar(
                  value: summary.totals.cost / top, tint: BurnTheme.color(for: summary.harness),
                  height: 4)
                Text(caption(summary)).font(.system(size: 10)).foregroundStyle(.secondary)
              }
              Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            }
            .monospacedDigit()
          }
          .buttonStyle(.plain)
          .hoverRow()
          .help("Open \(summary.harness.name)")
          .accessibilityLabel(
            "\(summary.harness.name), \(Format.spend(summary.totals)), \(Format.tokens(summary.totals.tokens.total)) tokens")
          .accessibilityHint("Opens the \(summary.harness.name) dashboard")
        }
      }
      .padding(.horizontal, -8)
      Spacer(minLength: 0)
    }
    .frame(maxHeight: .infinity, alignment: .top)
    .burnCard()
  }

  private func caption(_ summary: HarnessSummary) -> String {
    switch summary.availability {
    case .live: Format.tokens(summary.totals.tokens.total) + " tokens"
    case .stale: Format.tokens(summary.totals.tokens.total) + " tokens · saved data"
    case .notFound: "History not found"
    case .failed: "Could not be read"
    }
  }
}

private struct ModelsCard: View {
  let dashboard: Dashboard
  @State private var search = ""
  @State private var order = [KeyPathComparator(\ModelSummary.cost, order: .reverse)]

  private var filtered: [ModelSummary] {
    dashboard.models
      .filter { search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search) }
      .sorted(using: order)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      CardHeader(title: "Models", symbol: "cpu", tint: .purple) {
        HStack(spacing: 10) {
          Text("\(dashboard.models.count) · Available source data")
          HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
            TextField("Filter models", text: $search).textFieldStyle(.plain)
              .font(.system(size: 12))
              .accessibilityLabel("Filter models by name")
          }
          .padding(.horizontal, 9).padding(.vertical, 5)
          .frame(width: 190)
          .background(BurnTheme.track, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
      }
      if dashboard.models.isEmpty {
        Label("No model usage recorded in this period.", systemImage: "cpu")
          .font(.system(size: 12)).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, minHeight: 60)
      } else if filtered.isEmpty {
        Label("No model matches “\(search)”.", systemImage: "magnifyingglass")
          .font(.system(size: 12)).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, minHeight: 60)
      } else {
        table
          .frame(height: CGFloat(min(9, max(3, filtered.count))) * 24 + 36)
          .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      }
      dataNotes
    }
    .burnCard()
  }

  private var table: some View {
    Table(filtered, sortOrder: $order) {
      TableColumn("Model", value: \.displayName) { model in
        HStack(spacing: 6) {
          if dashboard.harness == nil {
            ForEach(model.harnesses) { harness in
              Circle().fill(BurnTheme.color(for: harness)).frame(width: 6, height: 6)
                .help(harness.name)
            }
          }
          Text(model.displayName)
            .foregroundStyle(model.model == nil ? .secondary : .primary)
            .help(model.displayName)
          if model.hasInferredModel {
            Image(systemName: "questionmark.circle").foregroundStyle(.tertiary)
              .help(
                "Part of this usage was logged without an exact model name (for example Codex auto-review); ccusage assigned the closest priced model."
              )
          }
        }
      }
      TableColumn("Tokens", value: \.tokenCount) { model in
        Text(Format.tokens(model.tokenCount)).monospacedDigit().foregroundStyle(.secondary)
          .help(Format.fullTokens(model.tokenCount) + " tokens")
      }.width(min: 70, ideal: 100)
      TableColumn("Spend", value: \.cost) { model in
        if model.totals.isPartial && model.cost == 0 {
          Text("No price").foregroundStyle(BurnTheme.warning)
            .help("This model is not in the pricing snapshot, so its usage is not valued.")
        } else {
          Text(Format.spend(model.totals)).monospacedDigit()
        }
      }.width(min: 70, ideal: 100)
      TableColumn("Share", value: \.share) { model in
        HStack(spacing: 8) {
          Capsule().fill(BurnTheme.track).frame(width: 44, height: 4)
            .overlay(alignment: .leading) {
              Capsule().fill(BurnTheme.ember).frame(width: max(2, 44 * model.share), height: 4)
            }
            .accessibilityHidden(true)
          Text(dashboard.totals.cost > 0 ? Format.percent(model.share) : "—")
            .monospacedDigit().foregroundStyle(.secondary)
        }
      }.width(min: 90, ideal: 120)
    }
    .tableStyle(.inset(alternatesRowBackgrounds: true))
  }

  @ViewBuilder private var dataNotes: some View {
    let unpriced = dashboard.models.filter { $0.totals.isPartial }
    if !unpriced.isEmpty || dashboard.unattributedTokens > 0 || dashboard.hasInferredModels {
      VStack(alignment: .leading, spacing: 4) {
        if !unpriced.isEmpty {
          Text(
            "No known price for \(unpriced.count == 1 ? "1 model" : "\(unpriced.count) models") (\(Format.tokens(dashboard.totals.unpricedTokens)) tokens). Spend totals are partial."
          )
        }
        if dashboard.unattributedTokens > 0 {
          Text(
            "\(Format.tokens(dashboard.unattributedTokens)) tokens were logged without a model name and are listed as Unattributed."
          )
        }
        if dashboard.hasInferredModels {
          Text(
            "Models marked ? include usage logged without an exact model name, which ccusage assigned to the closest priced model."
          )
        }
      }
      .font(.caption).foregroundStyle(.secondary)
    }
  }
}

private struct TokenBreakdownCard: View {
  let totals: SpendTotals
  var body: some View {
    let parts = tokenParts(totals.tokens)
    let total = max(1, totals.tokens.total)
    VStack(alignment: .leading, spacing: 14) {
      CardHeader(title: "Token breakdown", symbol: "square.stack.3d.up.fill", tint: .blue) {
        Text("Available source data")
      }
      GeometryReader { geometry in
        HStack(spacing: 2) {
          ForEach(parts, id: \.label) { part in
            let share = Double(part.value) / Double(total)
            if share > 0 {
              Rectangle().fill(part.color.gradient)
                .frame(width: max(2, geometry.size.width * share - 2))
            }
          }
        }
        .clipShape(Capsule())
      }
      .frame(height: 8)
      .accessibilityHidden(true)
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 20) { tiles(parts, total: total) }
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 12) {
          GridRow { tiles(Array(parts.prefix(2)), total: total) }
          GridRow { tiles(Array(parts.suffix(2)), total: total) }
        }
      }
    }
    .burnCard()
  }

  @ViewBuilder private func tiles(_ parts: [(label: String, value: UInt64, color: Color)], total: UInt64) -> some View {
    ForEach(parts, id: \.label) { part in
      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 6) {
          Circle().fill(part.color).frame(width: 7, height: 7)
          Text(part.label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
        }
        Text(Format.tokens(part.value)).font(.system(size: 20, weight: .semibold, design: .rounded))
        Text(Format.percent(Double(part.value) / Double(total)))
          .font(.system(size: 11)).foregroundStyle(.secondary)
      }
      .monospacedDigit()
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityElement(children: .combine)
      .help(Format.fullTokens(part.value) + " tokens")
    }
  }
}
