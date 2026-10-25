import AppKit
import BurnlessCore
import SwiftUI

@main
enum BurnlessMain {
  static func main() {
    // launchd runs the bundled binary with this flag for background collection.
    if CommandLine.arguments.contains("--collect-quotas") {
      exit(QuotaCollector.collectOnce())
    }
    BurnlessApp.main()
  }
}

struct BurnlessApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @State private var store: UsageStore
  // Bound through UserDefaults: binding the observable store here makes
  // SwiftUI rebuild the scenes (and the main menu) in a loop.
  @AppStorage("showInMenuBar") private var showInMenuBar = true

  init() {
    let arguments = ProcessInfo.processInfo.arguments
    let environment = ProcessInfo.processInfo.environment
    let demo = arguments.contains("--demo") || environment["BURNLESS_DEMO"] == "1"
    let store = UsageStore(settings: demo ? .demo : AppSettings(), isDemo: demo)
    // Launch options for screenshots and checks. Environment variables, not
    // arguments: AppKit treats bare arguments as documents to open.
    switch environment["BURNLESS_ROUTE"] {
    case "claude": store.route = .harness(.claude)
    case "codex": store.route = .harness(.codex)
    case "gemini": store.route = .harness(.gemini)
    default: break
    }
    if let period = environment["BURNLESS_PERIOD"].flatMap(Period.init(rawValue:)) {
      store.period = period
    }
    _store = State(initialValue: store)
    // Started here rather than from a window, so menu-bar-only mode and the
    // menu bar extra work without the dashboard open.
    Task { @MainActor in store.start() }
  }

  var body: some Scene {
    Window("Burnless", id: "dashboard") {
      MainView().environment(store)
    }
    .defaultSize(width: 1240, height: 860)
    .windowToolbarStyle(.unified)
    .commands {
      CommandGroup(after: .appInfo) {
        Button("Check for Updates…") { Task { await UpdateChecker.shared.check() } }
      }
      CommandMenu("Usage") {
        Button("Refresh") { store.refreshAll() }
          .keyboardShortcut("r")
          .disabled(store.isDemo)
        Button("Check Limits Now") { store.checkQuotas(hard: true) }
          .keyboardShortcut("r", modifiers: [.command, .shift])
          .disabled(store.isDemo)
      }
    }
    MenuBarExtra(isInserted: WindowCapture.isActive ? .constant(false) : $showInMenuBar) {
      MenuPopover().environment(store)
    } label: {
      MenuBarLabel(
        remaining: store.remaining(store.settings.menuBarQuota), stale: store.isStale(store.settings.menuBarQuota))
    }
    .menuBarExtraStyle(.window)
    // Screenshots of the menu bar popover render it in a plain window.
    Window("Burnless menu", id: "popover-preview") {
      MenuPopover().environment(store)
    }
    .windowResizability(.contentSize)
    Settings {
      SettingsView(initialTab: SettingsTab(rawValue: ProcessInfo.processInfo.environment["BURNLESS_SETTINGS_TAB"] ?? "") ?? .general)
        .environment(store)
    }
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    // Inside Burnless.app the Info.plist icon applies. `swift run` has no
    // bundle, so load the icon from the SwiftPM resource bundle instead.
    if Bundle.main.bundleURL.pathExtension != "app",
      let url = ResourceBundle.bundle.url(forResource: "AppIcon", withExtension: "icns"),
      let image = NSImage(contentsOf: url)
    {
      NSApp.applicationIconImage = image
    }
    let defaults = UserDefaults.standard
    let menuBarOnly = defaults.bool(forKey: "menuBarOnly") && (defaults.object(forKey: "showInMenuBar") as? Bool ?? true)
    if WindowCapture.isActive {
      // Captures render in the background: no Dock icon, no focus taken.
      NSApp.setActivationPolicy(.accessory)
    } else if menuBarOnly {
      NSApp.setActivationPolicy(.accessory)
      DispatchQueue.main.async {
        for window in NSApp.windows where window.identifier?.rawValue.contains("dashboard") == true {
          window.orderOut(nil)
        }
      }
    } else {
      NSApp.setActivationPolicy(.regular)
      NSApp.activate(ignoringOtherApps: true)
    }
    WindowCapture.scheduleIfRequested()
  }

  /// With the menu bar extra, closing the window keeps Burnless running.
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    !(UserDefaults.standard.object(forKey: "showInMenuBar") as? Bool ?? true)
  }
}

