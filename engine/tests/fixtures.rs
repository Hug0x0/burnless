//! End-to-end checks of burnless-engine against synthetic history folders.
//!
//! Each test builds a throwaway HOME with fake Claude Code / Codex / Gemini CLI logs, runs
//! the real binary, and checks the JSON report. No real history is touched.

use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
};

use serde_json::{Value, json};
use tempfile::TempDir;

struct Fixture {
    dir: TempDir,
}

impl Fixture {
    fn new() -> Self {
        Self {
            dir: tempfile::tempdir().unwrap(),
        }
    }

    fn path(&self, relative: &str) -> PathBuf {
        self.dir.path().join(relative)
    }

    fn write(&self, relative: &str, lines: &[String]) {
        let path = self.path(relative);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, lines.join("\n") + "\n").unwrap();
    }

    fn mkdir(&self, relative: &str) {
        fs::create_dir_all(self.path(relative)).unwrap();
    }

    /// Runs the engine with HOME pointed at the fixture, so default paths
    /// (`~/.claude`, `~/.codex`) resolve inside it.
    fn run(&self, timezone: &str) -> Value {
        self.run_with(timezone, &[])
    }

    fn run_with(&self, timezone: &str, env: &[(&str, &Path)]) -> Value {
        self.engine(&["report", "--timezone", timezone], env)
    }

    fn quota(&self) -> Value {
        self.engine(&["quota"], &[])
    }

    fn engine(&self, args: &[&str], env: &[(&str, &Path)]) -> Value {
        let mut command = Command::new(env!("CARGO_BIN_EXE_burnless-engine"));
        command
            .args(args)
            .env_clear()
            .env("HOME", self.dir.path())
            .env("PATH", "/usr/bin:/bin");
        for (key, value) in env {
            command.env(key, value);
        }
        let output = command.output().unwrap();
        assert!(output.status.success(), "engine failed: {output:?}");
        serde_json::from_slice(&output.stdout).unwrap()
    }
}

fn claude_line(id: &str, request: &str, timestamp: &str, model: &str, input: u64, output: u64) -> String {
    json!({
        "type": "assistant",
        "timestamp": timestamp,
        "sessionId": "session-1",
        "requestId": request,
        "message": {
            "id": id,
            "model": model,
            "usage": {
                "input_tokens": input,
                "output_tokens": output,
                "cache_creation_input_tokens": 0,
                "cache_read_input_tokens": 0
            }
        }
    })
    .to_string()
}

fn codex_total(timestamp: &str, model: &str, input: u64, cached: u64, output: u64) -> String {
    json!({
        "timestamp": timestamp,
        "type": "event_msg",
        "payload": {
            "type": "token_count",
            "info": {
                "model": model,
                "total_token_usage": {
                    "input_tokens": input,
                    "cached_input_tokens": cached,
                    "output_tokens": output,
                    "total_tokens": input + output
                }
            }
        }
    })
    .to_string()
}

fn rows<'a>(report: &'a Value, source: &str) -> Vec<&'a Value> {
    report["rows"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|row| row["source"] == source)
        .collect()
}

fn source<'a>(report: &'a Value, id: &str) -> &'a Value {
    report["sources"]
        .as_array()
        .unwrap()
        .iter()
        .find(|source| source["id"] == id)
        .unwrap()
}

fn sum(rows: &[&Value], field: &str) -> u64 {
    rows.iter().map(|row| row[field].as_u64().unwrap()).sum()
}

fn gemini_message(id: &str, timestamp: &str, model: &str, input: u64, cached: u64, output: u64, thoughts: u64) -> Value {
    json!({
        "id": id,
        "timestamp": timestamp,
        "type": "gemini",
        "content": "not read",
        "model": model,
        "tokens": {
            "input": input,
            "output": output,
            "cached": cached,
            "thoughts": thoughts,
            "tool": 0,
            "total": input + output + thoughts
        }
    })
}

#[test]
fn report_has_versioned_schema_and_pricing_provenance() {
    let fixture = Fixture::new();
    let report = fixture.run("UTC");
    assert_eq!(report["schemaVersion"], 1);
    assert_eq!(report["pricing"]["online"], false);
    // Offline runs must never touch the network.
    assert_eq!(report["pricing"]["onlineFetched"], false);
    assert!(report["pricing"]["litellmRevision"].as_str().unwrap().len() == 40);
}

