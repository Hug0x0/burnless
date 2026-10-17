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
    // Launch options for screenshots and checks. Environment variables, not
    // arguments: AppKit treats bare arguments as documents to open.
    let environment = ProcessInfo.processInfo.environment
    switch environment["BURNLESS_ROUTE"] {
    case "claude": store.route = .harness(.claude)
    case "codex": store.route = .harness(.codex)
    case "settings": store.route = .settings
    default: break
    }
    if let period = environment["BURNLESS_PERIOD"].flatMap(Period.init(rawValue:)) {
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
    // Inside Burnless.app the Info.plist icon applies. `swift run` has no
    // bundle, so load the icon from the SwiftPM resource bundle instead.
    if Bundle.main.bundleURL.pathExtension != "app",
      let url = Bundle.module.url(forResource: "AppIcon", withExtension: "icns"),
      let image = NSImage(contentsOf: url)
    {
      NSApp.applicationIconImage = image
    }
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    WindowCapture.scheduleIfRequested()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct MainView: View {
  @Environment(UsageStore.self) private var store

  var body: some View {
    NavigationSplitView {
      Sidebar()
        .navigationSplitViewColumnWidth(min: 236, ideal: 244, max: 320)
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

/// `BURNLESS_CAPTURE=<file.png>` renders the app's own window into a PNG and
/// quits (optional `BURNLESS_CAPTURE_DELAY` seconds, `BURNLESS_WINDOW_SIZE`
/// like `1180x900`). Used for README screenshots and visual checks; it needs
/// no Screen Recording permission because the app draws its own views.
/// Environment variables are used because AppKit treats path arguments as
/// documents to open, which suppresses the main window.
@MainActor enum WindowCapture {
  static var isActive: Bool { ProcessInfo.processInfo.environment["BURNLESS_CAPTURE"] != nil }

  static func scheduleIfRequested() {
    let environment = ProcessInfo.processInfo.environment
    guard let path = environment["BURNLESS_CAPTURE"], !path.isEmpty else { return }
    let delay = environment["BURNLESS_CAPTURE_DELAY"].flatMap(Double.init) ?? 6
    let size = environment["BURNLESS_WINDOW_SIZE"]?.split(separator: "x").compactMap { Double($0) }
    if let size, size.count == 2 {
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        mainWindow?.setContentSize(NSSize(width: size[0], height: size[1]))
      }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
      defer { NSApp.terminate(nil) }
      guard let view = mainWindow?.contentView,
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
      else {
        FileHandle.standardError.write(Data("capture: no window\n".utf8))
        return
      }
      view.cacheDisplay(in: view.bounds, to: rep)
      do {
        try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
      } catch {
        FileHandle.standardError.write(Data("capture: \(error.localizedDescription)\n".utf8))
      }
    }
  }

  private static var mainWindow: NSWindow? {
    NSApp.windows.first { $0.frame.width > 300 && $0.contentView != nil }
  }
}
