import AppKit
import BurnlessCore
import Observation
import SwiftUI

enum Route: Hashable {
  case overview
  case harness(Harness)
  case settings

  var harness: Harness? {
    if case .harness(let harness) = self { return harness }
    return nil
  }

  var title: String {
    switch self {
    case .overview: "All harnesses"
    case .harness(let harness): harness.name
    case .settings: "Settings"
    }
  }
}

enum Appearance: String, CaseIterable, Identifiable {
  case system, light, dark
  var id: String { rawValue }
  var label: String { rawValue.capitalized }

  @MainActor func apply() {
    NSApp.appearance =
      switch self {
      case .system: nil
      case .light: NSAppearance(named: .aqua)
      case .dark: NSAppearance(named: .darkAqua)
      }
  }
}

/// User preferences, persisted in UserDefaults (domain `io.github.hug0x0.burnless`).
@Observable @MainActor final class AppSettings {
  private let defaults: UserDefaults

  var appearance: Appearance { didSet { save(appearance.rawValue, "appearance"); appearance.apply() } }
  var claudeDirectory: String { didSet { save(claudeDirectory, "claudeDirectory") } }
  var codexHome: String { didSet { save(codexHome, "codexHome") } }
  var onlinePricing: Bool { didSet { save(onlinePricing, "onlinePricing") } }
  /// Minutes between automatic refreshes while the app is open; 0 disables.
  var refreshMinutes: Int { didSet { save(refreshMinutes, "refreshMinutes") } }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    appearance = Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
    claudeDirectory = defaults.string(forKey: "claudeDirectory") ?? ""
    codexHome = defaults.string(forKey: "codexHome") ?? ""
    onlinePricing = defaults.bool(forKey: "onlinePricing")
    refreshMinutes = defaults.object(forKey: "refreshMinutes") as? Int ?? 5
  }

  private func save(_ value: Any, _ key: String) { defaults.set(value, forKey: key) }
}

@Observable @MainActor final class UsageStore {
  let settings: AppSettings
  let isDemo: Bool
  private let cache: SnapshotCache

  private(set) var snapshot: UsageSnapshot?
  private(set) var isLoading = false
  /// Set when the last refresh failed as a whole (the engine could not run).
  private(set) var lastError: String?
  private(set) var lastAttempt: Date?
  /// True once a cached or fresh snapshot has been looked for.
  private(set) var didLoad = false

  var route: Route = .overview
  var period: Period = .last30
  /// Chart granularity chosen by the user; `nil` follows the period length.
  var granularity: Granularity?

  private var refreshTask: Task<Void, Never>?
  private var refreshAgain = false
  private var autoRefresh: Task<Void, Never>?

  init(settings: AppSettings = AppSettings(), cache: SnapshotCache = .standard, isDemo: Bool) {
    self.settings = settings
    self.cache = cache
    self.isDemo = isDemo
  }

  var calendar: DayCalendar { DayCalendar(timeZone: .current) }

  func dashboard(for harness: Harness?, now: Date = .now) -> Dashboard {
    Dashboard.compute(snapshot: snapshot, harness: harness, period: period, now: now, days: calendar)
  }

  func start() {
    settings.appearance.apply()
    if isDemo {
      snapshot = DemoData.snapshot(now: .now, days: calendar)
      lastAttempt = .now
      didLoad = true
      return
    }
    snapshot = cache.load()
    didLoad = snapshot != nil
    refresh()
    scheduleAutoRefresh()
  }

  /// Starts a refresh, or queues one more if a refresh is already running so
  /// the newest settings always win without overlapping engine runs.
  func refresh() {
    guard !isDemo else { return }
    if refreshTask != nil {
      refreshAgain = true
      return
    }
    refreshTask = Task { [weak self] in
      guard let self else { return }
      repeat {
        refreshAgain = false
        await runRefresh()
      } while refreshAgain
      refreshTask = nil
    }
  }

  func scheduleAutoRefresh() {
    autoRefresh?.cancel()
    let minutes = settings.refreshMinutes
    guard !isDemo, minutes > 0 else { return }
    autoRefresh = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(Double(minutes) * 60))
        if Task.isCancelled { return }
        self?.refresh()
      }
    }
  }

  private func runRefresh() async {
    isLoading = true
    defer {
      isLoading = false
      didLoad = true
    }
    let now = Date.now
    lastAttempt = now
    guard let executable = EngineClient.locate() else {
      lastError = EngineError.missing.localizedDescription
      return
    }
    let configuration = EngineConfiguration(
      executable: executable,
      claudeDirectory: settings.claudeDirectory.isEmpty ? nil : settings.claudeDirectory,
      codexHome: settings.codexHome.isEmpty ? nil : settings.codexHome,
      onlinePricing: settings.onlinePricing, timeZone: .current)
    do {
      let report = try await EngineClient.run(configuration)
      let merged = UsageSnapshot.merging(report, previous: snapshot, now: now)
      snapshot = merged
      lastError = nil
      do { try cache.save(merged) } catch {
        lastError = "Usage updated, but the local cache could not be saved: \(error.localizedDescription)"
      }
    } catch {
      // Keep showing the last valid snapshot.
      lastError = error.localizedDescription
    }
  }
}
