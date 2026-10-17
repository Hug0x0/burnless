import Foundation
import Testing

@testable import BurnlessCore

func report(_ rows: [UsageRow], claude: SourceState = .ok, codex: SourceState = .ok)
  -> EngineReport
{
  EngineReport(
    pricing: testPricing,
    sources: [
      SourceStatus(id: .claude, state: claude, error: claude == .error ? "boom" : nil),
      SourceStatus(id: .codex, state: codex, error: codex == .error ? "boom" : nil),
    ],
    rows: rows)
}

func temporaryDirectory() -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(
    "burnless-tests-\(UUID().uuidString)")
  try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

@Suite struct MergeTests {
  let t0 = at("2026-10-15T10:00:00Z")
  let t1 = at("2026-10-17T10:00:00Z")
  let base = [row(.claude, "2026-10-15", "a", cost: 1), row(.codex, "2026-10-15", "b", cost: 2)]

  @Test func repeatedRefreshesNeverDuplicateRows() {
    var current: UsageSnapshot? = nil
    for _ in 0..<5 {
      current = UsageSnapshot.merging(report(base), previous: current, now: t1)
    }
    #expect(current?.rows.count == 2)
    let result = Dashboard.compute(snapshot: current, harness: nil, period: .allTime, now: t1, days: paris)
    #expect(result.totals.cost == 3)
  }

  @Test func failedSourceKeepsLastGoodRowsAsStale() {
    let first = UsageSnapshot.merging(report(base), previous: nil, now: t0)
    let second = UsageSnapshot.merging(
      report([row(.codex, "2026-10-17", "b", cost: 5)], claude: .error), previous: first, now: t1)
    #expect(second.rows.filter { $0.source == .claude } == first.rows.filter { $0.source == .claude })
    #expect(second.rows.filter { $0.source == .codex }.map(\.date) == ["2026-10-17"])
    #expect(second.availability(.claude) == .stale(lastSuccess: t0, reason: "boom"))
    #expect(second.availability(.codex) == .live)
  }

  @Test func staleSourceMarksLaterDaysUnknownInItsView() {
    let first = UsageSnapshot.merging(report(base), previous: nil, now: t0)
    let second = UsageSnapshot.merging(report([], claude: .error), previous: first, now: t1)
    let claude = Dashboard.compute(snapshot: second, harness: .claude, period: .last7, now: t1, days: paris)
    #expect(claude.stale == [.claude])
    let unknown = Dictionary(uniqueKeysWithValues: claude.days.map { ($0.key, $0.isUnknown) })
    #expect(unknown["2026-10-15"] == false)
    #expect(unknown["2026-10-16"] == true)
    #expect(unknown["2026-10-17"] == true)
    // The live source keeps the global chart's days known.
    let all = Dashboard.compute(snapshot: second, harness: nil, period: .last7, now: t1, days: paris)
    #expect(all.days.allSatisfy { !$0.isUnknown })
  }

  @Test func missingSourceWithoutHistoryIsUnavailable() {
    let merged = UsageSnapshot.merging(report(base.filter { $0.source == .claude }, codex: .notFound), previous: nil, now: t1)
    #expect(merged.availability(.codex) == .notFound)
    let codex = Dashboard.compute(snapshot: merged, harness: .codex, period: .last7, now: t1, days: paris)
    #expect(codex.unavailable == [.codex])
    #expect(codex.days.allSatisfy { $0.isUnknown })
    let all = Dashboard.compute(snapshot: merged, harness: nil, period: .allTime, now: t1, days: paris)
    #expect(all.unavailable == [.codex])
    #expect(all.totals.cost == 1)
  }

  @Test func recoveredSourceReplacesStaleRows() {
    let first = UsageSnapshot.merging(report(base), previous: nil, now: t0)
    let failed = UsageSnapshot.merging(report([], claude: .error), previous: first, now: t1)
    let recovered = UsageSnapshot.merging(report(base), previous: failed, now: t1)
    #expect(recovered.rows.count == 2)
    #expect(recovered.availability(.claude) == .live)
  }
}

@Suite struct CacheTests {
  @Test func saveAndLoadRoundTrip() throws {
    let cache = SnapshotCache(directory: temporaryDirectory())
    let snapshot = UsageSnapshot.merging(
      report([row(.claude, "2026-10-15", "a")]), previous: nil, now: at("2026-10-15T10:00:00Z"))
    try cache.save(snapshot)
    #expect(cache.load() == snapshot)
  }