#[test]
fn missing_sources_are_reported_as_not_found() {
    let fixture = Fixture::new();
    let report = fixture.run("UTC");
    assert_eq!(source(&report, "claude")["state"], "notFound");
    assert_eq!(source(&report, "codex")["state"], "notFound");
    assert_eq!(source(&report, "gemini")["state"], "notFound");
    assert_eq!(report["rows"].as_array().unwrap().len(), 0);
}

#[test]
fn one_missing_source_does_not_block_the_other() {
    let fixture = Fixture::new();
    fixture.write(
        ".claude/projects/demo/session-1.jsonl",
        &[claude_line("msg_1", "req_1", "2026-03-10T10:00:00.000Z", "claude-sonnet-4-5", 100, 50)],
    );
    let report = fixture.run("UTC");
    assert_eq!(source(&report, "claude")["state"], "ok");
    assert_eq!(source(&report, "codex")["state"], "notFound");
    assert_eq!(rows(&report, "claude").len(), 1);
}

#[test]
fn claude_duplicate_messages_are_counted_once() {
    let fixture = Fixture::new();
    let line = claude_line("msg_1", "req_1", "2026-03-10T10:00:00.000Z", "claude-sonnet-4-5", 100, 50);
    // The same message logged twice in one file and again in a resumed session.
    fixture.write(".claude/projects/demo/session-1.jsonl", &[line.clone(), line.clone()]);
    fixture.write(".claude/projects/demo/session-2.jsonl", &[line]);
    let report = fixture.run("UTC");
    let claude = rows(&report, "claude");
    assert_eq!(sum(&claude, "inputTokens"), 100);
    assert_eq!(sum(&claude, "outputTokens"), 50);
    assert_eq!(sum(&claude, "totalTokens"), 150);
    assert!(claude[0]["costUSD"].as_f64().unwrap() > 0.0);
    assert_eq!(claude[0]["missingPricing"], false);
}

#[test]
fn malformed_lines_are_skipped_without_failing_the_source() {
    let fixture = Fixture::new();
    fixture.write(
        ".claude/projects/demo/session-1.jsonl",
        &[
            "{not json".into(),
            json!({"type": "assistant", "message": "unexpected shape"}).to_string(),
            claude_line("msg_1", "req_1", "2026-03-10T10:00:00.000Z", "claude-sonnet-4-5", 100, 50),
            "".into(),
        ],
    );
    fixture.write(
        ".codex/sessions/2026/03/10/rollout-a.jsonl",
        &[
            "\u{0}garbage".into(),
            codex_total("2026-03-10T10:00:00.000Z", "gpt-5.5", 1000, 0, 100),
        ],
    );
    let report = fixture.run("UTC");
    assert_eq!(source(&report, "claude")["state"], "ok");
    assert_eq!(source(&report, "codex")["state"], "ok");
    assert_eq!(sum(&rows(&report, "claude"), "totalTokens"), 150);
    assert_eq!(sum(&rows(&report, "codex"), "totalTokens"), 1100);
}

#[test]
fn codex_cumulative_counters_become_deltas() {
    let fixture = Fixture::new();
    fixture.write(
        ".codex/sessions/2026/03/10/rollout-a.jsonl",
        &[
            codex_total("2026-03-10T10:00:00.000Z", "gpt-5.5", 1000, 400, 100),
            // Same cumulative total repeated: no new usage.
            codex_total("2026-03-10T10:00:05.000Z", "gpt-5.5", 1000, 400, 100),
            codex_total("2026-03-10T10:01:00.000Z", "gpt-5.5", 2500, 1400, 300),
        ],
    );
    let report = fixture.run("UTC");
    let codex = rows(&report, "codex");
    assert_eq!(codex.len(), 1);
    let row = codex[0];
    // Cumulative input 2500 of which 1400 cached: 1100 uncached input.
    assert_eq!(row["inputTokens"], 1100);
    assert_eq!(row["cacheReadTokens"], 1400);
    assert_eq!(row["outputTokens"], 300);
    assert_eq!(row["totalTokens"], 2800);
}

#[test]
fn codex_archived_copy_of_active_session_is_not_double_counted() {
    let fixture = Fixture::new();
    let lines = [codex_total("2026-03-10T10:00:00.000Z", "gpt-5.5", 1000, 0, 100)];
    fixture.write(".codex/sessions/2026/03/10/rollout-a.jsonl", &lines);
    fixture.write(".codex/archived_sessions/2026/03/10/rollout-a.jsonl", &lines);
    let report = fixture.run("UTC");
    assert_eq!(sum(&rows(&report, "codex"), "totalTokens"), 1100);
}

