// Settings tabs follow Agent Burn's SettingsView
// (https://github.com/Melvynx/agent-burn, MIT).

import AppKit
import BurnlessCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
  @Environment(UsageStore.self) private var store
  var initialTab = SettingsTab.general
  @State private var tab = SettingsTab.general

  var body: some View {
    TabView(selection: $tab) {
      GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
      DataSettings().tabItem { Label("Data", systemImage: "externaldrive") }.tag(SettingsTab.data)
      QuotaSettings().tabItem { Label("Quotas", systemImage: "gauge.with.dots.needle.67percent") }
        .tag(SettingsTab.quotas)
      BackgroundSettings().tabItem { Label("Background", systemImage: "clock.arrow.circlepath") }
        .tag(SettingsTab.background)
      UpdateSettings().tabItem { Label("Updates", systemImage: "arrow.down.circle") }.tag(SettingsTab.updates)
      AboutSettings().tabItem { Label("About", systemImage: "flame") }.tag(SettingsTab.about)
    }
    .frame(width: 620, height: 600)
    .onAppear { tab = initialTab }
  }
}

enum SettingsTab: String, Hashable {
  case general, data, quotas, background, updates, about
}

// MARK: - General

private struct GeneralSettings: View {
  @Environment(UsageStore.self) private var store
  @State private var loginItem = ServiceToggle.mainApp()

