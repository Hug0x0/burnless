// Subscription economics adapted from Agent Burn's HarnessSpendDetails and
// subscription cards (https://github.com/Melvynx/agent-burn, MIT).

import BurnlessCore
import Charts
import SwiftUI

struct SpendMetric: View {
  let title: String
  let value: String
  var detail = ""
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).font(.system(size: 13)).foregroundStyle(.secondary)
      Text(value).font(.system(size: 30, weight: .semibold)).monospacedDigit()
        .lineLimit(1).minimumScaleFactor(0.6)
        .contentTransition(.numericText()).animation(.snappy, value: value)
      if !detail.isEmpty { Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }
}

/// Overview card: each plan with its weekly remaining share.
struct SubscriptionsCard: View {
  @Environment(UsageStore.self) private var store

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      CardHeader(title: "Subscriptions") {
        Text("Weekly limit remaining")
      }
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 10) { tiles }
        VStack(spacing: 10) { tiles }
      }
    }
    .burnCard()
  }

  @ViewBuilder private var tiles: some View {
    ForEach(Harness.allCases) { harness in
      Button {
        withAnimation(.snappy) { store.route = .harness(harness) }
      } label: {
        tile(harness)
      }
      .buttonStyle(.plain)
      .help("Open \(harness.name)")
    }
  }

  private func tile(_ harness: Harness) -> some View {
    let plan = store.plan(for: harness)
    let weekly = store.weekly(harness)
    let remaining = store.remaining(harness)
    return VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 14) {
        HarnessBadge(harness: harness, size: 40)
        VStack(alignment: .leading, spacing: 3) {
          Text(harness.name).font(.system(size: 15, weight: .semibold))
          Text([plan.name ?? "Plan not detected", plan.pricePerMonth.map { Format.currency($0, wholeDollars: true) + " / month" }]
            .compactMap { $0 }.joined(separator: " · "))
            .font(.system(size: 13)).foregroundStyle(.secondary)
        }
        Spacer(minLength: 8)
      }
      if let remaining {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text(remaining.formatted(.number.precision(.fractionLength(0))))
            .font(.system(size: 36, weight: .medium)).monospacedDigit().contentTransition(.numericText())
          Text("% remaining").font(.system(size: 13)).foregroundStyle(.secondary)
          Spacer()
          if let weekly, !weekly.hasReset(at: store.clock) {
            Text("Resets in " + QuotaText.duration(weekly.reset.timeIntervalSince(store.clock)))
              .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
          }
        }
        ShareBar(value: remaining / 100, tint: BurnTheme.tone(remaining: remaining), height: 5)
      } else {
        Text(
          !harness.readsLimits ? "No limit to read · usage only"
            : weekly == nil ? "Weekly limit not read yet" : "No reading since the weekly reset")
          .font(.system(size: 12)).foregroundStyle(.secondary)
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(BurnTheme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .accessibilityElement(children: .combine)
  }
}

/// Harness page: subscription value, token costs and trends.
struct SubscriptionDetailsCard: View {
  @Environment(UsageStore.self) private var store
  let harness: Harness
  @State private var expanded = WindowCapture.isActive

