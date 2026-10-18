// Spend histogram adapted from Agent Burn's ActivityChart
// (https://github.com/Melvynx/agent-burn, MIT).

import BurnlessCore
import Charts
import SwiftUI

struct SpendChart: View {
  let dashboard: Dashboard
  let calendar: DayCalendar
  @Binding var granularity: Granularity?
  @State private var selected: Date?

  private var effective: Granularity {
    granularity ?? Granularity.automatic(days: dashboard.days.count)
  }
  private var binding: Binding<Granularity> {
    Binding(get: { effective }, set: { granularity = $0 })
  }
  private var buckets: [SpendBucket] {
    spendBuckets(dashboard.days, granularity: effective, calendar: calendar)
  }
  private var series: [Harness] { dashboard.scope }
  private var domain: ClosedRange<Date> {
    guard let first = buckets.first?.start, let last = buckets.last?.end, first < last else {
      let today = calendar.calendar.startOfDay(for: .now)
      return today...today.addingTimeInterval(86_400)
    }
    return first...last
  }
  private var selectedBucket: SpendBucket? {
    guard let selected else { return nil }
    return buckets.first { selected >= $0.start && selected < $0.end }
  }
  private var unit: Calendar.Component {
    switch effective {
    case .day: .day
    case .week: .weekOfYear
    case .month: .month
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      header
      chart
        .frame(height: 220)
        .overlay { emptyOverlay }
      if hasNotes { legend }
    }
  }

  private var hasNotes: Bool {
    !dashboard.unavailable.isEmpty || !dashboard.stale.isEmpty || buckets.contains(where: \.isUnknown)
  }

  private var header: some View {
    HStack(spacing: 10) {
      Text(effective.title).font(.system(size: 15, weight: .semibold))
        .accessibilityAddTraits(.isHeader)
      Picker("Granularity", selection: binding) {
        ForEach(Granularity.allCases) { Text($0.label).tag($0) }
      }
      .pickerStyle(.menu)
      .menuStyle(.borderlessButton)
      .labelsHidden()
      .fixedSize()
      .foregroundStyle(.secondary)
      .accessibilityLabel("Spend granularity")
      Spacer(minLength: 8)
      Text("USD").font(.system(size: 12)).foregroundStyle(.secondary)
    }
  }

  /// One color per page, as on Agent Burn's site: the accent for all
  /// harnesses, the harness color on its own page.
  private var barColor: Color { dashboard.harness.map(BurnTheme.color) ?? BurnTheme.accent }

  private var chart: some View {
    Chart {
      ForEach(buckets) { bucket in
        if bucket.isUnknown {
          RectangleMark(
            xStart: .value("Start", bucket.start), xEnd: .value("End", bucket.end)
          )
          .foregroundStyle(BurnTheme.unknown)
          .accessibilityLabel("\(label(bucket)): not read")
        }
        if bucket.cost > 0 {
          BarMark(
            x: .value("Date", bucket.start, unit: unit),
            y: .value("Spend", bucket.cost)
          )
          .foregroundStyle(barColor.gradient)
          .opacity(selectedBucket == nil || selectedBucket?.id == bucket.id ? 1 : 0.35)
          .accessibilityLabel(label(bucket))
          .accessibilityValue(Format.currency(bucket.cost))
        }
      }
      if let bucket = selectedBucket {
        RuleMark(x: .value("Date", bucket.start, unit: unit))
          .foregroundStyle(Color.secondary.opacity(0.3))
          .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
          .annotation(
            position: .top, spacing: 4,
            overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
          ) { tooltip(bucket) }
      }
    }
    // Screenshots ignore wherever the real pointer happens to be.
    .chartXSelection(value: WindowCapture.isActive ? .constant(nil) : $selected)
    .chartXScale(domain: domain)
    .chartYAxis {
      AxisMarks(position: .leading) { value in
        AxisGridLine()
        AxisValueLabel {
          if let amount = value.as(Double.self) {
            // A plain string: Text(_:format:) would swap in the system locale.
            Text(
              amount.formatted(
                .currency(code: "USD").locale(Locale(identifier: "en_US")).precision(
                  .fractionLength(0))))
          }
        }
      }
    }
    .chartXAxis {
      AxisMarks(values: .automatic(desiredCount: 6)) { _ in
        AxisGridLine().foregroundStyle(.clear)
        if effective == .month {
          AxisValueLabel(format: .dateTime.month(.abbreviated).year(.twoDigits))
        } else {
          AxisValueLabel(format: .dateTime.month(.abbreviated).day())
        }
      }
    }
    .animation(.easeOut(duration: 0.15), value: selectedBucket?.id)
    .id(effective.rawValue + dashboard.lowerKey + dashboard.upperKey + (dashboard.harness?.rawValue ?? "all"))
  }