#[test]
fn repeated_runs_are_identical_apart_from_timestamp() {
    let fixture = Fixture::new();
    fixture.write(
        ".claude/projects/demo/session-1.jsonl",
        &[claude_line("msg_1", "req_1", "2026-03-10T10:00:00.000Z", "claude-sonnet-4-5", 100, 50)],
    );
    fixture.write(
        ".codex/sessions/2026/03/10/rollout-a.jsonl",
        &[codex_total("2026-03-10T10:00:00.000Z", "gpt-5.5", 1000, 0, 100)],
    );
    let first = fixture.run("UTC");
    let second = fixture.run("UTC");
    assert_eq!(first["rows"], second["rows"]);
    assert_eq!(first["sources"], second["sources"]);
}

#[test]
fn an_unknown_timezone_is_refused() {
    let output = Command::new(env!("CARGO_BIN_EXE_burnless-engine"))
        .args(["report", "--timezone", "Bogus/Zone"])
        .env_clear()
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&output.stderr).contains("unknown timezone"));
}

#[test]
fn dates_follow_the_requested_timezone() {
    let fixture = Fixture::new();
    // 23:30 UTC on March 10 is already March 11 in Paris (UTC+1 in winter)
    // and still March 10 in New York.
    fixture.write(
        ".claude/projects/demo/session-1.jsonl",
        &[claude_line("msg_1", "req_1", "2026-03-10T23:30:00.000Z", "claude-sonnet-4-5", 100, 50)],
    );
    assert_eq!(rows(&fixture.run("Europe/Paris"), "claude")[0]["date"], "2026-03-11");
    assert_eq!(rows(&fixture.run("America/New_York"), "claude")[0]["date"], "2026-03-10");
    assert_eq!(rows(&fixture.run("UTC"), "claude")[0]["date"], "2026-03-10");
}

#[test]
fn daylight_saving_transition_days_are_grouped_locally() {
    let fixture = Fixture::new();
    // Paris switches to summer time at 01:00 UTC on 2026-03-29.
    fixture.write(
        ".claude/projects/demo/session-1.jsonl",
        &[
            claude_line("msg_1", "req_1", "2026-03-28T22:59:00.000Z", "claude-sonnet-4-5", 1, 1),
            claude_line("msg_2", "req_2", "2026-03-28T23:01:00.000Z", "claude-sonnet-4-5", 2, 2),
            claude_line("msg_3", "req_3", "2026-03-29T21:59:00.000Z", "claude-sonnet-4-5", 4, 4),
            claude_line("msg_4", "req_4", "2026-03-29T22:01:00.000Z", "claude-sonnet-4-5", 8, 8),
        ],
    );
    let report = fixture.run("Europe/Paris");
    let claude = rows(&report, "claude");
    let by_date: Vec<(String, u64)> = claude
        .iter()
        .map(|row| (row["date"].as_str().unwrap().to_string(), row["inputTokens"].as_u64().unwrap()))
        .collect();
    assert_eq!(
        by_date,
        vec![
            ("2026-03-28".into(), 1),
            ("2026-03-29".into(), 6),
            ("2026-03-30".into(), 8),
        ]
    );
}

#[test]
fn unknown_model_price_is_flagged() {
    let fixture = Fixture::new();
    fixture.write(
        ".claude/projects/demo/session-1.jsonl",
        &[claude_line("msg_1", "req_1", "2026-03-10T10:00:00.000Z", "acme-unpriced-model-zz9", 100, 50)],
    );
    let report = fixture.run("UTC");
    let claude = rows(&report, "claude");
    assert_eq!(claude.len(), 1);
    assert_eq!(claude[0]["missingPricing"], true);
}

#[test]
fn environment_overrides_select_custom_folders() {
    let fixture = Fixture::new();
    fixture.write(
        "elsewhere/claude/projects/demo/session-1.jsonl",
        &[claude_line("msg_1", "req_1", "2026-03-10T10:00:00.000Z", "claude-sonnet-4-5", 100, 50)],
    );
    fixture.mkdir("elsewhere/codex/sessions");
    let claude_dir = fixture.path("elsewhere/claude");
    let codex_dir = fixture.path("elsewhere/codex");
    let report = fixture.run_with(
        "UTC",
        &[("CLAUDE_CONFIG_DIR", &claude_dir), ("CODEX_HOME", &codex_dir)],
    );
    assert_eq!(source(&report, "claude")["state"], "ok");
    assert_eq!(source(&report, "claude")["envOverride"], true);
    assert_eq!(source(&report, "codex")["state"], "ok");
    assert_eq!(rows(&report, "claude").len(), 1);
}

