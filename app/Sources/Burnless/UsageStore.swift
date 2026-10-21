import AppKit
import BurnlessCore
import Observation
import SwiftUI

enum Route: Hashable {
  case overview
  case harness(Harness)

  var harness: Harness? {
    if case .harness(let harness) = self { return harness }
    return nil
  }

  var title: String {
    switch self {
    case .overview: "Overview"
    case .harness(let harness): harness.name
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
  var geminiDirectory: String { didSet { save(geminiDirectory, "geminiDirectory") } }
  var onlinePricing: Bool { didSet { save(onlinePricing, "onlinePricing") } }
  /// Minutes between automatic usage refreshes while the app is open; 0 disables.
  var refreshMinutes: Int { didSet { save(refreshMinutes, "refreshMinutes") } }
  /// Ask the providers' usage endpoints with the existing sign-ins (read-only).
  var liveQuotas: Bool { didSet { save(liveQuotas, "liveQuotas") } }
  /// Plan overrides: a monthly price or a plan name. Empty uses the detected plan.
  var claudePlan: String { didSet { save(claudePlan, "claudePlan") } }
  var codexPlan: String { didSet { save(codexPlan, "codexPlan") } }
  /// Gemini CLI logs no plan, so this is the only source of its plan.
  var geminiPlan: String { didSet { save(geminiPlan, "geminiPlan") } }
  var showInMenuBar: Bool { didSet { save(showInMenuBar, "showInMenuBar") } }
  var menuBarOnly: Bool { didSet { save(menuBarOnly, "menuBarOnly"); applyActivationPolicy() } }
  /// Harness whose weekly remaining is shown in the menu bar and toolbar.
  var menuBarQuota: Harness { didSet { save(menuBarQuota.rawValue, "menuBarQuota") } }
  var quotaChartRange: QuotaChartRange { didSet { save(quotaChartRange.rawValue, "quotaChartRange") } }
  var checkForUpdates: Bool { didSet { save(checkForUpdates, "checkForUpdates") } }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    appearance = Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
    claudeDirectory = defaults.string(forKey: "claudeDirectory") ?? ""
    codexHome = defaults.string(forKey: "codexHome") ?? ""
    geminiDirectory = defaults.string(forKey: "geminiDirectory") ?? ""
    onlinePricing = defaults.bool(forKey: "onlinePricing")
    refreshMinutes = defaults.object(forKey: "refreshMinutes") as? Int ?? 5
    liveQuotas = defaults.bool(forKey: "liveQuotas")
    claudePlan = defaults.string(forKey: "claudePlan") ?? ""
    codexPlan = defaults.string(forKey: "codexPlan") ?? ""
    geminiPlan = defaults.string(forKey: "geminiPlan") ?? ""
    showInMenuBar = defaults.object(forKey: "showInMenuBar") as? Bool ?? true
    menuBarOnly = defaults.bool(forKey: "menuBarOnly")
    menuBarQuota =
      Harness(rawValue: defaults.string(forKey: "menuBarQuota") ?? "").flatMap { $0.readsLimits ? $0 : nil }
      ?? .codex
    quotaChartRange =
      QuotaChartRange(rawValue: defaults.string(forKey: "quotaChartRange") ?? "") ?? .untilReset
    checkForUpdates = defaults.bool(forKey: "checkForUpdates")
  }

  func applyActivationPolicy() {
    NSApp.setActivationPolicy(menuBarOnly && showInMenuBar ? .accessory : .regular)
  }

  private func save(_ value: Any, _ key: String) { defaults.set(value, forKey: key) }

  var engineClaudeDirectory: String? { claudeDirectory.isEmpty ? nil : claudeDirectory }
  var engineCodexHome: String? { codexHome.isEmpty ? nil : codexHome }
  var engineGeminiDirectory: String? { geminiDirectory.isEmpty ? nil : geminiDirectory }
}

/// Cross-process pacing for live Claude reads, shared with the background
/// collector so both never hit Anthropic's endpoint in the same minute.
enum LivePacing {
  static let interval: TimeInterval = 55
  private static let lastKey = "claudeLiveAt"
  private static let blockedKey = "claudeLiveBlockedUntil"

  static func claudeDue(now: Date = .now, force: Bool, defaults: UserDefaults = .standard) -> Bool {
    if let blocked = defaults.object(forKey: blockedKey) as? Date, blocked > now { return false }
    guard !force else { return true }
    let last = defaults.object(forKey: lastKey) as? Date ?? .distantPast
    return now.timeIntervalSince(last) >= interval
  }