  @ViewBuilder private var emptyOverlay: some View {
    if !dashboard.unavailable.isEmpty && dashboard.unavailable.count == dashboard.scope.count {
      overlayMessage(
        symbol: "folder.badge.questionmark", title: "Source unavailable",
        detail: "No readable history for \(dashboard.unavailable.map(\.name).joined(separator: " or ")).")
    } else if buckets.allSatisfy({ $0.cost <= 0 }) {
      overlayMessage(
        symbol: "chart.bar.xaxis",
        title: dashboard.hasUsageInPeriod ? "No priced spend in this period" : "No usage in this period",
        detail: dashboard.hasUsageInPeriod
          ? "Usage was recorded, but its models have no known price."
          : "Choose a longer period or run a session.")
    }
  }

  private func overlayMessage(symbol: String, title: String, detail: String) -> some View {
    VStack(spacing: 6) {
      Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(.tertiary)
      Text(title).font(.system(size: 13, weight: .medium))
      Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
    }
    .padding(.horizontal, 16).padding(.vertical, 12)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
  }

  private func tooltip(_ bucket: SpendBucket) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(label(bucket)).font(.system(size: 10)).foregroundStyle(.secondary)
      if bucket.isUnknown {
        Text("Not read yet").font(.system(size: 12, weight: .semibold))
      } else {
        Text(Format.spend(bucket.totals)).font(.system(size: 13, weight: .semibold))
        if series.count > 1 {
          ForEach(series) { harness in
            HStack(spacing: 6) {
              Circle().fill(BurnTheme.color(for: harness)).frame(width: 6, height: 6)
              Text(harness.name).foregroundStyle(.secondary)
              Spacer(minLength: 10)
              Text(Format.currency(bucket.costs[harness] ?? 0))
            }
            .font(.system(size: 10))
          }
        }
        Text(Format.tokens(bucket.totals.tokens.total) + " tokens")
          .font(.system(size: 10)).foregroundStyle(.secondary)
        if bucket.totals.isPartial {
          Text("Includes unpriced usage").font(.system(size: 10)).foregroundStyle(BurnTheme.warning)
        }
        if bucket.hasUnknownDays {
          Text("Some days not read yet").font(.system(size: 10)).foregroundStyle(.secondary)
        }
      }
    }
    .monospacedDigit()
    .frame(width: 168, alignment: .leading)
    .padding(9)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 9, style: .continuous)
        .strokeBorder(BurnTheme.cardStroke, lineWidth: 1))
  }

  private var legend: some View {
    HStack(spacing: 14) {
      ForEach(series.filter { dashboard.unavailable.contains($0) || dashboard.stale.contains($0) }) { harness in
        HStack(spacing: 5) {
          Text(harness.name)
          if dashboard.unavailable.contains(harness) {
            Text("· unavailable").foregroundStyle(.tertiary)
          } else {
            Text("· saved data").foregroundStyle(BurnTheme.warning)
          }
        }
        .fixedSize()
      }
      if buckets.contains(where: \.isUnknown) {
        HStack(spacing: 5) {
          RoundedRectangle(cornerRadius: 2).fill(BurnTheme.unknown)
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(BurnTheme.cardStroke))
            .frame(width: 10, height: 8)
          Text("Not read")
        }
        .fixedSize()
      }
      Spacer(minLength: 0)
    }
    .font(.system(size: 11)).foregroundStyle(.secondary)
    .accessibilityElement(children: .combine)
  }

  private func label(_ bucket: SpendBucket) -> String {
    let style = Date.FormatStyle.dateTime.month(.abbreviated).day().year()
    switch effective {
    case .day:
      return bucket.start.formatted(Date.FormatStyle.dateTime.weekday(.abbreviated).month(.abbreviated).day().year())
    case .week:
      let first = calendar.date(bucket.firstKey) ?? bucket.start
      let last = calendar.date(bucket.lastKey) ?? bucket.start
      return first.formatted(.dateTime.month(.abbreviated).day()) + " – " + last.formatted(style)
    case .month:
      return bucket.start.formatted(.dateTime.month(.wide).year())
    }
  }
}
