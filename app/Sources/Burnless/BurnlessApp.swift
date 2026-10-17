import AppKit
import BurnlessCore
import SwiftUI

@main
struct BurnlessApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @State private var store: UsageStore

  init() {
    let arguments = ProcessInfo.processInfo.arguments
    let demo =
      arguments.contains("--demo") || ProcessInfo.processInfo.environment["BURNLESS_DEMO"] == "1"
    let store = UsageStore(isDemo: demo)
    if let route = arguments.firstIndex(of: "--route").flatMap({ arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }) {
      store.route = route == "claude" ? .harness(.claude) : route == "codex" ? .harness(.codex) : route == "settings" ? .settings : .overview
    }
    if let period = arguments.firstIndex(of: "--period").flatMap({ arguments.indices.contains($0 + 1) ? Period(rawValue: arguments[$0 + 1]) : nil }) {
      store.period = period
    }
    _store = State(initialValue: store)
  }

  var body: some Scene {
    Window("Burnless", id: "dashboard") {
      MainView()
        .environment(store)
        .task { store.start() }
    }
    .defaultSize(width: 1180, height: 820)
    .windowToolbarStyle(.unified)
    .commands {
      CommandGroup(after: .toolbar) {
        Button("Refresh") { store.refresh() }
          .keyboardShortcut("r")
          .disabled(store.isDemo)
      }
      CommandGroup(replacing: .appSettings) {
        Button("Settings…") { store.route = .settings }
          .keyboardShortcut(",")
      }
    }
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    // Running from `swift run` has no bundle icon; use the packaged one.
    if let url = Bundle.module.url(forResource: "AppIcon", withExtension: "icns"),
      let image = NSImage(contentsOf: url)
    {
      NSApp.applicationIconImage = image
    }
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct MainView: View {
  @Environment(UsageStore.self) private var store

  var body: some View {
    NavigationSplitView {
      Sidebar()
        .navigationSplitViewColumnWidth(min: 190, ideal: 214, max: 280)
    } detail: {
      VStack(spacing: 0) {
        ScrollView {
          Group {
            switch store.route {
            case .settings: SettingsView()
            case .overview: DashboardView(harness: nil)
            case .harness(let harness): DashboardView(harness: harness)
            }
          }
          .id(store.route)
          .padding(20)
          .frame(maxWidth: 1280)
          .frame(maxWidth: .infinity)
        }
        Divider()
        StatusFooter().padding(.horizontal, 18).padding(.vertical, 8)
      }
      .background(BurnTheme.background)
      .navigationTitle(store.route.title)
      .navigationSubtitle(store.route == .settings ? "" : store.period.label)
    }
    .frame(minWidth: 720, minHeight: 520)
    .tint(BurnTheme.ember)
    .toolbar {
      if store.route != .settings {
        ToolbarItem(placement: .primaryAction) {
          @Bindable var store = store
          Picker("Period", selection: $store.period) {
            ForEach(Period.allCases) { Text($0.label).tag($0) }
          }
          .frame(width: 140)
          .help("Spend period")
          .accessibilityLabel("Period")
        }
      }
      ToolbarItem(placement: .primaryAction) {
        Button {
          store.refresh()
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
            .symbolEffect(.pulse, isActive: store.isLoading)
        }
        .disabled(store.isDemo)
        .help("Refresh usage (⌘R)")
      }
    }
  }
}

private struct Sidebar: View {
  @Environment(UsageStore.self) private var store

  private var selection: Binding<Route?> {
    Binding(get: { store.route }, set: { if let route = $0 { store.route = route } })
  }

  var body: some View {
    let all = store.dashboard(for: nil)
    List(selection: selection) {
      row(.overview, title: "All harnesses", cost: store.snapshot == nil ? nil : all.totals) {
        IconBadge(symbol: "flame.fill", size: 20)
      }
      Section("Harnesses") {
        ForEach(Harness.allCases) { harness in
          let summary = all.harnesses.first { $0.harness == harness }
          row(
            .harness(harness), title: harness.name,
            cost: summary?.availability.hasData == true ? summary?.totals : nil
          ) {
            HarnessBadge(harness: harness, size: 20)
          }
        }
      }
      Section {
        Label("Settings", systemImage: "gearshape").tag(Route.settings)
      }
    }
    .listStyle(.sidebar)
  }

  private func row<Icon: View>(
    _ route: Route, title: String, cost: SpendTotals?, @ViewBuilder icon: () -> Icon
  ) -> some View {
    HStack(spacing: 9) {
      icon()
      Text(title).lineLimit(1)
      Spacer(minLength: 6)
      if let cost {
        Text(Format.spend(cost)).font(.system(size: 11)).monospacedDigit()
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 2)
    .tag(route)
    .accessibilityElement(children: .combine)
  }
}

private struct StatusFooter: View {
  @Environment(UsageStore.self) private var store

  var body: some View {
    HStack(spacing: 14) {
      if store.isDemo {
        Label("Demo data", systemImage: "theatermasks").foregroundStyle(BurnTheme.warning)
      } else {
        ForEach(Harness.allCases) { harness in
          HStack(spacing: 5) {
            Text(harness.name)
            StatusPill(availability: store.snapshot?.availability(harness))
          }
        }
      }
      Spacer()
      if store.isLoading {
        ProgressView().controlSize(.small)
        Text("Reading history…")
      } else if let date = store.snapshot?.refreshedAt {
        Text("Updated \(date.formatted(date: .omitted, time: .shortened))")
          .help(date.formatted(date: .complete, time: .standard))
      }
    }
    .font(.system(size: 11)).foregroundStyle(.secondary)
  }
}
