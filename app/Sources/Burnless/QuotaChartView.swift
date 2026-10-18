// Quota chart adapted from Agent Burn's QuotaChart
// (https://github.com/Melvynx/agent-burn, MIT, © 2025 ryoppippi, © 2026 Melvynx).

import BurnlessCore
import Charts
import SwiftUI

struct QuotaChartView: View {
  let forecast: Forecast
  let samples: [QuotaSample]
  let color: Color
  var range = QuotaChartRange.untilReset
  var now = Date.now
  var height: CGFloat = 214
  var compact = false
  /// No header or day bands, edge-only axis labels, and in-chart labels for
  /// now, even pace, the reset outcome and any lockout before reset.
  var minimal = false
  @State private var selected: Date?

  private var muted: Color { compact || minimal ? BurnTheme.quotaMuted : BurnTheme.muted }
  private var domain: ClosedRange<Date> { QuotaChart.window(range: range, forecast: forecast, now: now) }
  private var showsForecast: Bool { range == .untilReset && forecast.projectedUse != nil }
  private var showsIdeal: Bool { range.isCycle }
  private var runsOut: Bool { showsForecast && forecast.runsOut }
  private var drawn: [QuotaSample] { QuotaChart.stepped(samples) }
  private var gridDates: [Date] { QuotaChart.gridDates(range: range, forecast: forecast, now: now) }
  private var cursor: Date { selected ?? forecast.observedAt }
  private var reading: QuotaChart.Reading {
    QuotaChart.reading(at: cursor, samples: drawn, forecast: forecast, range: range)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if !minimal { header }
      chart
    }
    .id(range.rawValue + domain.lowerBound.description + domain.upperBound.description)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Quota chart")
    .accessibilityValue(accessibilityValue)
    .accessibilityAdjustableAction { direction in
      selected = QuotaChart.step(
        from: cursor, forward: direction == .increment, marks: gridDates, domain: domain)
    }
    .help(
      "Drag across the chart to read the remaining limit at any time. Even pace spreads the limit evenly until reset; the forecast extends the observed pace. The line is green while remaining is ahead of pace and red where it falls behind."
    )
  }

  private var chart: some View {
    Chart {
      if !minimal { currentDayBand }
      RuleMark(x: .value("Date", domain.lowerBound)).foregroundStyle(.clear)
      RuleMark(x: .value("Date", domain.upperBound)).foregroundStyle(.clear)
      if minimal && runsOut { lockoutBand }
      if showsIdeal { paceBand } else { recordedArea }
      if showsIdeal { idealLine }
      if minimal && showsIdeal { paceLabel }
      recordedLine
      if showsForecast { forecastLine }
      if minimal && showsForecast { forecastEnd }
      if range == .untilReset && domain.contains(forecast.reset) { resetRule }
      cursorMarks
    }
    .chartXScale(domain: domain, range: .plotDimension(endPadding: minimal ? 0 : 12))
    .chartYScale(domain: 0...100, range: .plotDimension(endPadding: minimal ? 16 : 0))
    .chartXSelection(value: WindowCapture.isActive ? .constant(nil) : $selected)
    .chartYAxis {
      AxisMarks(position: .leading, values: minimal ? [0, 100] : compact ? [0, 50, 100] : [0, 25, 50, 75, 100]) {
        value in
        let baseline = minimal && value.as(Int.self) == 0
        AxisGridLine(stroke: StrokeStyle(lineWidth: baseline ? 1 : 0.5, dash: baseline ? [] : [3, 5]))
          .foregroundStyle(baseline ? BurnTheme.grid : BurnTheme.line)
        AxisValueLabel {
          if let number = value.as(Int.self) {
            Text("\(number)%").foregroundStyle(muted).monospacedDigit()
          }
        }
      }
    }
    .chartXAxis {
      if minimal {
        AxisMarks(values: [domain.lowerBound, min(domain.upperBound, forecast.reset)]) { value in
          AxisValueLabel(anchor: value.index == 0 ? .topLeading : .topTrailing, collisionResolution: .disabled) {
            if let date = value.as(Date.self) {
              Text(edgeLabel(date, isStart: value.index == 0)).foregroundStyle(muted).monospacedDigit()
            }
          }
        }
      } else {
        AxisMarks(values: QuotaChart.axisDates(range: range, forecast: forecast, now: now, limit: compact ? 4 : 7)) {
          value in
          AxisGridLine().foregroundStyle(BurnTheme.line)
          AxisValueLabel {
            if let date = value.as(Date.self) {
              Text(axisLabel(date)).foregroundStyle(muted).monospacedDigit()
            }
          }
        }
      }
    }
    .frame(height: height)
  }

  // MARK: Marks

  @ChartContentBuilder private var currentDayBand: some ChartContent {
    if QuotaChart.stepComponent(range: range, window: domain) == .day,
      let today = Calendar.current.dateInterval(of: .day, for: now)
    {
      RectangleMark(
        xStart: .value("Start", max(today.start, domain.lowerBound)),
        xEnd: .value("End", min(today.end, domain.upperBound)),
        yStart: .value("Low", 0), yEnd: .value("High", 100)
      )
      .foregroundStyle(color.opacity(0.07))
    }
  }

  /// Hatched span between the projected run-out and the reset: time without quota.
  @ChartContentBuilder private var lockoutBand: some ChartContent {
    RectangleMark(
      xStart: .value("Empty", forecast.projectedEnd), xEnd: .value("Reset", forecast.reset),
      yStart: .value("Low", 0), yEnd: .value("High", 100)
    )
    .foregroundStyle(lockoutHatch())
    .annotation(position: .overlay, alignment: .center) {
      VStack(spacing: 2) {
        Text("Locked out").font(.system(size: 11, weight: .semibold))
        Text(QuotaText.duration(forecast.reset.timeIntervalSince(forecast.projectedEnd)))
          .font(.system(size: 10.5)).monospacedDigit()
      }
      .foregroundStyle(BurnTheme.behind)
      .fixedSize()
    }
  }

  @ChartContentBuilder private var paceBand: some ChartContent {
    ForEach(Array(QuotaChart.deltaSegments(samples: drawn, forecast: forecast).enumerated()), id: \.offset) {
      index, segment in
      ForEach(Array(segment.points.enumerated()), id: \.offset) { _, point in
        AreaMark(
          x: .value("Date", point.date), yStart: .value("Pace", point.ideal),
          yEnd: .value("Recorded", point.recorded), series: .value("Series", "Pace delta \(index)")
        )
        .foregroundStyle((segment.ahead ? BurnTheme.ahead : BurnTheme.behind).opacity(minimal ? 0.2 : 0.26))
        .interpolationMethod(.linear)
      }
    }
  }

  @ChartContentBuilder private var recordedArea: some ChartContent {
    ForEach(Array(drawn.enumerated()), id: \.offset) { _, sample in
      // Step points share a date; default stacking would sum them past 100%.
      AreaMark(
        x: .value("Date", sample.date), y: .value("Remaining", sample.remaining),
        series: .value("Series", "Recorded area"), stacking: .unstacked
      )
      .foregroundStyle(color.opacity(0.12))
      .interpolationMethod(.linear)
    }
  }

  @ChartContentBuilder private var idealLine: some ChartContent {
    ForEach([domain.lowerBound, min(domain.upperBound, forecast.reset)], id: \.self) { date in
      LineMark(
        x: .value("Date", date), y: .value("Remaining", forecast.idealRemaining(at: date)),
        series: .value("Series", "Pace")
      )
      .foregroundStyle(muted)
      .lineStyle(StrokeStyle(lineWidth: minimal ? 1.25 : 1.5, dash: [4, 4]))
    }
  }

  /// Names the dashed pace line on the side the recorded line leaves free.
  @ChartContentBuilder private var paceLabel: some ChartContent {
    let end = forecast.projectedEnd.timeIntervalSince(forecast.start) / forecast.duration
    let fraction = end - forecast.elapsed >= 0.25 ? forecast.elapsed + (end - forecast.elapsed) * 0.5 : forecast.elapsed * 0.5
    let date = forecast.start.addingTimeInterval(forecast.duration * fraction)
    let ahead = forecast.paceDelta >= 0
    PointMark(x: .value("Date", date), y: .value("Remaining", forecast.idealRemaining(at: date)))
      .symbolSize(0)
      .annotation(
        position: ahead ? .bottomLeading : .topTrailing, spacing: 2,
        overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
      ) {
        Text("even pace").font(.system(size: 10)).foregroundStyle(muted).fixedSize()
      }
  }

  @ChartContentBuilder private var recordedLine: some ChartContent {
    if showsIdeal {
      ForEach(Array(QuotaChart.deltaSegments(samples: drawn, forecast: forecast).enumerated()), id: \.offset) {
        index, segment in
        ForEach(Array(segment.points.enumerated()), id: \.offset) { _, point in
          LineMark(
            x: .value("Date", point.date), y: .value("Remaining", point.recorded),
            series: .value("Series", "Recorded \(index)")
          )
          .foregroundStyle(minimal || segment.ahead ? color : BurnTheme.behind)
          .lineStyle(StrokeStyle(lineWidth: minimal ? 2.25 : 2.5, lineCap: .round, lineJoin: .round))
          .interpolationMethod(.linear)
        }
      }
    } else {
      ForEach(Array(drawn.enumerated()), id: \.offset) { _, sample in
        LineMark(
          x: .value("Date", sample.date), y: .value("Remaining", sample.remaining),
          series: .value("Series", "Recorded")
        )
        .foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 2.5))
        .interpolationMethod(.linear)
      }
      if drawn.count == 1, let only = drawn.first {
        PointMark(x: .value("Date", only.date), y: .value("Remaining", only.remaining))
          .foregroundStyle(color).symbolSize(18)
      }
    }
  }

  @ChartContentBuilder private var forecastLine: some ChartContent {
    let stroke = runsOut ? BurnTheme.behind : color
    ForEach([0, 1], id: \.self) { index in
      LineMark(
        x: .value("Date", index == 0 ? forecast.observedAt : forecast.projectedEnd),
        y: .value("Remaining", index == 0 ? forecast.remaining : forecast.projectedRemaining),
        series: .value("Series", "Forecast")
      )
      .foregroundStyle(stroke.opacity(0.85))
      .lineStyle(StrokeStyle(lineWidth: minimal ? 1.75 : 2, dash: [5, 4]))
    }
  }

  /// Where the forecast lands: the share left at reset, or the run-out time.
  @ChartContentBuilder private var forecastEnd: some ChartContent {
    let stroke = runsOut ? BurnTheme.behind : color
    PointMark(x: .value("Date", forecast.projectedEnd), y: .value("Remaining", forecast.projectedRemaining))
      .symbol {
        Circle().strokeBorder(stroke, lineWidth: 1.5).background(Circle().fill(.background))
          .frame(width: 7, height: 7)
      }
      .annotation(
        position: runsOut ? .topTrailing : forecast.projectedRemaining >= 15 ? .bottomLeading : .topLeading,
        spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
      ) {
        Text(
          runsOut
            ? "Empty " + runOutLabel
            : "~" + QuotaText.percent(forecast.projectedRemaining.rounded()) + " at reset"
        )
        .font(.system(size: 11, weight: .semibold)).monospacedDigit()
        .foregroundStyle(stroke)
        .fixedSize()
      }
  }

  @ChartContentBuilder private var resetRule: some ChartContent {
    let rule = RuleMark(x: .value("Date", forecast.reset))
      .foregroundStyle(muted.opacity(0.55)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
    if minimal {
      rule
    } else {
      rule.annotation(position: .leading, alignment: .top, spacing: 4) {
        Text("Reset").font(.system(size: 10, weight: .medium)).foregroundStyle(muted)
      }
    }
  }

  @ChartContentBuilder private var cursorMarks: some ChartContent {
    if domain.contains(cursor) {
      if minimal && selected == nil {
        RuleMark(x: .value("Date", cursor), yStart: .value("Low", 0), yEnd: .value("High", 100))
          .foregroundStyle(color.opacity(0.5))
          .lineStyle(StrokeStyle(lineWidth: 1))
          .annotation(position: .top, spacing: 3, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
            Text("Now").font(.system(size: 10, weight: .semibold)).foregroundStyle(color)
          }
      } else {
        RuleMark(x: .value("Date", cursor))
          .foregroundStyle(color.opacity(selected == nil ? 0.35 : 0.5))
          .lineStyle(StrokeStyle(lineWidth: 1))
      }
      if let value = reading.value {
        let tone = (reading.paceDelta ?? 0) >= 0 ? color : BurnTheme.behind
        let point = PointMark(x: .value("Date", cursor), y: .value("Remaining", value))
          .foregroundStyle(reading.projected ? tone.opacity(0.6) : tone)
          .symbolSize(reading.projected ? 30 : 48)
        if selected != nil || compact {
          point.annotation(
            position: .top, spacing: compact ? 4 : 8,
            overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
          ) { badge }
        } else {
          point
        }
      }
    }
  }

  private var badge: some View {
    let delta = reading.paceDelta
    let tone: Color = delta.map { $0 < -0.05 ? BurnTheme.behind : BurnTheme.ahead } ?? muted
    return HStack(spacing: 5) {
      Text(QuotaText.percentOneDecimal(reading.value)).foregroundStyle(.primary)
      if let delta, let text = QuotaText.pace(delta) {
        Text("·").foregroundStyle(muted.opacity(0.55))
        Text(compact ? (abs(delta) < 0.05 ? "pace" : text.replacingOccurrences(of: " pts ahead", with: "").replacingOccurrences(of: " pts behind", with: "")) : text)
          .foregroundStyle(tone)
      }
    }
    .font(.system(size: compact ? 9.5 : 11, weight: .medium)).monospacedDigit()
    .padding(.horizontal, compact ? 6 : 8).padding(.vertical, compact ? 2.5 : 4)
    .background(.ultraThinMaterial, in: Capsule())
    .overlay(Capsule().stroke(BurnTheme.cardStroke, lineWidth: 0.5))
  }

  // MARK: Header and labels

  private var header: some View {
    // Drops the cursor label rather than truncating it in narrow columns.
    ViewThatFits(in: .horizontal) {
      headerRow(cursor: !compact)
      headerRow(cursor: false)
    }
  }

  private func headerRow(cursor: Bool) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      series("Recorded", reading.recorded, color: (reading.paceDelta ?? 0) >= 0 ? color : BurnTheme.behind, dashed: false)
      if showsForecast { series("Forecast", reading.forecast, color: runsOut ? BurnTheme.behind : color, dashed: true) }
      if showsIdeal { series("Even pace", reading.ideal, color: muted, dashed: true) }
      Spacer(minLength: 4)
      if cursor {
        Text(cursorLabel).font(.system(size: 12)).foregroundStyle(muted).monospacedDigit()
          .lineLimit(1).fixedSize()
      }
    }
  }

  private func series(_ title: String, _ value: Double?, color: Color, dashed: Bool) -> some View {
    HStack(spacing: 5) {
      Path { path in
        path.move(to: .zero)
        path.addLine(to: CGPoint(x: 12, y: 0))
      }
      .stroke(color, style: StrokeStyle(lineWidth: 2, dash: dashed ? [3, 3] : []))
      .frame(width: 12, height: 1)
      Text(title).foregroundStyle(muted)
      // The site's compact legend names the lines only.
      if !compact { Text(QuotaText.percentOneDecimal(value)).monospacedDigit() }
    }
    .font(.system(size: compact ? 13 : 12))
    .lineLimit(1)
    .fixedSize()
  }

  private var cursorLabel: String {
    let prefix = reading.projected ? "Projected · " : selected == nil ? "Latest · " : ""
    let style: Date.FormatStyle =
      range == .today ? .dateTime.hour().minute() : .dateTime.month(.abbreviated).day().hour().minute()
    return prefix + cursor.formatted(style)
  }

  private var runOutLabel: String {
    forecast.duration <= 86_400
      ? forecast.projectedEnd.formatted(date: .omitted, time: .shortened)
      : forecast.projectedEnd.formatted(.dateTime.weekday(.abbreviated))
  }

  private func edgeLabel(_ date: Date, isStart: Bool) -> String {
    if forecast.duration <= 86_400 { return date.formatted(date: .omitted, time: .shortened) }
    return isStart
      ? date.formatted(.dateTime.weekday(.abbreviated).day())
      : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
  }

  private func axisLabel(_ date: Date) -> String {
    let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
    if range == .today || span <= 86_400 { return date.formatted(.dateTime.hour()) }
    if span > 45 * 86_400 { return date.formatted(.dateTime.month(.abbreviated)) }
    if span > 10 * 86_400 || compact { return date.formatted(.dateTime.month(.abbreviated).day()) }
    return date.formatted(.dateTime.weekday(.abbreviated).day())
  }

  private var accessibilityValue: String {
    var parts = ["\(QuotaText.percentOneDecimal(reading.value)) remaining at \(cursorLabel)"]
    if let pace = QuotaText.pace(reading.paceDelta) { parts.append(pace) }
    parts.append(range.label)
    return parts.joined(separator: ". ") + "."
  }
}

/// Diagonal red hatching for the time between a projected run-out and reset.
func lockoutHatch() -> ImagePaint {
  let size: CGFloat = 6
  let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    NSColor.systemRed.withAlphaComponent(0.3).setStroke()
    let path = NSBezierPath()
    path.lineWidth = 1.6
    for offset in [-size, 0, size] {
      path.move(to: NSPoint(x: offset - 1, y: -1))
      path.line(to: NSPoint(x: offset + size + 1, y: size + 1))
    }
    path.stroke()
    return true
  }
  return ImagePaint(image: Image(nsImage: image))
}
