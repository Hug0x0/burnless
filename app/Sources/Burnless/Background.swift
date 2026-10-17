import BurnlessCore
import Foundation
import Observation
import ServiceManagement

/// The optional launch agent that keeps recording limits after Burnless quits.
///
/// launchd runs `Burnless --collect-quotas` every minute
/// (`Contents/Library/LaunchAgents/io.github.hug0x0.burnless.quota.plist`).
/// Each run reads the same settings as the app, takes one quota reading,
/// merges it into the history under its file lock and exits.
enum QuotaCollector {
  static let plistName = "io.github.hug0x0.burnless.quota.plist"
  static var service: SMAppService { .agent(plistName: plistName) }

  /// Exit status for launchd: 0 on success.
  static func collectOnce() -> Int32 {
    let defaults = UserDefaults.standard
    guard let executable = EngineClient.locate() else {
      FileHandle.standardError.write(Data("burnless: engine not found\n".utf8))
      return 1
    }
    let text = { (key: String) in defaults.string(forKey: key).flatMap { $0.isEmpty ? nil : $0 } }
    let configuration = EngineConfiguration(
      executable: executable, claudeDirectory: text("claudeDirectory"), codexHome: text("codexHome"))
    let live = defaults.bool(forKey: "liveQuotas")
    let liveClaude = live && LivePacing.claudeDue(force: false, defaults: defaults)
    do {
      let report = try EngineClient.quotaBlocking(configuration, liveClaude: liveClaude, liveCodex: live)
      if liveClaude { LivePacing.record(report.claude.live, defaults: defaults) }
      try QuotaHistoryFile.standard.commit(report.readings)
      return 0
    } catch {
      FileHandle.standardError.write(Data("burnless: quota collection failed: \(error.localizedDescription)\n".utf8))
      return 1
    }
  }
}

/// Opt-in check of the latest GitHub release.
@Observable @MainActor final class UpdateChecker {
  static let shared = UpdateChecker()
  static let releasesURL = URL(string: "https://api.github.com/repos/Hug0x0/burnless/releases/latest")!

  enum State: Equatable {
    case idle, checking, upToDate, noReleases
    case available(String, URL)
    case failed(String)
  }

  private(set) var state = State.idle
  var isChecking: Bool { state == .checking }

  /// At most once a day, and only when the user enabled it.
  func checkIfDue(settings: AppSettings, defaults: UserDefaults = .standard) {
    guard settings.checkForUpdates else { return }
    let last = defaults.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast
    guard Date.now.timeIntervalSince(last) > 86_400 else { return }
    Task { await check(defaults: defaults) }
  }

  func check(defaults: UserDefaults = .standard) async {
    state = .checking
    defaults.set(Date.now, forKey: "lastUpdateCheck")
    var request = URLRequest(url: Self.releasesURL, timeoutInterval: 15)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("Burnless/\(appVersion)", forHTTPHeaderField: "User-Agent")
    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      if status == 404 {
        state = .noReleases
        return
      }
      guard status == 200 else {
        state = .failed("GitHub answered \(status).")
        return
      }
      struct Release: Decodable {
        let tag_name: String
        let html_url: URL
      }
      let release = try JSONDecoder().decode(Release.self, from: data)
      let latest = release.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
      let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
      state = Self.isNewer(latest, than: current) ? .available(latest, release.html_url) : .upToDate
    } catch {
      state = .failed("Could not check: \(error.localizedDescription)")
    }
  }

  nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
    let parts = { (text: String) in text.split(separator: ".").map { Int($0) ?? 0 } }
    let a = parts(candidate)
    let b = parts(current)
    for index in 0..<max(a.count, b.count) {
      let left = index < a.count ? a[index] : 0
      let right = index < b.count ? b[index] : 0
      if left != right { return left > right }
    }
    return false
  }
}