struct MainView: View {
  @Environment(UsageStore.self) private var store
  @Environment(\.openWindow) private var openWindow
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    NavigationSplitView {
      Sidebar()
        .navigationSplitViewColumnWidth(min: 220, ideal: 236, max: 320)
    } detail: {
      VStack(spacing: 0) {
        ScrollView {
          Group {
            switch store.route {
            case .overview: DashboardView(harness: nil)
            case .harness(let harness): DashboardView(harness: harness)
            }
          }
          .id(store.route)
          .transition(.opacity.combined(with: .offset(y: 8)))
          .padding(24)
          .frame(maxWidth: 1280)
          .frame(maxWidth: .infinity)
        }
        .animation(.smooth(duration: 0.3), value: store.route)
        Divider()
        StatusFooter().padding(.horizontal, 18).padding(.vertical, 8)
      }
      .background(BurnTheme.background)
      .navigationTitle(store.route.title)
    }
    .frame(minWidth: 760, minHeight: 540)
    .task {
      let environment = ProcessInfo.processInfo.environment
      if environment["BURNLESS_POPOVER"] == "1" { openWindow(id: "popover-preview") }
      if environment["BURNLESS_ROUTE"] == "settings" { openSettings() }
    }
    .toolbar {
      ToolbarItem(placement: .navigation) { QuotaSourceMenu() }
      ToolbarItemGroup(placement: .primaryAction) {
        Button {
          store.refreshAll()
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
            .symbolEffect(.pulse, isActive: store.isLoading)
        }
        .disabled(store.isDemo)
        .help("Refresh usage and limits (⌘R)")
        Button {
          store.checkQuotas(hard: true)
        } label: {
          Label("Check limits now", systemImage: "gauge.with.dots.needle.67percent")
            .symbolEffect(.pulse, isActive: store.isCheckingQuotas)
        }
        .disabled(store.isDemo || store.isCheckingQuotas)
        .help("Check limits now (⇧⌘R)")
        SettingsLink { Label("Settings", systemImage: "gearshape") }.help("Settings")
      }
    }
  }
}

/// Toolbar menu: the remaining weekly limit shown in the menu bar.
private struct QuotaSourceMenu: View {
  @Environment(UsageStore.self) private var store

  var body: some View {
    Menu {
      ForEach(Harness.allCases.filter(\.readsLimits)) { harness in
        Button {
          store.settings.menuBarQuota = harness
        } label: {
          Text(harness.name + (store.remaining(harness).map { " · \(Int($0.rounded(.down)))% left" } ?? ""))
        }
      }
    } label: {
      Text(
        store.remaining(store.settings.menuBarQuota).map {
          (store.isStale(store.settings.menuBarQuota) ? "~" : "") + "\(Int($0.rounded(.down)))%"
        } ?? "Burn"
      )
      .monospacedDigit().fontWeight(.medium).fixedSize()
    }
    .menuIndicator(.visible)
    .fixedSize()
    .help("Weekly limit remaining shown in the menu bar (\(store.settings.menuBarQuota.name))")
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
      row(.overview, title: "Overview") {
        OverviewMark(size: 20)
      } trailing: {
        if store.snapshot != nil { spend(all.totals) }
      }
      Section("Subscriptions") {
        ForEach(Harness.allCases) { harness in
          let summary = all.harnesses.first { $0.harness == harness }
          row(.harness(harness), title: harness.name) {
            HarnessBadge(harness: harness, size: 20)
          } trailing: {
            if let remaining = store.remaining(harness) {
              QuotaBadge(remaining: remaining, stale: store.isStale(harness))
                .help("\(harness.name) weekly limit remaining" + (store.isStale(harness) ? " · last reading may be out of date" : ""))
            } else if summary?.availability.hasData == true, let totals = summary?.totals {
              spend(totals)
            }
          }
        }
      }
    }
    .listStyle(.sidebar)
  }

  private func spend(_ totals: SpendTotals) -> some View {
    Text(Format.spend(totals)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
  }

  private func row<Icon: View, Trailing: View>(
    _ route: Route, title: String, @ViewBuilder icon: () -> Icon, @ViewBuilder trailing: () -> Trailing
  ) -> some View {
    HStack(spacing: 9) {
      icon()
      Text(title).lineLimit(1)
      Spacer(minLength: 6)
      trailing()
    }
    .padding(.vertical, 2)
    .tag(route)
    .accessibilityElement(children: .combine)
  }
}

