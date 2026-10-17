import AppKit
import BurnlessCore
import SwiftUI

struct SettingsView: View {
  @Environment(UsageStore.self) private var store

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
        ForEach(Harness.allCases) { harness in
          SourceRow(harness: harness)
        }
      } header: {
        Text("Sources")
      } footer: {
        Text(
          "Burnless only reads these folders. It never modifies logs, credentials or tool settings, and it does not store prompts or conversations."
        )
        .font(.caption).foregroundStyle(.secondary)
      }

      Section {
        Picker("Refresh automatically", selection: $settings.refreshMinutes) {
          Text("Every minute").tag(1)
          Text("Every 5 minutes").tag(5)
          Text("Every 15 minutes").tag(15)
          Text("Never").tag(0)
        }
        .onChange(of: settings.refreshMinutes) { store.scheduleAutoRefresh() }
        LabeledContent("Last refresh") {
          if let date = store.lastAttempt {
            Text(date.formatted(date: .abbreviated, time: .standard))
          } else {
            Text("Never")
          }
        }
        LabeledContent("Local cache") {
          Button("Show in Finder") {
            let url = SnapshotCache.standard.directory
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            NSWorkspace.shared.activateFileViewerSelecting([url])
          }
        }
      } header: {
        Text("Refresh")
      } footer: {
        Text(
          "Refresh runs only while Burnless is open. The cache in ~/Library/Application Support/Burnless keeps the last valid data if a read fails."
        )
        .font(.caption).foregroundStyle(.secondary)
      }

      Section {
        Toggle("Fetch current prices when refreshing", isOn: $settings.onlinePricing)
          .onChange(of: settings.onlinePricing) { store.refresh() }
        if let pricing = store.snapshot?.pricing {
          LabeledContent("Pricing snapshot") {
            Text("LiteLLM \(pricing.litellmRevision.prefix(7)) · \(pricing.snapshotDate)")
              .textSelection(.enabled)
          }
          if pricing.online {
            LabeledContent("Current prices") {
              Text(pricing.onlineFetched == true ? "Downloaded on last refresh" : "Download failed · using bundled snapshot")
                .foregroundStyle(pricing.onlineFetched == true ? Color.secondary : BurnTheme.warning)
            }
          }
          LabeledContent("Engine") {
            Text("ccusage \(pricing.ccusageRevision.prefix(7))").textSelection(.enabled)
          }
        }
      } header: {
        Text("Pricing")
      } footer: {
        Text(
          "Costs use public per-token API prices from a LiteLLM snapshot bundled with the app, so Burnless works offline. When enabled, each refresh also downloads LiteLLM's public price list from GitHub; no usage data is sent. API-equivalent usage estimates token value, not your subscription bill."
        )
        .font(.caption).foregroundStyle(.secondary)
      }

      Section("About") {
        LabeledContent("Version") { Text(appVersion) }
        Text(
          "Burnless is built on ccusage (MIT, © ryoppippi) and adapts dashboard components from Agent Burn (MIT, © ryoppippi, © Melvynx). Pricing data from LiteLLM (MIT, © Berri AI)."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .frame(maxWidth: 720)
    .frame(maxWidth: .infinity)
  }

  private var appVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
  }
}

private struct SourceRow: View {
  @Environment(UsageStore.self) private var store
  let harness: Harness

  private var override: Binding<String> {
    switch harness {
    case .claude: Binding(get: { store.settings.claudeDirectory }, set: { store.settings.claudeDirectory = $0 })
    case .codex: Binding(get: { store.settings.codexHome }, set: { store.settings.codexHome = $0 })
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
            store.refresh()
          }
        }
      }
      Text(
        harness == .claude
          ? "Pick a Claude config folder (containing projects/) or the projects folder itself. Same as CLAUDE_CONFIG_DIR."
          : "Pick a Codex home folder (containing sessions/). Same as CODEX_HOME."
      )
      .font(.caption2).foregroundStyle(.tertiary)
    }
    .padding(.vertical, 4)
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
      store.refresh()
    }
  }
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