#[test]
fn engine_never_modifies_history_files() {
    let fixture = Fixture::new();
    let relative = ".claude/projects/demo/session-1.jsonl";
    fixture.write(
        relative,
        &[claude_line("msg_1", "req_1", "2026-03-10T10:00:00.000Z", "claude-sonnet-4-5", 100, 50)],
    );
    let before = fs::read(fixture.path(relative)).unwrap();
    let modified = fs::metadata(fixture.path(relative)).unwrap().modified().unwrap();
    fixture.run("UTC");
    assert_eq!(fs::read(fixture.path(relative)).unwrap(), before);
    assert_eq!(fs::metadata(fixture.path(relative)).unwrap().modified().unwrap(), modified);
    let entries: Vec<_> = fs::read_dir(fixture.path(".claude/projects/demo")).unwrap().collect();
    assert_eq!(entries.len(), 1);
}

#[test]
fn rows_carry_no_prompt_content() {
    let fixture = Fixture::new();
    let mut line: Value = serde_json::from_str(&claude_line(
        "msg_1",
        "req_1",
        "2026-03-10T10:00:00.000Z",
        "claude-sonnet-4-5",
        100,
        50,
    ))
    .unwrap();
    line["message"]["content"] = json!([{"type": "text", "text": "SECRET-PROMPT-TEXT"}]);
    fixture.write(".claude/projects/demo/session-1.jsonl", &[line.to_string()]);
    let output = Command::new(env!("CARGO_BIN_EXE_burnless-engine"))
        .args(["report", "--timezone", "UTC"])
        .env_clear()
        .env("HOME", fixture.dir.path())
        .output()
        .unwrap();
    assert!(!String::from_utf8_lossy(&output.stdout).contains("SECRET-PROMPT-TEXT"));
}

fn codex_rate_limits(timestamp: &str, used: f64, plan: &str) -> String {
    json!({
        "timestamp": timestamp,
        "type": "event_msg",
        "payload": {
            "type": "token_count",
            "info": null,
            "rate_limits": {
                "limit_id": "codex",
                "primary": {"used_percent": used, "window_minutes": 10080, "resets_at": 1_792_683_187},
                "secondary": null,
                "plan_type": plan
            }
        }
    })
    .to_string()
}

#[test]
fn quota_reads_local_plans_and_meters_without_credentials() {
    let fixture = Fixture::new();
    fs::write(
        fixture.path(".claude.json"),
        json!({
            "oauthAccount": {"accountUuid": "acct", "organizationRateLimitTier": "default_claude_max_5x"},
            "cachedUsageUtilization": {
                "accountUuid": "acct",
                "fetchedAtMs": 1_792_245_336_888_i64,
                "utilization": {
                    "five_hour": {"utilization": 3, "resets_at": "2026-10-17T17:29:59.714946+00:00"},
                    "seven_day": {"utilization": 10, "resets_at": "2026-10-19T21:59:59.714969+00:00"}
                }
            }
        })
        .to_string(),
    )
    .unwrap();
    fixture.write(
        ".codex/sessions/2026/10/16/rollout-2026-10-16T09-00-00-a.jsonl",
        &[codex_rate_limits("2026-10-16T09:00:00.000Z", 30.0, "plus")],
    );
    // The newest session wins, including over a side limit logged after it.
    fixture.write(
        ".codex/sessions/2026/10/17/rollout-2026-10-17T09-00-00-b.jsonl",
        &[
            codex_rate_limits("2026-10-17T09:00:00.000Z", 42.5, "plus"),
            json!({"payload": {"rate_limits": {"limit_id": "codex_bengalfox",
                "primary": {"used_percent": 100.0, "window_minutes": 10080, "resets_at": 1}}}})
            .to_string(),
        ],
    );

    let quota = fixture.quota();
    assert_eq!(quota["schemaVersion"], 1);
    assert_eq!(quota["claude"]["planTier"], "default_claude_max_5x");
    assert_eq!(quota["claude"]["account"]["source"], "claudeCode");
    assert_eq!(quota["claude"]["account"]["session"]["usedPercent"], 3.0);
    assert_eq!(quota["claude"]["account"]["weekly"]["windowMinutes"], 10080);
    assert!(quota["claude"]["account"]["weekly"]["resetsAtMs"].is_i64());
    assert_eq!(quota["claude"]["live"]["state"], "off");
    assert_eq!(quota["codex"]["planType"], "plus");
    assert_eq!(quota["codex"]["snapshot"]["source"], "logs");
    assert_eq!(quota["codex"]["snapshot"]["weekly"]["usedPercent"], 42.5);
    assert_eq!(quota["codex"]["snapshot"]["weekly"]["resetsAtMs"], 1_792_683_187_000_i64);
    assert_eq!(quota["codex"]["live"]["state"], "off");
}