/// Footer adapted from Agent Burn's RefreshFooter: freshness, sources,
/// version and a refresh button.
private struct StatusFooter: View {
  @Environment(UsageStore.self) private var store

  var body: some View {
    HStack(spacing: 7) {
      Circle().fill(store.lastError == nil ? Color.green : BurnTheme.ember).frame(width: 5, height: 5)
      if store.isDemo {
        Text("Demo data").foregroundStyle(BurnTheme.warning)
      } else if store.isLoading && store.snapshot == nil {
        Text("Updating usage…")
      } else if let date = store.snapshot?.refreshedAt {
        Text(store.lastError == nil ? "Updated" : "Last successful update")
        Text(date, style: .relative)
        Text("ago")
      } else {
        Text("Waiting for usage")
      }
      if !store.isDemo {
        // Names only when the window is too narrow for every state.
        ViewThatFits(in: .horizontal) {
          pills(compact: false)
          pills(compact: true)
          Color.clear.frame(width: 0, height: 0)
        }
        .padding(.leading, 6)
      }
      Spacer(minLength: 8)
      Text("v" + appVersion).monospacedDigit().accessibilityLabel("App version")
      QuotaCheckButton()
      Button {
        store.refreshAll()
      } label: {
        Image(systemName: "arrow.clockwise").symbolEffect(.pulse, isActive: store.isLoading)
      }
      .buttonStyle(.plain)
      .disabled(store.isDemo || store.isLoading)
      .help("Refresh usage and limits (⌘R)")
      .accessibilityLabel("Refresh usage")
    }
    .font(.system(size: 11)).foregroundStyle(.secondary)
  }

  private func pills(compact: Bool) -> some View {
    HStack(spacing: 8) {
      ForEach(Harness.allCases) { harness in
        StatusPill(availability: store.snapshot?.availability(harness), label: harness.name, compact: compact)
      }
    }
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
    hideWindows()
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
        let names = NSApp.windows.map { "\($0.identifier?.rawValue ?? "-") '\($0.title)' visible=\($0.isVisible)" }
        FileHandle.standardError.write(Data(("capture: no window\n" + names.joined(separator: "\n") + "\n").utf8))
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

  /// Keeps capture windows invisible and off screen as SwiftUI opens them;
  /// views still draw into the cached bitmap.
  private static func hideWindows() {
    Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in
      MainActor.assumeIsolated {
        for window in NSApp.windows where window.alphaValue != 0 {
          window.alphaValue = 0
          window.ignoresMouseEvents = true
          window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        }
      }
    }
  }

  /// `BURNLESS_CAPTURE_WINDOW`: `settings`, `popover` or the dashboard (default).
  private static var mainWindow: NSWindow? {
    let target = ProcessInfo.processInfo.environment["BURNLESS_CAPTURE_WINDOW"] ?? "dashboard"
    let visible = NSApp.windows.filter { $0.isVisible && $0.contentView != nil && $0.frame.width > 300 }
    switch target {
    case "settings":
      return visible.first {
        let id = $0.identifier?.rawValue ?? ""
        return !id.contains("dashboard") && !id.contains("popover-preview")
      }
    case "popover": return visible.first { $0.identifier?.rawValue.contains("popover-preview") == true }
    default: return visible.first { $0.identifier?.rawValue.contains("dashboard") == true } ?? visible.first
    }
  }
}
