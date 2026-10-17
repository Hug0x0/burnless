// Quota chart geometry adapted from Agent Burn's Usage.swift
// (https://github.com/Melvynx/agent-burn, MIT, © 2025 ryoppippi, © 2026 Melvynx).

import Foundation

public enum QuotaChartRange: String, CaseIterable, Identifiable, Sendable {
  case untilReset, resetToToday, today, week, month

  public var id: String { rawValue }
  public var label: String {
    switch self {
    case .untilReset: "Until reset"
    case .resetToToday: "Reset to today"
    case .today: "Today"
    case .week: "Last 7 days"
    case .month: "Last 30 days"
    }
  }
  /// The range follows the current limit window, so pace and forecast apply.
  public var isCycle: Bool { self == .untilReset || self == .resetToToday }
}

public enum QuotaChart {
  public static func window(
    range: QuotaChartRange, forecast: Forecast, now: Date, calendar: Calendar = .current
  ) -> ClosedRange<Date> {
    let cursor = min(now, forecast.observedAt)
    let start: Date
    let end: Date
    switch range {
    case .untilReset:
      start = forecast.start
      end = max(now, forecast.reset)
    case .resetToToday:
      start = forecast.start
      end = max(cursor, forecast.observedAt)
    case .today:
      start = calendar.startOfDay(for: cursor)
      end = max(now, forecast.observedAt)
    case .week:
      start = cursor.addingTimeInterval(-7 * 86_400)
      end = max(now, forecast.observedAt)
    case .month:
      start = cursor.addingTimeInterval(-30 * 86_400)
      end = max(now, forecast.observedAt)
    }
    return start...max(start.addingTimeInterval(1), end)
  }

  /// Samples drawn for a range. Cycle ranges start from a full limit at the
  /// window start and drop everything before the latest reset.
  public static func samples(
    _ samples: [QuotaSample], range: QuotaChartRange, forecast: Forecast, now: Date
  ) -> [QuotaSample] {
    let window = window(range: range, forecast: forecast, now: now)
    let inWindow = samples.filter { $0.date >= window.lowerBound && $0.date <= window.upperBound }
      .sorted { $0.date < $1.date }
    guard range.isCycle else { return inWindow }
    var cycle: [QuotaSample] = []
    for sample in inWindow where sample.date >= window.lowerBound.addingTimeInterval(-60) {
      // A quota increase indicates a reset or a provider correction.
      if let previous = cycle.last, sample.remaining > previous.remaining + 1 { cycle.removeAll() }
      cycle.append(sample)
    }
    let anchor = QuotaSample(date: forecast.start, remaining: 100)
    guard let first = cycle.first else {
      return [anchor, QuotaSample(date: forecast.observedAt, remaining: forecast.remaining)]
    }
    return first.date <= forecast.start.addingTimeInterval(90) ? cycle : [anchor] + cycle
  }

  /// Holds each value until the next reading, then steps, so a drop shows
  /// when it was measured rather than as a slope across a long gap.
  public static func stepped(_ samples: [QuotaSample], stepGap: TimeInterval = 2 * 3_600)
    -> [QuotaSample]
  {
    let points = collapsed(samples)
    guard var previous = points.first else { return [] }
    var result = [previous]
    for sample in points.dropFirst() {
      if sample.date.timeIntervalSince(previous.date) <= stepGap,
        abs(sample.remaining - previous.remaining) >= 0.05
      {
        result.append(QuotaSample(date: sample.date, remaining: previous.remaining))
      }
      result.append(sample)
      previous = sample
    }
    return result
  }

  private static func collapsed(_ samples: [QuotaSample]) -> [QuotaSample] {
    let sorted = samples.sorted { $0.date < $1.date }
    guard var previous = sorted.first else { return [] }
    var result = [previous]
    for sample in sorted.dropFirst() {
      if abs(sample.remaining - previous.remaining) >= 0.05 {
        if result.last != previous { result.append(previous) }
        result.append(sample)
      }
      previous = sample
    }
    if let last = sorted.last, result.last != last { result.append(last) }
    return result
  }

  public static func recordedRemaining(at date: Date, samples: [QuotaSample]) -> Double? {
    let sorted = samples.sorted { $0.date < $1.date }
    guard let first = sorted.first, let last = sorted.last else { return nil }
    if date <= first.date { return first.remaining }
    if date >= last.date { return last.remaining }
    for (previous, next) in zip(sorted, sorted.dropFirst()) where date <= next.date {
      let span = next.date.timeIntervalSince(previous.date)
      guard span > 0 else { return next.remaining }
      let progress = date.timeIntervalSince(previous.date) / span
      return previous.remaining + (next.remaining - previous.remaining) * progress
    }
    return nil
  }

  public static func forecastRemaining(at date: Date, forecast: Forecast) -> Double? {
    guard forecast.projectedUse != nil, date >= forecast.observedAt else { return nil }
    if date >= forecast.projectedEnd { return forecast.projectedRemaining }
    let span = forecast.projectedEnd.timeIntervalSince(forecast.observedAt)
    guard span > 0 else { return forecast.projectedRemaining }
    let progress = date.timeIntervalSince(forecast.observedAt) / span
    return forecast.remaining + (forecast.projectedRemaining - forecast.remaining) * progress
  }

  public static func reading(
    at date: Date, samples: [QuotaSample], forecast: Forecast, range: QuotaChartRange
  ) -> Reading {
    Reading(
      date: date,
      recorded: recordedRemaining(at: date, samples: samples),
      ideal: range.isCycle ? forecast.idealRemaining(at: date) : nil,
      forecast: range == .untilReset ? forecastRemaining(at: date, forecast: forecast) : nil,
      projected: date > forecast.observedAt)
  }