  var body: some View {
    let now = store.clock
    let plan = store.plan(for: harness)
    let value = SubscriptionMath.value(store.snapshot, harness: harness, plan: plan, now: now, calendar: store.calendar)
    DisclosureGroup(isExpanded: $expanded) {
      VStack(alignment: .leading, spacing: 22) {
        if let subsidy = value.subsidy, let discount = value.discountPercent {
          HStack {
            Text("API-equivalent minus plan: \(Format.currency(subsidy))")
            Spacer()
            Text("API pricing discount: \(discount.formatted(.number.precision(.fractionLength(1))))%")
          }
          .font(.system(size: 11)).foregroundStyle(.secondary)
        } else if plan.pricePerMonth == nil {
          Text("Set the plan's monthly price in Settings → Quotas to compare it with your usage.")
            .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        if let cycle = store.cycle(harness) {
          MiniSpendChart(
            title: "Daily usage · current window",
            points: SubscriptionMath.cycleDays(store.snapshot, harness: harness, since: cycle.forecast.start, now: now, calendar: store.calendar)
              .map { ($0.date, $0.cost) },
            color: BurnTheme.color(for: harness), unit: .day)
        }
        spendMix(now: now)
        MiniSpendChart(
          title: "Weekly trend",
          points: SubscriptionMath.weeklyTrend(store.snapshot, harness: harness, now: now, calendar: store.calendar)
            .map { ($0.start, $0.cost) },
          color: BurnTheme.color(for: harness), unit: .weekOfYear)
        if let estimate = store.cycle(harness)?.estimate { estimateSection(estimate) }
        if harness == .codex, let images = SubscriptionMath.imageCount(store.snapshot) { imageSection(images) }
      }
      .padding(.top, 18)
    } label: {
      Text("Subscription economics, token costs and weekly trends").font(.system(size: 15, weight: .semibold))
    }
    .burnCard()
  }

  @ViewBuilder private func spendMix(now: Date) -> some View {
    let mix = SubscriptionMath.spendMix(store.snapshot, harness: harness, now: now, calendar: store.calendar)
    if !mix.isEmpty {
      VStack(alignment: .leading, spacing: 12) {
        SectionLabel(title: "Spend by token type", detail: "Past 30 days")
        ForEach(mix) { category in
          HStack(spacing: 10) {
            Text(category.kind.label).frame(width: 90, alignment: .leading)
            ShareBar(value: category.costShare, tint: tokenColor(category.kind), height: 5)
            Text(Format.tokens(category.tokens)).foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
            Text(Format.percent(category.costShare)).foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
            Text(Format.currency(category.cost)).frame(width: 84, alignment: .trailing)
          }
          .font(.system(size: 12)).monospacedDigit()
          .accessibilityElement(children: .combine)
        }
      }
    }
  }

  private func estimateSection(_ estimate: QuotaValueEstimate) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      SectionLabel(title: "Quota value estimate", detail: "Based on the current window")
      detail("Spent this window", Format.currency(estimate.cycleSpend))
      detail("Full quota value", Format.currency(estimate.fullQuotaValue))
      detail("Average $ / %", Format.currency(estimate.dollarsPerPercent) + " / %")
      detail("Monthly quota value", Format.currency(estimate.monthlyValue))
      detail("Projected quota use", QuotaText.percent(estimate.projectedUsePercent.rounded()))
      if let multiple = estimate.valueMultiple { detail("Quota value / plan price", Format.multiple(multiple)) }
      Text("Extrapolated from this window's API-equivalent spend and the share of the limit it used.")
        .font(.system(size: 11)).foregroundStyle(.secondary)
    }
  }

  private func imageSection(_ count: Int) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      SectionLabel(title: "Image generations", detail: "Past 30 days")
      detail("Generated images", count.formatted())
      detail("Estimated image cost", Format.currency(Double(count) * SubscriptionMath.imagePriceEstimate))
      Text("\(Format.currency(SubscriptionMath.imagePriceEstimate)) per image estimate. Codex logs no tokens for images, so this is not in spend totals.")
        .font(.system(size: 11)).foregroundStyle(.secondary)
    }
  }

  private func detail(_ title: String, _ value: String) -> some View {
    HStack {
      Text(title).foregroundStyle(.secondary)
      Spacer()
      Text(value)
    }
    .font(.system(size: 12)).monospacedDigit()
  }

  private func tokenColor(_ kind: TokenClass) -> Color {
    switch kind {
    case .input: .blue
    case .output: BurnTheme.ember
    case .cacheWrite: .purple
    case .cacheRead: .teal
    }
  }
}

/// A small single-series spend bar chart.
struct MiniSpendChart: View {
  let title: String
  let points: [(date: Date, cost: Double)]
  let color: Color
  let unit: Calendar.Component
  @State private var selected: Date?

  private var selectedPoint: (date: Date, cost: Double)? {
    guard let selected else { return nil }
    let calendar = Calendar.current
    return points.first { calendar.isDate($0.date, equalTo: selected, toGranularity: unit) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        SectionLabel(title: title, detail: "")
        Spacer()
        Text(
          selectedPoint.map {
            $0.date.formatted(.dateTime.month(.abbreviated).day()) + " · " + Format.currency($0.cost)
          } ?? "API-equivalent USD"
        )
        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
      }
      Chart {
        ForEach(points, id: \.date) { point in
          BarMark(x: .value("Date", point.date, unit: unit), y: .value("Spend", point.cost))
            .foregroundStyle(color.gradient).cornerRadius(3)
            .opacity(selectedPoint == nil || selectedPoint?.date == point.date ? 1 : 0.4)
            .accessibilityLabel(point.date.formatted(date: .abbreviated, time: .omitted))
            .accessibilityValue(Format.currency(point.cost))
        }
      }
      .chartXSelection(value: WindowCapture.isActive ? .constant(nil) : $selected)
      .chartYAxis {
        AxisMarks(position: .leading) { value in
          AxisGridLine().foregroundStyle(BurnTheme.line)
          AxisValueLabel {
            if let amount = value.as(Double.self) {
              Text(amount.formatted(.currency(code: "USD").locale(Locale(identifier: "en_US")).precision(.fractionLength(0))))
            }
          }
        }
      }
      .chartXAxis {
        AxisMarks(values: .automatic(desiredCount: 6)) { _ in
          AxisValueLabel(format: .dateTime.month(.abbreviated).day())
        }
      }
      .frame(height: 140)
    }
  }
}