#[test]
fn quota_takes_the_latest_codex_meter_from_any_open_session() {
    let fixture = Fixture::new();
    fixture.write(
        ".codex/sessions/2026/10/17/rollout-2026-10-17T09-00-00-new.jsonl",
        &[codex_rate_limits("2026-10-17T09:00:00.000Z", 10.0, "plus")],
    );
    // A session started earlier but still in use logged a later meter,
    // followed by a line longer than the first tail read.
    fixture.write(
        ".codex/sessions/2026/10/03/rollout-2026-10-03T18-00-00-old.jsonl",
        &[
            codex_rate_limits("2026-10-17T10:00:00.000Z", 12.0, "plus"),
            json!({"timestamp": "2026-10-17T10:00:01.000Z", "type": "response_item",
                "payload": {"output": "x".repeat(200_000)}})
            .to_string(),
        ],
    );
    let quota = fixture.quota();
    assert_eq!(quota["codex"]["snapshot"]["weekly"]["usedPercent"], 12.0);
}

#[test]
fn quota_without_any_source_is_empty_not_an_error() {
    let fixture = Fixture::new();
    let quota = fixture.quota();
    assert!(quota["claude"]["account"].is_null());
    assert!(quota["claude"]["planTier"].is_null());
    assert!(quota["codex"]["snapshot"].is_null());
    assert_eq!(quota["codex"]["limitUsageDaily"], json!([]));
}

#[test]
fn quota_never_modifies_account_or_session_files() {
    let fixture = Fixture::new();
    let account = json!({"oauthAccount": {"userRateLimitTier": "default_claude_pro"}}).to_string();
    fs::write(fixture.path(".claude.json"), &account).unwrap();
    let session = ".codex/sessions/2026/10/17/rollout-2026-10-17T09-00-00-b.jsonl";
    fixture.write(session, &[codex_rate_limits("2026-10-17T09:00:00.000Z", 1.0, "pro")]);
    let before = fs::read(fixture.path(session)).unwrap();
    let quota = fixture.quota();
    assert_eq!(quota["claude"]["planTier"], "default_claude_pro");
    assert_eq!(fs::read_to_string(fixture.path(".claude.json")).unwrap(), account);
    assert_eq!(fs::read(fixture.path(session)).unwrap(), before);
}

#[test]
fn codex_image_generations_are_counted_once_per_image() {
    let fixture = Fixture::new();
    let today = Command::new("date").arg("-u").arg("+%Y-%m-%d").output().unwrap();
    let today = String::from_utf8(today.stdout).unwrap().trim().to_string();
    let image = |id: &str| {
        json!({"timestamp": format!("{today}T10:00:00.000Z"), "type": "response_item",
            "payload": {"type": "image_generation_call", "id": id, "result": "AAAA"}})
        .to_string()
    };
    fixture.write(
        &format!(".codex/sessions/x/rollout-{today}T10-00-00-img.jsonl"),
        &[
            codex_total(&format!("{today}T10:00:00.000Z"), "gpt-5", 100, 0, 10),
            image("ig_one"),
            image("ig_one"),
            image("ig_two"),
        ],
    );
    let report = fixture.run("UTC");
    assert_eq!(report["codexImages"], json!([{"date": today, "count": 2}]));
}