  public struct Reading: Equatable, Sendable {
    public var date: Date
    public var recorded: Double?
    public var ideal: Double?
    public var forecast: Double?
    public var projected: Bool
    public var value: Double? { projected ? forecast ?? recorded : recorded }
    public var paceDelta: Double? {
      guard let ideal, let value else { return nil }
      return value - ideal
    }
  }

  public struct DeltaPoint: Equatable, Sendable {
    public var date: Date
    public var recorded: Double
    public var ideal: Double
    public var delta: Double { recorded - ideal }
  }

  public struct DeltaSegment: Equatable, Sendable {
    public var ahead: Bool
    public var points: [DeltaPoint]
  }

  /// The recorded line split where it crosses even pace, so each part can be
  /// tinted ahead (green) or behind (red). Crossings are exact because both
  /// lines are linear between samples.
  public static func deltaSegments(samples: [QuotaSample], forecast: Forecast) -> [DeltaSegment] {
    var points: [DeltaPoint] = []
    for sample in samples.sorted(by: { $0.date < $1.date }) {
      let point = DeltaPoint(
        date: sample.date, recorded: sample.remaining, ideal: forecast.idealRemaining(at: sample.date))
      if let previous = points.last, previous.delta * point.delta < 0 {
        let progress = previous.delta / (previous.delta - point.delta)
        let date = previous.date.addingTimeInterval(progress * point.date.timeIntervalSince(previous.date))
        let value = forecast.idealRemaining(at: date)
        points.append(DeltaPoint(date: date, recorded: value, ideal: value))
      }
      points.append(point)
    }
    guard points.count > 1 else { return [] }
    var segments: [DeltaSegment] = []
    for (previous, next) in zip(points, points.dropFirst()) {
      let ahead = previous.delta + next.delta >= 0
      if var last = segments.last, last.ahead == ahead {
        last.points.append(next)
        segments[segments.count - 1] = last
      } else {
        segments.append(DeltaSegment(ahead: ahead, points: [previous, next]))
      }
    }
    return segments
  }

  public static func stepComponent(range: QuotaChartRange, window: ClosedRange<Date>)
    -> Calendar.Component
  {
    let days = window.upperBound.timeIntervalSince(window.lowerBound) / 86_400
    if range == .today || days <= 1 { return .hour }
    return days > 45 ? .month : .day
  }

  public static func gridDates(
    range: QuotaChartRange, forecast: Forecast, now: Date, calendar: Calendar = .current
  ) -> [Date] {
    let window = window(range: range, forecast: forecast, now: now, calendar: calendar)
    let component = stepComponent(range: range, window: window)
    guard var cursor = calendar.dateInterval(of: component, for: window.lowerBound)?.start else {
      return [window.lowerBound]
    }
    var dates: [Date] = []
    while cursor <= window.upperBound, dates.count < 400 {
      if cursor >= window.lowerBound { dates.append(cursor) }
      guard let next = calendar.date(byAdding: component, value: 1, to: cursor), next > cursor else {
        break
      }
      cursor = next
    }
    return dates
  }

  /// At most `limit` evenly spaced axis dates.
  public static func axisDates(
    range: QuotaChartRange, forecast: Forecast, now: Date, limit: Int = 7,
    calendar: Calendar = .current
  ) -> [Date] {
    let grid = gridDates(range: range, forecast: forecast, now: now, calendar: calendar)
    guard grid.count > limit, limit >= 2 else { return grid }
    let last = grid.count - 1
    var picked: [Date] = []
    for index in 0..<limit {
      let date = grid[Int((Double(index) * Double(last) / Double(limit - 1)).rounded())]
      if picked.last != date { picked.append(date) }
    }
    return picked
  }

  /// One cursor step for keyboard adjustment of the chart.
  public static func step(from date: Date, forward: Bool, marks: [Date], domain: ClosedRange<Date>)
    -> Date
  {
    let sorted = marks.sorted()
    if forward { return min(domain.upperBound, sorted.first { $0 > date } ?? domain.upperBound) }
    return max(domain.lowerBound, sorted.last { $0 < date } ?? domain.lowerBound)
  }
}

public enum QuotaText {
  /// Whole percentages stay whole ("90%"); others keep one decimal ("96.5%").
  public static func percent(_ value: Double) -> String {
    value.formatted(.number.locale(Locale(identifier: "en_US")).precision(.fractionLength(0...1))) + "%"
  }

  public static func percentOneDecimal(_ value: Double?) -> String {
    value.map {
      $0.formatted(.number.locale(Locale(identifier: "en_US")).precision(.fractionLength(1))) + "%"
    } ?? "—"
  }

  /// "2h 05m", "45m" or "1d 4h".
  public static func duration(_ seconds: TimeInterval) -> String {
    let minutes = Int(max(0, seconds) / 60)
    let days = minutes / 1_440
    let hours = minutes % 1_440 / 60
    if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
    if hours > 0 { return String(format: "%dh %02dm", hours, minutes % 60) }
    return "\(minutes)m"
  }

  /// "+3.2% ahead", "−1.5% behind" or "On pace".
  public static func pace(_ delta: Double?) -> String? {
    guard let delta else { return nil }
    if abs(delta) < 0.05 { return "On pace" }
    let magnitude = abs(delta).formatted(
      .number.locale(Locale(identifier: "en_US")).precision(.fractionLength(0...1)))
    return delta > 0 ? "+\(magnitude) pts ahead" : "−\(magnitude) pts behind"
  }
}