  @Test func writesAreAtomicAndKeepABackup() throws {
    let cache = SnapshotCache(directory: temporaryDirectory())
    let first = UsageSnapshot.merging(report([row(.claude, "2026-10-15", "a")]), previous: nil, now: at("2026-10-15T10:00:00Z"))
    let second = UsageSnapshot.merging(report([row(.claude, "2026-10-16", "a")]), previous: first, now: at("2026-10-16T10:00:00Z"))
    try cache.save(first)
    try cache.save(second)
    #expect(cache.load() == second)
    // A corrupted main file falls back to the previous valid copy.
    try Data("{broken".utf8).write(to: cache.fileURL)
    #expect(cache.load() == first)
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: cache.directory.path)
    #expect(Set(leftovers) == ["usage-cache.json", "usage-cache.json.bak"])
  }

  @Test func corruptedCacheLoadsNothing() throws {
    let cache = SnapshotCache(directory: temporaryDirectory())
    try Data("not json".utf8).write(to: cache.fileURL)
    #expect(cache.load() == nil)
  }

  @Test func demoDataIsNeverCached() throws {
    let cache = SnapshotCache(directory: temporaryDirectory())
    try cache.save(DemoData.snapshot(now: at("2026-10-17T10:00:00Z"), days: paris))
    #expect(!FileManager.default.fileExists(atPath: cache.fileURL.path))
  }
}

@Suite struct DecodingTests {
  let sample = """
    {"schemaVersion":1,"engineVersion":"0.1.0","generatedAtMs":1,"timezone":"Europe/Paris",
     "pricing":{"provider":"p","ccusageRevision":"c","litellmRevision":"l","snapshotDate":"d","online":false},
     "sources":[{"id":"claude","state":"ok","paths":["/x"],"searched":[],"envVar":"CLAUDE_CONFIG_DIR","envOverride":false,"error":null},
                {"id":"codex","state":"notFound","paths":[],"searched":["/y"],"envVar":"CODEX_HOME","envOverride":false,"error":null}],
     "rows":[{"source":"claude","date":"2026-10-17","model":null,"inputTokens":1,"outputTokens":2,"cacheWriteTokens":3,
              "cacheReadTokens":4,"reasoningTokens":0,"totalTokens":10,"costUSD":0.5,"missingPricing":true,"inferredModel":false}]}
    """

  @Test func decodesEngineReport() throws {
    let decoded = try EngineReport.decode(Data(sample.utf8))
    #expect(decoded.rows.first?.model == nil)
    #expect(decoded.rows.first?.totalTokens == 10)
    #expect(decoded.sources.map(\.state) == [.ok, .notFound])
  }

  @Test func rejectsInvalidJSON() {
    #expect(throws: EngineError.invalidOutput) { try EngineReport.decode(Data("{oops".utf8)) }
    #expect(throws: EngineError.invalidOutput) { try EngineReport.decode(Data()) }
  }

  @Test func rejectsOtherSchemaVersions() {
    let future = sample.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2")
    #expect(throws: EngineError.unsupportedSchema(2)) { try EngineReport.decode(Data(future.utf8)) }
  }

  @Test func rejectsUnknownSource() {
    let other = sample.replacingOccurrences(of: "\"source\":\"claude\"", with: "\"source\":\"cursor\"")
    #expect(throws: EngineError.invalidOutput) { try EngineReport.decode(Data(other.utf8)) }
  }
}

@Suite struct EngineClientTests {
  func script(_ body: String) throws -> URL {
    let url = temporaryDirectory().appendingPathComponent("fake-engine")
    try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
  }

  @Test func passesTimezoneAndFolderOverrides() async throws {
    let directory = temporaryDirectory()
    let log = directory.appendingPathComponent("args.txt")
    let engine = try script(
      "echo \"$@|$CLAUDE_CONFIG_DIR|$CODEX_HOME\" > '\(log.path)'\n"
        + "echo '{\"schemaVersion\":1,\"engineVersion\":\"x\",\"generatedAtMs\":0,\"timezone\":null,\"pricing\":{\"provider\":\"p\",\"ccusageRevision\":\"c\",\"litellmRevision\":\"l\",\"snapshotDate\":\"d\",\"online\":false},\"sources\":[],\"rows\":[]}'"
    )
    let configuration = EngineConfiguration(
      executable: engine, claudeDirectory: "/tmp/c", codexHome: "/tmp/x",
      timeZone: TimeZone(identifier: "Asia/Tokyo")!)
    let decoded = try await EngineClient.run(configuration)
    #expect(decoded.rows.isEmpty)
    let recorded = try String(contentsOf: log, encoding: .utf8)
    #expect(recorded.trimmingCharacters(in: .newlines) == "report --timezone Asia/Tokyo|/tmp/c|/tmp/x")
  }

  @Test func reportsNonZeroExit() async throws {
    let engine = try script("exit 3")
    await #expect(throws: EngineError.failed(3)) {
      try await EngineClient.run(EngineConfiguration(executable: engine))
    }
  }

  @Test func reportsInvalidOutput() async throws {
    let engine = try script("echo 'not json'")
    await #expect(throws: EngineError.invalidOutput) {
      try await EngineClient.run(EngineConfiguration(executable: engine))
    }
  }

  @Test func stopsHungEngine() async throws {
    let engine = try script("sleep 30")
    await #expect(throws: EngineError.timedOut) {
      try await EngineClient.run(EngineConfiguration(executable: engine, timeout: 0.5))
    }
  }

  @Test func missingEngine() async {
    await #expect(throws: EngineError.missing) {
      try await EngineClient.run(EngineConfiguration(executable: URL(fileURLWithPath: "/nonexistent/engine")))
    }
  }
}