  static func record(_ status: LiveStatus, now: Date = .now, defaults: UserDefaults = .standard) {
    defaults.set(now, forKey: lastKey)
    let pause: TimeInterval? =
      switch status.state {
      case .rateLimited: max(120, min(3600, status.retryAfterSeconds ?? 300))
      // Without a readable sign-in, asking every minute would prompt again
      // and again; try once an hour, or sooner with Check now.
      case .noSignIn, .unauthorized: 3600
      case .signInExpired: 600
      default: nil
      }
    if let pause { defaults.set(now.addingTimeInterval(pause), forKey: blockedKey) } else {
      defaults.removeObject(forKey: blockedKey)
    }
  }

  static func blockedUntil(defaults: UserDefaults = .standard) -> Date? {
    (defaults.object(forKey: blockedKey) as? Date).flatMap { $0 > .now ? $0 : nil }
  }
}

@Observable @MainActor final class UsageStore {
  let settings: AppSettings
  let isDemo: Bool
  private let cache: SnapshotCache
  private let historyFile: QuotaHistoryFile

  private(set) var snapshot: UsageSnapshot?
  private(set) var isLoading = false
  /// Set when the last refresh failed as a whole (the engine could not run).
  private(set) var lastError: String?
  private(set) var lastAttempt: Date?
  /// True once a cached or fresh snapshot has been looked for.
  private(set) var didLoad = false

  private(set) var quota: QuotaReport?
  private(set) var quotaHistory = QuotaHistory()
  private(set) var quotaCheckedAt: Date?
  private(set) var quotaError: String?
  private(set) var isCheckingQuotas = false
  /// Advances every quota poll so time-based labels stay current.
  private(set) var clock = Date.now

  var route: Route = .overview
  var period: Period = .last30
  /// Chart granularity chosen by the user; `nil` follows the period length.
  var granularity: Granularity?

  private var refreshTask: Task<Void, Never>?
  private var refreshAgain = false
  private var autoRefresh: Task<Void, Never>?
  private var quotaLoop: Task<Void, Never>?
  private var pendingHardQuota = false
  private var started = false

  init(
    settings: AppSettings = AppSettings(), cache: SnapshotCache = .standard,
    historyFile: QuotaHistoryFile = .standard, isDemo: Bool
  ) {
    self.settings = settings
    self.cache = cache
    self.historyFile = historyFile
    self.isDemo = isDemo
  }

  var calendar: DayCalendar { DayCalendar(timeZone: .current) }

  func dashboard(for harness: Harness?, now: Date = .now) -> Dashboard {
    Dashboard.compute(
      snapshot: snapshot, harness: harness, period: period, now: now, days: calendar,
      resetStart: resetStart(for: harness))
  }

  func start() {
    guard !started else { return }
    started = true
    settings.appearance.apply()
    settings.applyActivationPolicy()
    // BURNLESS_APPEARANCE=light|dark for screenshots; not saved to preferences.
    if let forced = ProcessInfo.processInfo.environment["BURNLESS_APPEARANCE"].flatMap(
      Appearance.init(rawValue:))
    {
      forced.apply()
    }
    if isDemo {
      let now = Date.now
      snapshot = DemoData.snapshot(now: now, days: calendar)
      let demo = DemoData.quota(now: now)
      quota = demo.report
      quotaHistory = demo.history
      quotaCheckedAt = now
      lastAttempt = now
      didLoad = true
      return
    }
    snapshot = cache.load()
    quotaHistory = historyFile.load() ?? QuotaHistory()
    didLoad = snapshot != nil
    refresh()
    scheduleAutoRefresh()
    startQuotaLoop()
    UpdateChecker.shared.checkIfDue(settings: settings)
  }