  var body: some View {
    @Bindable var settings = store.settings
    Form {
      Section("Appearance") {
        Picker("Theme", selection: $settings.appearance) {
          ForEach(Appearance.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
      }
      Section {
        Toggle(
          "Launch at login",
          isOn: Binding(get: { loginItem.isEnabled }, set: { value in Task { await loginItem.setEnabled(value) } })
        )
        .disabled(loginItem.isUpdating)
        ServiceStatusText(item: loginItem, approval: "Allow Burnless in System Settings → Login Items to finish.")
      } header: {
        Text("Startup")
      } footer: {
        Text("Start Burnless when you sign in to your Mac. The menu-bar-only choice is respected.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section {
        Toggle("Show in menu bar", isOn: $settings.showInMenuBar)
          .onChange(of: settings.showInMenuBar) { settings.applyActivationPolicy() }
        Toggle("Menu bar only", isOn: $settings.menuBarOnly).disabled(!settings.showInMenuBar)
        Picker("Show remaining", selection: $settings.menuBarQuota) {
          ForEach(Harness.allCases.filter(\.readsLimits)) { Text($0.name).tag($0) }
        }
      } header: {
        Text("Menu bar")
      } footer: {
        Text(
          "The menu bar and the window toolbar show this harness's weekly limit remaining. Menu bar only hides Burnless from the Dock and Command-Tab; open the dashboard from the menu bar."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .onAppear { loginItem.refresh() }
  }
}

// MARK: - Data

private struct DataSettings: View {
  @Environment(UsageStore.self) private var store

  var body: some View {
    @Bindable var settings = store.settings
    Form {
      Section {
        ForEach(Harness.allCases) { harness in SourceRow(harness: harness) }
      } header: {
        Text("Sources")
      } footer: {
        Text(
          "Burnless only reads these folders. It never modifies logs, credentials or tool settings, and it does not store prompts or conversations."
        )
        .font(.caption).foregroundStyle(.secondary)
      }

      Section {
        Picker("Refresh usage", selection: $settings.refreshMinutes) {
          Text("Every minute").tag(1)
          Text("Every 5 minutes").tag(5)
          Text("Every 15 minutes").tag(15)
          Text("Every 30 minutes").tag(30)
          Text("Never").tag(0)
        }
        .onChange(of: settings.refreshMinutes) { store.scheduleAutoRefresh() }
        LabeledContent("Last refresh") {
          Text(store.lastAttempt.map { $0.formatted(date: .abbreviated, time: .standard) } ?? "Never")
        }
        LabeledContent("Local cache") {
          Button("Show in Finder") { revealCacheFolder() }
        }
        Button(store.isLoading ? "Refreshing…" : "Apply and refresh") { store.refreshAll() }
          .disabled(store.isLoading || store.isDemo)
      } header: {
        Text("Refresh")
      } footer: {
        Text(
          "Usage refreshes while Burnless is open; limits are checked every minute. The cache in ~/Library/Application Support/Burnless keeps the last valid data if a read fails."
        )
        .font(.caption).foregroundStyle(.secondary)
      }

      Section {
        Toggle("Fetch current prices when refreshing", isOn: $settings.onlinePricing)
          .onChange(of: settings.onlinePricing) { store.refresh() }
        if let pricing = store.snapshot?.pricing {
          LabeledContent("Pricing snapshot") {
            Text("LiteLLM \(pricing.litellmRevision.prefix(7)) · \(pricing.snapshotDate)").textSelection(.enabled)
          }
          if pricing.online {
            LabeledContent("Current prices") {
              Text(pricing.onlineFetched == true ? "Downloaded on last refresh" : "Download failed · using bundled snapshot")
                .foregroundStyle(pricing.onlineFetched == true ? Color.secondary : BurnTheme.warning)
            }
          }
          LabeledContent("Engine") { Text("ccusage \(pricing.ccusageRevision.prefix(7))").textSelection(.enabled) }
        }
      } header: {
        Text("Pricing")
      } footer: {
        Text(
          "Costs use public per-token API prices from a LiteLLM snapshot bundled with the app, so Burnless works offline. When enabled, each refresh also downloads LiteLLM's public price list from GitHub; no usage data is sent. API-equivalent usage estimates token value, not your subscription bill."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }
}

func revealCacheFolder() {
  let url = SnapshotCache.standard.directory
  try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  NSWorkspace.shared.activateFileViewerSelecting([url])
}

private struct SourceRow: View {
  @Environment(UsageStore.self) private var store
  let harness: Harness

  private var override: Binding<String> {
    switch harness {
    case .claude: Binding(get: { store.settings.claudeDirectory }, set: { store.settings.claudeDirectory = $0 })
    case .codex: Binding(get: { store.settings.codexHome }, set: { store.settings.codexHome = $0 })
    case .gemini: Binding(get: { store.settings.geminiDirectory }, set: { store.settings.geminiDirectory = $0 })
    }
  }

  var body: some View {
    let source = store.snapshot?.source(harness)
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        HarnessBadge(harness: harness, size: 20)
        Text(harness.name).font(.system(size: 13, weight: .semibold))
        Spacer()
        StatusPill(availability: store.isDemo ? .live : source?.availability)
      }
      if let source {
        let paths = source.status.paths.isEmpty ? source.status.searched : source.status.paths
        Text((source.status.paths.isEmpty ? "Looked in: " : "Reading: ") + paths.joined(separator: ", "))
          .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        if let error = source.status.error {
          Text(error).font(.caption).foregroundStyle(BurnTheme.warning).textSelection(.enabled)
        }
      }
      HStack {
        Text(override.wrappedValue.isEmpty ? "Default location" : override.wrappedValue)
          .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        Spacer()
        Button("Choose Folder…") { choose() }
        if !override.wrappedValue.isEmpty {
          Button("Use Default") {
            override.wrappedValue = ""
            store.refreshAll()
          }
        }
      }
      Text(folderHint)
      .font(.caption2).foregroundStyle(.tertiary)
    }
    .padding(.vertical, 4)
  }

  private var folderHint: String {
    switch harness {
    case .claude:
      "Pick a Claude config folder (containing projects/) or the projects folder itself. Same as CLAUDE_CONFIG_DIR."
    case .codex: "Pick a Codex home folder (containing sessions/). Same as CODEX_HOME."
    case .gemini: "Pick Gemini CLI's data folder (~/.gemini/tmp, holding <project>/chats/). Same as GEMINI_DATA_DIR."
    }
  }

  private func choose() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.showsHiddenFiles = true
    panel.prompt = "Use Folder"
    panel.message = "Choose the \(harness.name) history folder"
    if panel.runModal() == .OK, let url = panel.url {
      override.wrappedValue = url.path
      store.refreshAll()
    }
  }
}

// MARK: - Quotas

private struct QuotaSettings: View {
  @Environment(UsageStore.self) private var store

  var body: some View {
    @Bindable var settings = store.settings
    Form {
      Section {
        Toggle("Read live limits from Anthropic and OpenAI", isOn: $settings.liveQuotas)
          .onChange(of: settings.liveQuotas) { store.checkQuotas(hard: true) }
        if settings.liveQuotas, let live = store.liveStatus {
          LabeledContent("Claude") { LiveStateText(status: live.claude) }
          LabeledContent("Codex") { LiveStateText(status: live.codex) }
          if let blocked = LivePacing.blockedUntil() {
            LabeledContent("Next Claude check") {
              Text(blocked.formatted(date: .omitted, time: .shortened)).monospacedDigit()
            }
          }
        }
      } header: {
        Text("Limits")
      } footer: {
        VStack(alignment: .leading, spacing: 6) {
          Text(
            "Off: limits come from files already on this Mac. Codex logs its weekly limit with each request; Claude Code saves its meters in ~/.claude.json when it checks them. No sign-in is read and nothing is sent."
          )
          Text(
            "On: once a minute Burnless also asks chatgpt.com and api.anthropic.com, the endpoints Codex and Claude Code use themselves. It reads your existing sign-in from ~/.codex/auth.json and Claude Code's Keychain item (macOS asks once), strictly read-only: tokens are never renewed, written, stored or sent anywhere else."
          )
        }
        .font(.caption).foregroundStyle(.secondary)
      }

      Section {
        PlanRow(harness: .claude, text: $settings.claudePlan)
        PlanRow(harness: .codex, text: $settings.codexPlan)
        PlanRow(harness: .gemini, text: $settings.geminiPlan)
      } header: {
        Text("Plans")
      } footer: {
        Text(
          "Detected from ~/.claude.json and Codex's logs. Gemini CLI logs no plan: enter plus, pro or ultra (Google AI plans). Enter a monthly price (for example 200) or a plan name (pro, max-5x, max-20x, plus) to override a plan. Unknown prices are left blank, never treated as $0."
        )
        .font(.caption).foregroundStyle(.secondary)
      }

      Section {
        LabeledContent("Readings") {
          Text(QuotaSeries.allCases.map { store.quotaHistory.all($0).count }.reduce(0, +).formatted())
            .monospacedDigit()
        }
        LabeledContent("Last check") {
          Text(store.quotaCheckedAt.map { $0.formatted(date: .omitted, time: .standard) } ?? "Never")
            .monospacedDigit()
        }
        if let error = store.quotaError { Text(error).font(.caption).foregroundStyle(BurnTheme.warning) }
        LabeledContent("History file") { Button("Show in Finder") { revealCacheFolder() } }
      } header: {
        Text("History")
      } footer: {
        Text(
          "quota-history.json keeps percentages and reset times (120 days) for the quota charts. It holds no prompts, tokens or account details."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }
}

private struct PlanRow: View {
  @Environment(UsageStore.self) private var store
  let harness: Harness
  @Binding var text: String

  var body: some View {
    let plan = store.plan(for: harness)
    LabeledContent {
      TextField("Override", text: $text, prompt: Text(harness.readsLimits ? "Detected" : "plus, pro…"))
        .labelsHidden()
        .frame(width: 110)
        .multilineTextAlignment(.trailing)
    } label: {
      HStack(spacing: 8) {
        HarnessBadge(harness: harness, size: 18)
        VStack(alignment: .leading, spacing: 2) {
          Text(harness.name)
          Text(plan.label + (plan.detected.map { " · detected \($0)" } ?? ""))
            .font(.caption).foregroundStyle(.secondary)
        }
      }
    }
  }
}

private struct LiveStateText: View {
  let status: LiveStatus
  var body: some View {
    let (text, color): (String, Color) =
      switch status.state {
      case .ok: ("Live", .green)
      case .off: ("Paused", .secondary)
      case .noSignIn: ("No readable sign-in", BurnTheme.warning)
      case .signInExpired: ("Sign-in expired · open the app to renew", BurnTheme.warning)
      case .unauthorized: ("Sign-in refused", .red)
      case .rateLimited: ("Rate limited · retrying later", BurnTheme.warning)
      case .failed: ("Request failed · using saved data", BurnTheme.warning)
      }
    Text(text).foregroundStyle(color)
  }
}

// MARK: - Background

private struct BackgroundSettings: View {
  @State private var agent = ServiceToggle.collector()

  var body: some View {
    Form {
      Section {
        Toggle(
          "Collect limits every minute",
          isOn: Binding(get: { agent.isEnabled }, set: { value in Task { await agent.setEnabled(value) } })
        )
        .disabled(agent.isUpdating)
        ServiceStatusText(item: agent, approval: "Allow Burnless to run in the background in System Settings → Login Items.")
      } header: {
        Text("Background quota history")
      } footer: {
        Text(
          "Records Claude and Codex limit readings even after you quit Burnless, so the quota charts have no gaps. It runs the same read as the app (local files, plus live limits if you turned them on) and stops when you turn this off."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .onAppear { agent.refresh() }
  }
}

private struct ServiceStatusText: View {
  let item: ServiceToggle
  let approval: String
  var body: some View {
    if item.requiresApproval {
      Text(approval).font(.caption).foregroundStyle(.secondary)
      Button("Open Login Items Settings…") { SMAppService.openSystemSettingsLoginItems() }
    }
    if let error = item.errorMessage {
      Text(error).font(.caption).foregroundStyle(.red)
    }
  }
}

/// A ServiceManagement registration (login item or launch agent).
@Observable @MainActor final class ServiceToggle {
  // SMAppService is not Sendable; it is only used from the main actor.
  private nonisolated(unsafe) let service: SMAppService
  private(set) var status: SMAppService.Status
  private(set) var isUpdating = false
  private(set) var errorMessage: String?

  init(service: SMAppService) {
    self.service = service
    status = service.status
  }

  static func mainApp() -> ServiceToggle { ServiceToggle(service: .mainApp) }
  static func collector() -> ServiceToggle { ServiceToggle(service: QuotaCollector.service) }

  var isEnabled: Bool { status == .enabled || status == .requiresApproval }
  var requiresApproval: Bool { status == .requiresApproval }

  func refresh() { status = service.status }

  func setEnabled(_ enabled: Bool) async {
    guard !isUpdating else { return }
    isUpdating = true
    errorMessage = nil
    defer {
      refresh()
      isUpdating = false
    }
    do {
      if enabled { try service.register() } else { try await service.unregister() }
    } catch {
      errorMessage = "Could not change this setting: \(error.localizedDescription)"
    }
  }
}

// MARK: - Updates

private struct UpdateSettings: View {
  @Environment(UsageStore.self) private var store
  private var checker: UpdateChecker { UpdateChecker.shared }

  var body: some View {
    @Bindable var settings = store.settings
    Form {
      Section {
        Toggle("Automatically check for updates", isOn: $settings.checkForUpdates)
        HStack {
          Button("Check for Updates…") { Task { await checker.check() } }.disabled(checker.isChecking)
          Spacer()
          UpdateStatusText()
        }
      } header: {
        Text("App updates")
      } footer: {
        Text(
          "Checks the latest release of github.com/Hug0x0/burnless once a day when enabled. Only the public release list is requested; nothing about your usage is sent."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }
}

struct UpdateStatusText: View {
  private var checker: UpdateChecker { UpdateChecker.shared }
  var body: some View {
    switch checker.state {
    case .idle: EmptyView()
    case .checking: ProgressView().controlSize(.small)
    case .upToDate: Text("Burnless is up to date.").foregroundStyle(.secondary)
    case .noReleases: Text("No release published yet.").foregroundStyle(.secondary)
    case .available(let version, let url):
      Link("Version \(version) available", destination: url)
    case .failed(let message): Text(message).foregroundStyle(BurnTheme.warning)
    }
  }
}

// MARK: - About

private struct AboutSettings: View {
  var body: some View {
    VStack(spacing: 14) {
      Spacer()
      Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high)
        .frame(width: 96, height: 96)
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .accessibilityHidden(true)
      VStack(spacing: 4) {
        Text("Burnless").font(.system(size: 22, weight: .bold, design: .rounded))
        Text("Version \(appVersion)").font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
      }
      Text(
        "Spend, tokens and subscription limits for Claude Code, Codex and Gemini CLI. Usage is read from local logs and never sent to a Burnless service."
      )
      .font(.system(size: 12)).foregroundStyle(.secondary)
      .multilineTextAlignment(.center).frame(maxWidth: 400)
      HStack(spacing: 10) {
        Link(destination: URL(string: "https://github.com/Hug0x0/burnless")!) {
          Label("Source code", systemImage: "chevron.left.forwardslash.chevron.right")
        }
        Link(destination: URL(string: "https://github.com/Melvynx/agent-burn")!) {
          Label("Agent Burn", systemImage: "flame")
        }
        Link(destination: URL(string: "https://github.com/ccusage/ccusage")!) {
          Label("ccusage", systemImage: "terminal")
        }
      }
      .buttonStyle(.bordered)
      Spacer()
      Text(
        "MIT licensed · Built on ccusage (© ryoppippi) · Adapted from Agent Burn (© ryoppippi, © Melvynx) · Prices from LiteLLM (© Berri AI)"
      )
      .font(.system(size: 11)).foregroundStyle(.tertiary).multilineTextAlignment(.center)
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

var appVersion: String {
  let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
  let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
  guard let short else { return "development" }
  return build.map { "\(short) (\($0))" } ?? short
}

struct StatusPill: View {
  let availability: SourceAvailability?
  var label: String? = nil
  var body: some View {
    let (text, color): (String, Color) =
      switch availability {
      case .live: ("Connected", .green)
      case .stale: ("Saved data", BurnTheme.warning)
      case .notFound: ("Not found", .secondary)
      case .failed: ("Error", .red)
      case nil: ("Not read", .secondary)
      }
    HStack(spacing: 5) {
      Circle().fill(color).frame(width: 6, height: 6)
      Text(label.map { "\($0) · \(text)" } ?? text).font(.system(size: 11, weight: .medium))
    }
    .foregroundStyle(color)
    .padding(.horizontal, 8).padding(.vertical, 3)
    .background(color.opacity(0.1), in: Capsule())
    .accessibilityElement(children: .combine)
  }
}