#[test]
fn compressed_sessions_and_long_running_ones_are_read() {
    let fixture = Fixture::new();
    let today = Command::new("date").arg("-u").arg("+%Y-%m-%d").output().unwrap();
    let today = String::from_utf8(today.stdout).unwrap().trim().to_string();
    // A session started months ago that generated an image today.
    fixture.write(
        ".codex/sessions/2026/05/05/rollout-2026-05-05T18-30-40-old.jsonl",
        &[json!({"timestamp": format!("{today}T08:00:00.000Z"), "type": "response_item",
            "payload": {"type": "image_generation_call", "id": "ig_late", "result": "AAAA"}})
        .to_string()],
    );
    // A compressed session holding the latest meter.
    let path = fixture.path(".codex/sessions/2026/10/17/rollout-2026-10-17T09-00-00-z.jsonl.zst");
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    let line = codex_rate_limits("2026-10-17T09:00:00.000Z", 33.0, "plus") + "\n";
    fs::write(&path, zstd::encode_all(line.as_bytes(), 3).unwrap()).unwrap();

    assert_eq!(fixture.quota()["codex"]["snapshot"]["weekly"]["usedPercent"], 33.0);
    let report = fixture.run("UTC");
    assert_eq!(report["codexImages"], json!([{"date": today, "count": 1}]));
}

#[test]
fn row_cost_breakdown_adds_up_to_the_row_cost() {
    let fixture = Fixture::new();
    fixture.write(
        ".claude/projects/p/s.jsonl",
        &[claude_line("m1", "r1", "2026-03-01T10:00:00.000Z", "claude-sonnet-4-5", 1000, 500)],
    );
    let report = fixture.run("UTC");
    let rows = rows(&report, "claude");
    let row = rows[0];
    let cost = row["costUSD"].as_f64().unwrap();
    assert!(cost > 0.0);
    let parts: f64 = ["input", "output", "cacheWrite", "cacheRead"]
        .iter()
        .map(|key| row["costBreakdown"][key].as_f64().unwrap())
        .sum();
    assert!((parts - cost).abs() < 1e-9);
    // Output tokens cost more per token than input tokens.
    assert!(row["costBreakdown"]["output"].as_f64().unwrap() > row["costBreakdown"]["input"].as_f64().unwrap());
}

#[test]
fn gemini_chat_sessions_are_read_with_thinking_as_output() {
    let fixture = Fixture::new();
    let session = json!({
        "sessionId": "gemini-session-1",
        "projectHash": "abc",
        "startTime": "2026-10-20T09:00:00.000Z",
        "messages": [
            {"id": "u1", "timestamp": "2026-10-20T09:00:00.000Z", "type": "user", "content": "hi"},
            gemini_message("g1", "2026-10-20T09:00:05.000Z", "gemini-2.5-pro", 1000, 400, 100, 50),
            gemini_message("g2", "2026-10-20T09:01:00.000Z", "gemini-2.5-flash", 500, 0, 20, 0),
        ]
    });
    fixture.write(".gemini/tmp/abc/chats/session-2026-10-20T09-00-a.json", &[session.to_string()]);
    let report = fixture.run("UTC");
    assert_eq!(source(&report, "gemini")["state"], "ok");
    let gemini = rows(&report, "gemini");
    assert_eq!(gemini.len(), 2);
    let pro = gemini.iter().find(|row| row["model"] == "gemini-2.5-pro").unwrap();
    // Input includes cache in Gemini's counters; the cached part is split out.
    assert_eq!(pro["inputTokens"], 600);
    assert_eq!(pro["cacheReadTokens"], 400);
    assert_eq!(pro["outputTokens"], 150);
    assert_eq!(pro["reasoningTokens"], 50);
    assert_eq!(pro["totalTokens"], 1150);
    assert!(pro["costUSD"].as_f64().unwrap() > 0.0);
    assert_eq!(pro["missingPricing"], false);
    assert_eq!(sum(&gemini, "totalTokens"), 1150 + 520);
}

#[test]
fn gemini_data_dir_override_is_honoured() {
    let fixture = Fixture::new();
    let session = json!({
        "sessionId": "s",
        "messages": [gemini_message("g1", "2026-10-20T09:00:05.000Z", "gemini-2.5-flash", 100, 0, 10, 0)]
    });
    fixture.write("elsewhere/gemini/abc/chats/session-a.json", &[session.to_string()]);
    let dir = fixture.path("elsewhere/gemini");
    let report = fixture.run_with("UTC", &[("GEMINI_DATA_DIR", &dir)]);
    assert_eq!(source(&report, "gemini")["state"], "ok");
    assert_eq!(source(&report, "gemini")["envOverride"], true);
    assert_eq!(sum(&rows(&report, "gemini"), "totalTokens"), 110);
}
