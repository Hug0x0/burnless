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

struct QuotaUnavailable: View {
  @Environment(UsageStore.self) private var store
  let harness: Harness

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(!harness.readsLimits ? "No limit reading" : store.quota == nil ? "Reading limits…" : "Limit not available yet")
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
    case .gemini:
      return "Gemini CLI does not save its limits on this Mac, so Burnless shows its usage and plan value only. Run /stats in Gemini CLI to see the remaining quota."
    }
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
        Text("Weekly limit used per day").font(.system(size: 15, weight: .semibold))
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