  /// Usage and quotas together (⌘R).
  func refreshAll() {
    refresh()
    checkQuotas()
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

  private func engineConfiguration() -> EngineConfiguration? {
    guard let executable = EngineClient.locate() else { return nil }
    return EngineConfiguration(
      executable: executable, claudeDirectory: settings.engineClaudeDirectory,
      codexHome: settings.engineCodexHome, geminiDirectory: settings.engineGeminiDirectory,
      onlinePricing: settings.onlinePricing,
      timeZone: .current)
  }

  private func runRefresh() async {
    isLoading = true
    defer {
      isLoading = false
      didLoad = true
    }
    let now = Date.now
    lastAttempt = now
    guard let configuration = engineConfiguration() else {
      lastError = EngineError.missing.localizedDescription
      return
    }
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

  // MARK: - Quotas

  private func startQuotaLoop() {
    quotaLoop?.cancel()
    quotaLoop = Task { [weak self] in
      while !Task.isCancelled {
        await self?.runQuotaCheck(hard: false)
        try? await Task.sleep(for: .seconds(60))
      }
    }
  }

  /// Reads plans and meters now. `hard` also retries a paused live read.
  func checkQuotas(hard: Bool = false) {
    guard !isDemo else { return }
    Task { await runQuotaCheck(hard: hard) }
  }

  private func runQuotaCheck(hard: Bool) async {
    clock = .now
    guard !isCheckingQuotas else {
      if hard { pendingHardQuota = true }
      return
    }
    isCheckingQuotas = true
    defer { isCheckingQuotas = false }
    var hard = hard
    repeat {
      pendingHardQuota = false
      await collectQuota(hard: hard)
      hard = pendingHardQuota
    } while hard
  }

  private func collectQuota(hard: Bool) async {
    guard let configuration = engineConfiguration() else {
      quotaError = EngineError.missing.localizedDescription
      return
    }
    let live = settings.liveQuotas
    let liveClaude = live && LivePacing.claudeDue(force: hard)
    do {
      let report = try await EngineClient.quota(
        configuration, liveClaude: liveClaude, liveCodex: live)
      if liveClaude { LivePacing.record(report.claude.live) }
      quota = report
      quotaCheckedAt = .now
      clock = .now
      quotaError = nil
      do { quotaHistory = try historyFile.commit(report.readings) } catch {
        quotaError = "Quota readings could not be saved: \(error.localizedDescription)"
      }
    } catch {
      quotaError = error.localizedDescription
    }
  }

  func plan(for harness: Harness) -> SubscriptionPlan {
    switch harness {
    case .claude:
      PlanCatalog.apply(
        settings.claudePlan, to: PlanCatalog.claude(tier: quota?.claude.planTier), harness: .claude)
    case .codex:
      PlanCatalog.apply(
        settings.codexPlan, to: PlanCatalog.codex(planType: quota?.codex.planType), harness: .codex)
    case .gemini:
      PlanCatalog.apply(settings.geminiPlan, to: SubscriptionPlan(), harness: .gemini)
    }
  }

  /// The newest trustworthy reading of a meter: the history's current one,
  /// or this poll's when the history could not be written.
  func reading(_ series: QuotaSeries) -> QuotaReading? {
    let stored = quotaHistory.current(series)
    let fresh = quota?.readings[series]
    switch (stored, fresh) {
    case (let stored?, let fresh?): return fresh.observedAt > stored.observedAt ? fresh : stored
    case (let stored, let fresh): return stored ?? fresh
    }
  }

  func forecast(_ series: QuotaSeries) -> Forecast? { reading(series).map(Forecast.init(reading:)) }

  /// Weekly limit window of a harness.
  func weekly(_ harness: Harness) -> Forecast? {
    switch harness {
    case .claude: forecast(.claudeWeekly)
    case .codex: forecast(.codexWeekly)
    case .gemini: nil
    }
  }

  /// Weekly remaining for badges. `nil` once the window has reset without a
  /// newer reading: usage since then is unknown, so it is not shown as 100%.
  func remaining(_ harness: Harness) -> Double? {
    guard let weekly = weekly(harness), !weekly.hasReset(at: clock) else { return nil }
    return weekly.remaining
  }

  func samples(_ series: QuotaSeries, range: QuotaChartRange) -> [QuotaSample] {
    guard let forecast = forecast(series) else { return [] }
    return QuotaChart.samples(
      quotaHistory.samples(series), range: range, forecast: forecast, now: clock)
  }

  func resets(_ series: QuotaSeries) -> [QuotaReset] { quotaHistory.resets(series) }

  /// Start of the current weekly window, for the Reset to date period.
  func resetStart(for harness: Harness?) -> Date? {
    guard let forecast = weekly(harness ?? settings.menuBarQuota) else { return nil }
    return forecast.hasReset(at: clock) ? forecast.reset : forecast.start
  }

  /// Spend and blend rates over the current weekly window.
  func cycle(_ harness: Harness) -> (forecast: Forecast, estimate: QuotaValueEstimate?)? {
    guard let forecast = weekly(harness), !forecast.hasReset(at: clock) else { return nil }
    let spend = SubscriptionMath.cycleSpend(
      snapshot, harness: harness, since: forecast.start, now: clock, calendar: calendar)
    let estimate = QuotaValueEstimate.make(
      cycleSpend: spend.cost, cycleTokens: spend.tokens, forecast: forecast,
      price: plan(for: harness).pricePerMonth)
    return (forecast, estimate)
  }

  var liveStatus: (claude: LiveStatus, codex: LiveStatus)? {
    quota.map { ($0.claude.live, $0.codex.live) }
  }
}
