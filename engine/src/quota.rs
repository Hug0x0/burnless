//! Subscription plans and rate limits for `burnless-engine quota`.
//!
//! Local sources are read by default and need no credentials:
//!
//! - Claude Code caches the account meters it last received from Anthropic in
//!   `~/.claude.json` (`cachedUsageUtilization`), next to the account's
//!   rate-limit tier, which names the plan.
//! - Codex logs the account `rate_limits` it enforced with every request in
//!   its session files, including the plan type.
//!
//! `--live` additionally asks the providers' usage endpoints, the same ones the
//! official apps call. It reads the existing sign-in strictly read-only (Codex
//! `auth.json`, Claude Code's Keychain item or `.credentials.json`): a token is
//! never renewed, written, logged or printed. An expired Claude token is
//! reported, and Claude Code renews it the next time it runs.
//!
//! Output only carries plan names, percentages, reset times and credit
//! amounts. Nothing is written anywhere.

use std::{
    env, fs,
    io::{Read, Seek, SeekFrom},
    path::{Path, PathBuf},
    thread,
};

use ccusage_core::{parse_ts_timestamp, utc_now};
use serde::Serialize;
use serde_json::Value;

use crate::sources;

pub const SCHEMA_VERSION: u32 = 1;

const CLAUDE_USAGE_URL: &str = "https://api.anthropic.com/api/oauth/usage";
const CODEX_USAGE_URL: &str = "https://chatgpt.com/backend-api/wham/usage";
const CODEX_DAILY_URL: &str =
    "https://chatgpt.com/backend-api/wham/usage/daily-token-usage-breakdown";
const FETCH_TIMEOUT_SECONDS: u64 = 8;
const USER_AGENT: &str = concat!("burnless/", env!("CARGO_PKG_VERSION"));
#[cfg(target_os = "macos")]
const CLAUDE_KEYCHAIN_SERVICE: &str = "Claude Code-credentials";
/// Codex session files inspected for the newest account meter, newest first.
const CODEX_FILES_SCANNED: usize = 24;
const CODEX_TAIL_BYTES: u64 = 64 * 1024;
const CODEX_TAIL_MAX_BYTES: u64 = 16 * 1024 * 1024;
/// A logged meter this recent can correct a live over-count.
const CODEX_LOG_TRUST_MS: i64 = 10 * 60_000;
/// Concurrent live reads; the lowest one for the same window wins.
const CODEX_LIVE_READS: usize = 3;
const WEEKLY_MINUTES: u64 = 7 * 24 * 60;
const SESSION_MINUTES: u64 = 5 * 60;

#[derive(Debug, Clone, Copy, Default)]
pub struct QuotaOptions {
    pub live_claude: bool,
    pub live_codex: bool,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct QuotaReport {
    pub schema_version: u32,
    pub engine_version: &'static str,
    pub generated_at_ms: i64,
    pub claude: ClaudeQuota,
    pub codex: CodexQuota,
}

/// A limit window: share used, its length and when it resets.
#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Window {
    pub used_percent: f64,
    pub window_minutes: u64,
    pub resets_at_ms: Option<i64>,
}

/// How a live request went. `off` when it was not requested.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum LiveState {
    Off,
    Ok,
    /// No stored sign-in was found.
    NoSignIn,
    /// The stored token has expired; the provider app renews it on next use.
    SignInExpired,
    /// The provider refused the token.
    Unauthorized,
    RateLimited,
    Failed,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LiveStatus {
    pub state: LiveState,
    pub retry_after_seconds: Option<i64>,
}

impl LiveStatus {
    fn off() -> Self {
        Self {
            state: LiveState::Off,
            retry_after_seconds: None,
        }
    }

    fn of(state: LiveState) -> Self {
        Self {
            state,
            retry_after_seconds: None,
        }
    }
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ClaudeQuota {
    /// Account rate-limit tier, e.g. `default_claude_max_20x`.
    pub plan_tier: Option<String>,
    pub account: Option<ClaudeAccount>,
    pub live: LiveStatus,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ClaudeAccount {
    /// `claudeCode` (Claude Code's own cache) or `live`.
    pub source: &'static str,
    pub observed_at_ms: i64,
    pub session: Option<Window>,
    pub weekly: Option<Window>,
    /// Model-scoped weekly limits (e.g. Opus, Sonnet).
    pub scoped: Vec<ScopedWindow>,
    pub extra: Option<ExtraUsage>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ScopedWindow {
    pub name: String,
    pub used_percent: f64,
    pub resets_at_ms: Option<i64>,
}

/// Pay-as-you-go credits beyond the plan limits.
#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ExtraUsage {
    pub enabled: bool,
    #[serde(rename = "usedUSD")]
    pub used_usd: Option<f64>,
    #[serde(rename = "limitUSD")]
    pub limit_usd: Option<f64>,
    pub used_percent: Option<f64>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CodexQuota {
    /// ChatGPT plan type, e.g. `plus` or `pro`.
    pub plan_type: Option<String>,
    pub snapshot: Option<CodexSnapshot>,
    /// Share of the weekly limit used per day (live only).
    pub limit_usage_daily: Vec<LimitUsageDay>,
    pub live: LiveStatus,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CodexSnapshot {
    /// `logs` (session files) or `live`.
    pub source: &'static str,
    pub observed_at_ms: Option<i64>,
    pub weekly: Option<Window>,
    /// Shorter rolling window when Codex still reports one (typically 5 hours).
    pub short: Option<Window>,
    pub reset_credits_available: Option<u32>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LimitUsageDay {
    pub date: String,
    pub used_percent: f64,
    pub surfaces: Vec<LimitUsageSurface>,
    pub models: Vec<LimitUsageModel>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LimitUsageSurface {
    pub surface: String,
    pub used_percent: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LimitUsageModel {
    pub model: String,
    pub speed: Option<String>,
    pub used_percent: f64,
}

pub fn run(options: QuotaOptions) -> QuotaReport {
    let claude = thread::spawn(move || claude_quota(options.live_claude));
    let codex = codex_quota(options.live_codex);
    let claude = claude.join().unwrap_or_else(|_| ClaudeQuota {
        plan_tier: None,
        account: None,
        live: LiveStatus::of(LiveState::Failed),
    });
    QuotaReport {
        schema_version: SCHEMA_VERSION,
        engine_version: env!("CARGO_PKG_VERSION"),
        generated_at_ms: utc_now().as_millis(),
        claude,
        codex,
    }
}

// MARK: - Claude

fn home() -> Option<PathBuf> {
    env::var_os("HOME").map(PathBuf::from)
}

/// Folders named by `CLAUDE_CONFIG_DIR`, `~/` expanded as for usage logs.
fn claude_config_dirs() -> Vec<PathBuf> {
    let Ok(dirs) = env::var("CLAUDE_CONFIG_DIR") else {
        return Vec::new();
    };
    dirs.split(',')
        .map(str::trim)
        .filter(|dir| !dir.is_empty())
        .map(|raw| {
            let dir = sources::expand_home(raw);
            if dir.file_name().is_some_and(|name| name == "projects") {
                dir.parent().map(Path::to_path_buf).unwrap_or(dir)
            } else {
                dir
            }
        })
        .collect()
}

/// `.claude.json` sits in the config folder when `CLAUDE_CONFIG_DIR` is set,
/// otherwise in the home folder.
fn claude_account_files() -> Vec<PathBuf> {
    let mut files: Vec<PathBuf> =
        claude_config_dirs().iter().map(|dir| dir.join(".claude.json")).collect();
    if let Some(home) = home() {
        files.push(home.join(".claude.json"));
    }
    files
}

fn claude_quota(live: bool) -> ClaudeQuota {
    let account_file = claude_account_files()
        .iter()
        .find_map(|path| fs::read_to_string(path).ok())
        .and_then(|text| serde_json::from_str::<Value>(&text).ok());
    let plan_tier = account_file.as_ref().and_then(plan_tier);
    let cached = account_file.as_ref().and_then(cached_claude_account);
    if !live {
        return ClaudeQuota {
            plan_tier,
            account: cached,
            live: LiveStatus::off(),
        };
    }
    let (fetched, status) = live_claude_account();
    // The newest reading wins: Claude Code may have fetched more recently.
    let account = match (cached, fetched) {
        (Some(cached), Some(fetched)) if cached.observed_at_ms > fetched.observed_at_ms => {
            Some(cached)
        }
        (cached, fetched) => fetched.or(cached),
    };
    ClaudeQuota {
        plan_tier,
        account,
        live: status,
    }
}

fn plan_tier(file: &Value) -> Option<String> {
    let account = file.get("oauthAccount")?;
    [
        "userRateLimitTier",
        "organizationRateLimitTier",
        "organizationType",
    ]
    .into_iter()
    .find_map(|key| {
        account
            .get(key)
            .and_then(Value::as_str)
            .filter(|tier| !tier.is_empty())
    })
    .map(str::to_string)
}

/// The meters Claude Code cached for itself, ignored when they belong to a
/// different signed-in account.
fn cached_claude_account(file: &Value) -> Option<ClaudeAccount> {
    let cached = file.get("cachedUsageUtilization")?;
    let signed_in = file
        .get("oauthAccount")
        .and_then(|account| account.get("accountUuid"))
        .and_then(Value::as_str);
    let cached_for = cached.get("accountUuid").and_then(Value::as_str);
    if signed_in.is_some() && cached_for.is_some() && signed_in != cached_for {
        return None;
    }
    let observed_at_ms = cached.get("fetchedAtMs").and_then(Value::as_i64)?;
    let body = cached.get("utilization").filter(|body| body.is_object())?;
    parse_claude_usage(body, "claudeCode", observed_at_ms)
}

pub(crate) fn parse_claude_usage(
    body: &Value,
    source: &'static str,
    observed_at_ms: i64,
) -> Option<ClaudeAccount> {
    let mut account = ClaudeAccount {
        source,
        observed_at_ms,
        session: claude_window(body.get("five_hour"), SESSION_MINUTES),
        weekly: claude_window(body.get("seven_day"), WEEKLY_MINUTES),
        scoped: Vec::new(),
        extra: extra_usage(body),
    };
    if let Some(entries) = body.get("limits").and_then(Value::as_array) {
        for entry in entries {
            let Some(kind) = entry.get("kind").and_then(Value::as_str) else {
                continue;
            };
            let Some(used_percent) = entry
                .get("percent")
                .and_then(percent)
                .or_else(|| entry.get("utilization").and_then(percent))
            else {
                continue;
            };
            let resets_at_ms = reset_ms(entry.get("resets_at"));
            match kind {
                "session" if account.session.is_none() => {
                    account.session = Some(Window {
                        used_percent,
                        window_minutes: SESSION_MINUTES,
                        resets_at_ms,
                    });
                }
                "weekly_all" if account.weekly.is_none() => {
                    account.weekly = Some(Window {
                        used_percent,
                        window_minutes: WEEKLY_MINUTES,
                        resets_at_ms,
                    });
                }
                "weekly_scoped" => {
                    if let Some(name) = scoped_name(entry) {
                        account.scoped.push(ScopedWindow {
                            name,
                            used_percent,
                            resets_at_ms,
                        });
                    }
                }
                _ => {}
            }
        }
    }
    let empty = account.session.is_none()
        && account.weekly.is_none()
        && account.scoped.is_empty()
        && account.extra.is_none();
    (!empty).then_some(account)
}

fn claude_window(value: Option<&Value>, window_minutes: u64) -> Option<Window> {
    let window = value.filter(|window| !window.is_null())?;
    Some(Window {
        used_percent: percent(window.get("utilization")?)?,
        window_minutes,
        resets_at_ms: reset_ms(window.get("resets_at")),
    })
}

fn scoped_name(entry: &Value) -> Option<String> {
    let scope = entry.get("scope")?;
    scope
        .get("model")
        .and_then(|model| model.get("display_name").or_else(|| model.get("id")))
        .and_then(Value::as_str)
        .or_else(|| scope.as_str())
        .filter(|name| !name.is_empty())
        .map(str::to_string)
}

fn extra_usage(body: &Value) -> Option<ExtraUsage> {
    let extra = body.get("extra_usage").filter(|extra| !extra.is_null())?;
    let enabled = extra
        .get("is_enabled")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    // Anthropic reports credits in cents.
    let used_usd = extra
        .get("used_credits")
        .and_then(Value::as_f64)
        .filter(|amount| amount.is_finite() && *amount >= 0.0)
        .map(|amount| amount / 100.0);
    let limit_usd = extra
        .get("monthly_limit")
        .and_then(Value::as_f64)
        .filter(|amount| amount.is_finite() && *amount > 0.0)
        .map(|amount| amount / 100.0);
    let used_percent = extra.get("utilization").and_then(percent);
    (enabled || used_usd.is_some_and(|used| used > 0.0) || limit_usd.is_some()).then_some(
        ExtraUsage {
            enabled,
            used_usd,
            limit_usd,
            used_percent,
        },
    )
}

/// A finite, non-negative percentage, capped at 100.
fn percent(value: &Value) -> Option<f64> {
    value
        .as_f64()
        .filter(|value| value.is_finite() && *value >= 0.0)
        .map(|value| value.min(100.0))
}

fn reset_ms(value: Option<&Value>) -> Option<i64> {
    match value? {
        Value::String(text) => parse_time(text),
        Value::Number(number) => number.as_i64().map(|seconds| {
            // Seconds or milliseconds since 1970.
            if seconds < 100_000_000_000 {
                seconds * 1000
            } else {
                seconds
            }
        }),
        _ => None,
    }
}

/// RFC 3339 time in milliseconds. Anthropic sends microseconds
/// (`…59.714946+00:00`), which are cut to milliseconds before parsing.
fn parse_time(text: &str) -> Option<i64> {
    let normalized = match text.find('.') {
        Some(dot) => {
            let digits = text[dot + 1..]
                .bytes()
                .take_while(u8::is_ascii_digit)
                .count();
            let kept = digits.min(3);
            format!("{}{}", &text[..dot + 1 + kept], &text[dot + 1 + digits..])
        }
        None => text.to_string(),
    };
    parse_ts_timestamp(&normalized).map(|time| time.as_millis())
}

struct ClaudeToken {
    access_token: String,
    expires_at_ms: Option<i64>,
}

/// Reads Claude Code's sign-in without modifying it: the Keychain item first
/// (macOS), then `~/.claude/.credentials.json`.
fn claude_token() -> Option<ClaudeToken> {
    #[cfg(target_os = "macos")]
    if let Some(token) = keychain_secret().as_deref().and_then(claude_token_from) {
        return Some(token);
    }
    let mut dirs = claude_config_dirs();
    dirs.extend(home().map(|home| home.join(".claude")));
    dirs.iter().find_map(|dir| {
        claude_token_from(&fs::read_to_string(dir.join(".credentials.json")).ok()?)
    })
}

#[cfg(target_os = "macos")]
fn keychain_secret() -> Option<String> {
    let output = std::process::Command::new("/usr/bin/security")
        .args(["find-generic-password", "-s", CLAUDE_KEYCHAIN_SERVICE, "-w"])
        .stderr(std::process::Stdio::null())
        .output()
        .ok()
        .filter(|output| output.status.success())?;
    String::from_utf8(output.stdout).ok()
}

fn claude_token_from(text: &str) -> Option<ClaudeToken> {
    let value = serde_json::from_str::<Value>(text.trim()).ok()?;
    let oauth = value.get("claudeAiOauth")?;
    Some(ClaudeToken {
        access_token: oauth
            .get("accessToken")
            .and_then(Value::as_str)
            .filter(|token| !token.is_empty())?
            .to_string(),
        expires_at_ms: oauth.get("expiresAt").and_then(Value::as_i64),
    })
}

fn live_claude_account() -> (Option<ClaudeAccount>, LiveStatus) {
    let Some(token) = claude_token() else {
        return (None, LiveStatus::of(LiveState::NoSignIn));
    };
    let now = utc_now().as_millis();
    // An expired token is never sent: Anthropic answers it with a long
    // rate limit. Claude Code renews it on its next run.
    if token.expires_at_ms.is_some_and(|expires| now >= expires) {
        return (None, LiveStatus::of(LiveState::SignInExpired));
    }
    let response = minreq::get(CLAUDE_USAGE_URL)
        .with_header("Authorization", format!("Bearer {}", token.access_token))
        .with_header("anthropic-beta", "oauth-2025-04-20")
        .with_header("Accept", "application/json")
        .with_header("User-Agent", USER_AGENT)
        .with_timeout(FETCH_TIMEOUT_SECONDS)
        .send();
    let Ok(response) = response else {
        return (None, LiveStatus::of(LiveState::Failed));
    };
    match response.status_code {
        200 => {}
        401 | 403 => return (None, LiveStatus::of(LiveState::Unauthorized)),
        429 => {
            let retry = response
                .headers
                .iter()
                .find(|(name, _)| name.eq_ignore_ascii_case("retry-after"))
                .and_then(|(_, value)| value.trim().parse().ok());
            return (
                None,
                LiveStatus {
                    state: LiveState::RateLimited,
                    retry_after_seconds: retry,
                },
            );
        }
        _ => return (None, LiveStatus::of(LiveState::Failed)),
    }
    let account = response
        .as_str()
        .ok()
        .and_then(|body| serde_json::from_str::<Value>(body).ok())
        .and_then(|body| parse_claude_usage(&body, "live", utc_now().as_millis()));
    match account {
        Some(account) => (Some(account), LiveStatus::of(LiveState::Ok)),
        None => (None, LiveStatus::of(LiveState::Failed)),
    }
}

// MARK: - Codex

fn codex_quota(live: bool) -> CodexQuota {
    let logged = latest_logged_codex();
    let plan_from_logs = logged
        .as_ref()
        .and_then(|(_, plan, _)| plan.clone())
        .filter(|plan| !plan.is_empty() && plan != "unknown");
    let logs_snapshot = logged.as_ref().map(|(snapshot, _, _)| snapshot.clone());
    if !live {
        return CodexQuota {
            plan_type: plan_from_logs,
            snapshot: logs_snapshot,
            limit_usage_daily: Vec::new(),
            live: LiveStatus::off(),
        };
    }
    let Some(token) = codex_token() else {
        return CodexQuota {
            plan_type: plan_from_logs,
            snapshot: logs_snapshot,
            limit_usage_daily: Vec::new(),
            live: LiveStatus::of(LiveState::NoSignIn),
        };
    };
    let daily = {
        let token = token.clone();
        thread::spawn(move || fetch_codex(CODEX_DAILY_URL, &token))
    };
    let others = (1..CODEX_LIVE_READS)
        .map(|_| {
            let token = token.clone();
            thread::spawn(move || fetch_codex(CODEX_USAGE_URL, &token))
        })
        .collect::<Vec<_>>();
    let first = fetch_codex(CODEX_USAGE_URL, &token);
    let first_error = first.as_ref().err().copied();
    let observed_at_ms = utc_now().as_millis();
    let mut live_plan = None;
    let live_snapshot = others
        .into_iter()
        .map(|read| read.join().ok().and_then(Result::ok))
        .fold(first.ok(), |kept, next| match (kept, next) {
            (Some(kept), Some(next)) => Some(lower_meter(kept, next)),
            (kept, next) => kept.or(next),
        })
        .and_then(|body| serde_json::from_str::<Value>(&body).ok())
        .and_then(|body| parse_codex_usage(&body, observed_at_ms))
        .map(|(snapshot, plan)| {
            live_plan = plan;
            heal_overcount(snapshot, logs_snapshot.as_ref(), observed_at_ms)
        });
    // Any read that returned meters makes the live read a success; otherwise
    // the first read's error says why.
    let state = if live_snapshot.is_some() {
        LiveState::Ok
    } else {
        first_error.unwrap_or(LiveState::Failed)
    };
    let limit_usage_daily = daily
        .join()
        .ok()
        .and_then(Result::ok)
        .map(|body| parse_limit_usage(&body))
        .unwrap_or_default();
    let plan_type = live_plan
        .filter(|plan| !plan.is_empty() && plan != "unknown")
        .or(plan_from_logs);
    // A live answer without a weekly window keeps the logged one.
    let snapshot = match (live_snapshot, logs_snapshot) {
        (Some(mut live), Some(logs)) if live.weekly.is_none() => {
            live.weekly = logs.weekly;
            live.short = live.short.or(logs.short);
            Some(live)
        }
        (live, logs) => live.or(logs),
    };
    CodexQuota {
        plan_type,
        snapshot,
        limit_usage_daily,
        live: LiveStatus::of(state),
    }
}

/// Codex homes as ccusage resolves them, for `auth.json`.
fn codex_homes() -> Vec<PathBuf> {
    match env::var("CODEX_HOME") {
        Ok(value) => value
            .split(',')
            .map(str::trim)
            .filter(|path| !path.is_empty())
            .map(PathBuf::from)
            .collect(),
        Err(_) => home().map(|home| vec![home.join(".codex")]).unwrap_or_default(),
    }
}

fn codex_token() -> Option<String> {
    codex_homes().iter().find_map(|home| {
        let text = fs::read_to_string(home.join("auth.json")).ok()?;
        let value = serde_json::from_str::<Value>(text.trim()).ok()?;
        value
            .get("tokens")?
            .get("access_token")?
            .as_str()
            .filter(|token| !token.is_empty())
            .map(str::to_string)
    })
}

fn fetch_codex(url: &str, token: &str) -> Result<String, LiveState> {
    let response = minreq::get(url)
        .with_header("Authorization", format!("Bearer {token}"))
        .with_header("Accept", "application/json")
        .with_header("User-Agent", USER_AGENT)
        .with_timeout(FETCH_TIMEOUT_SECONDS)
        .send()
        .map_err(|_| LiveState::Failed)?;
    match response.status_code {
        200 => response
            .as_str()
            .map(str::to_string)
            .map_err(|_| LiveState::Failed),
        401 | 403 => Err(LiveState::Unauthorized),
        429 => Err(LiveState::RateLimited),
        _ => Err(LiveState::Failed),
    }
}

/// The usage endpoint sometimes over-counts the weekly meter (seen: 99% while
/// Codex enforced 49%). An over-count never under-reports, so of two reads for
/// the same window the lower one is kept.
fn lower_meter(first: String, second: String) -> String {
    let weekly = |body: &str| {
        parse_codex_usage(&serde_json::from_str::<Value>(body).ok()?, 0)
            .and_then(|(snapshot, _)| snapshot.weekly)
    };
    match (weekly(&first), weekly(&second)) {
        (Some(a), Some(b)) if same_window(&a, &b) && b.used_percent < a.used_percent => second,
        _ => first,
    }
}

fn same_window(a: &Window, b: &Window) -> bool {
    a.window_minutes == b.window_minutes
        && matches!((a.resets_at_ms, b.resets_at_ms), (Some(a), Some(b)) if (a - b).abs() <= 60_000)
}

/// A recent logged meter far below the live one marks the live value as an
/// over-count for the same window.
fn heal_overcount(
    mut live: CodexSnapshot,
    logs: Option<&CodexSnapshot>,
    now_ms: i64,
) -> CodexSnapshot {
    let (Some(live_week), Some(logs)) = (live.weekly, logs) else {
        return live;
    };
    let (Some(log_week), Some(logged_at)) = (logs.weekly, logs.observed_at_ms) else {
        return live;
    };
    let fresh = now_ms - logged_at <= CODEX_LOG_TRUST_MS;
    if fresh
        && same_window(&live_week, &log_week)
        && live_week.used_percent > log_week.used_percent * 1.5 + 3.0
    {
        live.weekly = Some(Window {
            used_percent: log_week.used_percent,
            ..live_week
        });
    }
    live
}

/// Parses the live usage endpoint: `(snapshot, plan type)`.
pub(crate) fn parse_codex_usage(
    body: &Value,
    observed_at_ms: i64,
) -> Option<(CodexSnapshot, Option<String>)> {
    let plan = body
        .get("plan_type")
        .and_then(Value::as_str)
        .map(str::to_string);
    let rate_limit = body.get("rate_limit")?;
    let windows = [
        live_window(rate_limit.get("primary_window")),
        live_window(rate_limit.get("secondary_window")),
    ];
    let credits = body
        .get("rate_limit_reset_credits")
        .or_else(|| body.get("rateLimitResetCredits"))
        .and_then(|credits| {
            credits
                .get("available_count")
                .or_else(|| credits.get("availableCount"))
        })
        .and_then(Value::as_u64)
        .and_then(|count| u32::try_from(count).ok());
    Some((
        CodexSnapshot {
            source: "live",
            observed_at_ms: Some(observed_at_ms),
            weekly: weekly_of(&windows),
            short: short_of(&windows),
            reset_credits_available: credits,
        },
        plan,
    ))
}

fn live_window(value: Option<&Value>) -> Option<Window> {
    let window = value.filter(|window| !window.is_null())?;
    Some(Window {
        used_percent: percent(window.get("used_percent")?)?,
        window_minutes: window.get("limit_window_seconds")?.as_u64()? / 60,
        resets_at_ms: window
            .get("reset_at")
            .and_then(Value::as_i64)
            .map(|seconds| seconds * 1000),
    })
}

/// The account's weekly (or longer) window; a 5-hour meter is never weekly.
fn weekly_of(windows: &[Option<Window>]) -> Option<Window> {
    windows
        .iter()
        .flatten()
        .filter(|window| window.window_minutes >= 2 * 24 * 60)
        .max_by_key(|window| window.window_minutes)
        .copied()
}

fn short_of(windows: &[Option<Window>]) -> Option<Window> {
    windows
        .iter()
        .flatten()
        .filter(|window| window.window_minutes < 24 * 60)
        .max_by_key(|window| window.window_minutes)
        .copied()
}

fn collect_sessions(dir: &Path, files: &mut Vec<PathBuf>) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let Ok(kind) = entry.file_type() else { continue };
        if kind.is_dir() {
            collect_sessions(&path, files);
        } else if path
            .file_name()
            .and_then(|name| name.to_str())
            .is_some_and(|name| name.ends_with(".jsonl") || name.ends_with(".jsonl.zst"))
        {
            files.push(path);
        }
    }
}

/// Every session file in the configured Codex folders, plain or compressed
/// (`.jsonl.zst`, as Codex stores older sessions). Where both copies exist
/// the plain one is kept, as Codex and ccusage do.
pub(crate) fn codex_session_files() -> Vec<PathBuf> {
    let mut files = Vec::new();
    for dir in sources::codex().existing {
        collect_sessions(&dir, &mut files);
    }
    let plain: std::collections::HashSet<PathBuf> =
        files.iter().filter(|file| !is_compressed(file)).cloned().collect();
    files.retain(|file| !is_compressed(file) || !plain.contains(&file.with_extension("")));
    // Names start with the session's start time, so this is chronological
    // across homes.
    files.sort_by(|a, b| a.file_name().cmp(&b.file_name()));
    files
}

fn is_compressed(file: &Path) -> bool {
    file.extension().is_some_and(|ext| ext == "zst")
}

/// A whole session file as text, decompressing `.jsonl.zst`.
pub(crate) fn read_session(file: &Path) -> Option<String> {
    if !is_compressed(file) {
        return fs::read_to_string(file).ok();
    }
    let mut text = String::new();
    zstd::stream::read::Decoder::new(fs::File::open(file).ok()?)
        .ok()?
        .read_to_string(&mut text)
        .ok()?;
    Some(text)
}

/// The newest *account* meter logged by Codex: `(snapshot, plan, logged at)`.
/// Model-specific side limits (`limit_id` other than `codex`) are skipped.
///
/// Codex keeps sessions open for days, so the newest-named file is often not
/// the last one written: the most recently modified files are read and the
/// latest timestamp wins.
fn latest_logged_codex() -> Option<(CodexSnapshot, Option<String>, Option<i64>)> {
    let mut files: Vec<(std::time::SystemTime, PathBuf)> = codex_session_files()
        .into_iter()
        .filter_map(|file| Some((fs::metadata(&file).ok()?.modified().ok()?, file)))
        .collect();
    files.sort_by_key(|(modified, _)| std::cmp::Reverse(*modified));
    let mut best: Option<(CodexSnapshot, Option<String>, Option<i64>)> = None;
    for (modified, file) in files.iter().take(CODEX_FILES_SCANNED) {
        let best_ms = best.as_ref().and_then(|(_, _, at)| *at);
        // A file last written before the best meter cannot hold a newer one.
        let modified_ms = modified
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |since| since.as_millis() as i64);
        if best_ms.is_some_and(|best_ms| modified_ms < best_ms) {
            break;
        }
        if let Some(found) = last_logged_codex(file)
            && (best.is_none() || found.2.unwrap_or(i64::MIN) > best_ms.unwrap_or(i64::MIN))
        {
            best = Some(found);
        }
    }
    best
}

/// The last account meter in one session file. Reads a growing tail, so a
/// long line after the meter (a tool output, an image) does not hide it.
fn last_logged_codex(file: &Path) -> Option<(CodexSnapshot, Option<String>, Option<i64>)> {
    if is_compressed(file) {
        return read_session(file)?.lines().rev().find_map(logged_codex_line);
    }
    let len = fs::metadata(file).ok()?.len();
    let mut bytes = CODEX_TAIL_BYTES;
    loop {
        let found = tail(file, bytes).and_then(|text| text.lines().rev().find_map(logged_codex_line));
        if found.is_some() || bytes >= len || bytes >= CODEX_TAIL_MAX_BYTES {
            return found;
        }
        bytes *= 4;
    }
}

pub(crate) fn logged_codex_line(line: &str) -> Option<(CodexSnapshot, Option<String>, Option<i64>)> {
    if !line.contains("rate_limits") {
        return None;
    }
    let value = serde_json::from_str::<Value>(line).ok()?;
    let limits = value.get("payload")?.get("rate_limits")?;
    let limit_id = limits.get("limit_id").and_then(Value::as_str).unwrap_or("codex");
    if limit_id != "codex" {
        return None;
    }
    let windows = [
        logged_window(limits.get("primary")),
        logged_window(limits.get("secondary")),
    ];
    if windows.iter().all(Option::is_none) {
        return None;
    }
    let observed_at_ms = value
        .get("timestamp")
        .and_then(Value::as_str)
        .and_then(parse_ts_timestamp)
        .map(|time| time.as_millis());
    let plan = limits
        .get("plan_type")
        .and_then(Value::as_str)
        .map(str::to_string);
    Some((
        CodexSnapshot {
            source: "logs",
            observed_at_ms,
            weekly: weekly_of(&windows),
            short: short_of(&windows),
            reset_credits_available: None,
        },
        plan,
        observed_at_ms,
    ))
}

fn logged_window(value: Option<&Value>) -> Option<Window> {
    let window = value.filter(|window| !window.is_null())?;
    Some(Window {
        used_percent: percent(window.get("used_percent")?)?,
        window_minutes: window.get("window_minutes")?.as_u64()?,
        resets_at_ms: window
            .get("resets_at")
            .and_then(Value::as_i64)
            .map(|seconds| seconds * 1000),
    })
}

fn tail(path: &Path, max_bytes: u64) -> Option<String> {
    let mut file = fs::File::open(path).ok()?;
    let len = file.metadata().ok()?.len();
    if len > max_bytes {
        file.seek(SeekFrom::End(-(max_bytes as i64))).ok()?;
    }
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes).ok()?;
    let mut text = String::from_utf8_lossy(&bytes).into_owned();
    if len > max_bytes
        && let Some(index) = text.find('\n')
    {
        text.drain(..=index);
    }
    Some(text)
}

pub(crate) fn parse_limit_usage(body: &str) -> Vec<LimitUsageDay> {
    let Ok(value) = serde_json::from_str::<Value>(body) else {
        return Vec::new();
    };
    if value
        .get("units")
        .and_then(Value::as_str)
        .is_some_and(|units| units != "percent")
    {
        return Vec::new();
    }
    let positive = |value: &Value| value.as_f64().filter(|value| value.is_finite() && *value > 0.0);
    let mut days = value
        .get("data")
        .and_then(Value::as_array)
        .map(|days| {
            days.iter()
                .filter_map(|day| {
                    let date = day.get("date")?.as_str()?.to_string();
                    let mut surfaces = day
                        .get("product_surface_usage_values")
                        .and_then(Value::as_object)
                        .map(|values| {
                            values
                                .iter()
                                .filter_map(|(surface, value)| {
                                    Some(LimitUsageSurface {
                                        surface: surface.clone(),
                                        used_percent: positive(value)?,
                                    })
                                })
                                .collect::<Vec<_>>()
                        })
                        .unwrap_or_default();
                    surfaces.sort_by(|a, b| b.used_percent.total_cmp(&a.used_percent));
                    let mut models = day
                        .get("models")
                        .and_then(Value::as_array)
                        .map(|models| {
                            models
                                .iter()
                                .filter_map(|model| {
                                    Some(LimitUsageModel {
                                        model: model.get("model")?.as_str()?.to_string(),
                                        speed: model
                                            .get("speed")
                                            .and_then(Value::as_str)
                                            .map(str::to_string),
                                        used_percent: positive(model.get("credits")?)?,
                                    })
                                })
                                .collect::<Vec<_>>()
                        })
                        .unwrap_or_default();
                    models.sort_by(|a, b| b.used_percent.total_cmp(&a.used_percent));
                    // An empty float sum is -0.0; adding 0.0 keeps empty days at +0.
                    let used_percent = if surfaces.is_empty() {
                        models.iter().map(|model| model.used_percent).sum::<f64>() + 0.0
                    } else {
                        surfaces.iter().map(|surface| surface.used_percent).sum::<f64>() + 0.0
                    };
                    Some(LimitUsageDay {
                        date,
                        used_percent,
                        surfaces,
                        models,
                    })
                })
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    days.sort_by(|a, b| a.date.cmp(&b.date));
    days
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn reads_claude_code_cached_meters_and_scoped_limits() {
        let file = json!({
            "oauthAccount": {"accountUuid": "a", "organizationRateLimitTier": "default_claude_max_20x"},
            "cachedUsageUtilization": {
                "accountUuid": "a",
                "fetchedAtMs": 1_791_000_000_000_i64,
                "utilization": {
                    "five_hour": {"utilization": 12.0, "resets_at": "2026-10-17T15:00:00Z"},
                    "seven_day": {"utilization": 40.0, "resets_at": "2026-10-20T08:00:00+00:00"},
                    "limits": [
                        {"kind": "weekly_scoped", "percent": 55, "scope": {"model": {"display_name": "Opus"}}}
                    ],
                    "extra_usage": {"is_enabled": true, "used_credits": 1250, "monthly_limit": 5000, "utilization": 25.0}
                }
            }
        });
        assert_eq!(plan_tier(&file).as_deref(), Some("default_claude_max_20x"));
        let account = cached_claude_account(&file).unwrap();
        assert_eq!(account.source, "claudeCode");
        assert_eq!(account.observed_at_ms, 1_791_000_000_000);
        assert_eq!(account.session.unwrap().used_percent, 12.0);
        assert_eq!(account.session.unwrap().window_minutes, 300);
        assert_eq!(
            account.weekly.unwrap().resets_at_ms,
            parse_ts_timestamp("2026-10-20T08:00:00Z").map(|t| t.as_millis())
        );
        assert_eq!(account.scoped[0].name, "Opus");
        assert_eq!(account.scoped[0].used_percent, 55.0);
        let extra = account.extra.unwrap();
        assert_eq!(extra.used_usd, Some(12.5));
        assert_eq!(extra.limit_usd, Some(50.0));
    }

    #[test]
    fn parses_reset_times_with_microseconds() {
        assert_eq!(
            parse_time("2026-10-17T17:29:59.714946+00:00"),
            parse_ts_timestamp("2026-10-17T17:29:59.714Z").map(|t| t.as_millis())
        );
        assert_eq!(
            parse_time("2026-10-19T22:00:00+00:00"),
            parse_ts_timestamp("2026-10-19T22:00:00Z").map(|t| t.as_millis())
        );
        assert!(parse_time("soon").is_none());
    }

    #[test]
    fn ignores_cached_meters_of_another_account() {
        let file = json!({
            "oauthAccount": {"accountUuid": "b"},
            "cachedUsageUtilization": {"accountUuid": "a", "fetchedAtMs": 1, "utilization": {"five_hour": {"utilization": 1}}}
        });
        assert!(cached_claude_account(&file).is_none());
    }

    #[test]
    fn empty_meters_are_not_an_account_reading() {
        assert!(parse_claude_usage(&json!({"five_hour": null}), "live", 1).is_none());
    }

    #[test]
    fn reads_codex_account_meter_and_skips_side_limits() {
        let account = r#"{"timestamp":"2026-10-17T10:00:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":17.0,"window_minutes":300,"resets_at":1792000000},"secondary":{"used_percent":7.0,"window_minutes":10080,"resets_at":1792400000},"plan_type":"pro"}}}"#;
        let (snapshot, plan, at) = logged_codex_line(account).unwrap();
        assert_eq!(plan.as_deref(), Some("pro"));
        assert_eq!(at, parse_ts_timestamp("2026-10-17T10:00:00Z").map(|t| t.as_millis()));
        assert_eq!(snapshot.weekly.unwrap().used_percent, 7.0);
        assert_eq!(snapshot.weekly.unwrap().resets_at_ms, Some(1_792_400_000_000));
        assert_eq!(snapshot.short.unwrap().window_minutes, 300);

        let spark = r#"{"payload":{"rate_limits":{"limit_id":"codex_bengalfox","primary":{"used_percent":100.0,"window_minutes":10080,"resets_at":2}}}}"#;
        assert!(logged_codex_line(spark).is_none());
        assert!(logged_codex_line(r#"{"payload":{"type":"token_count"}}"#).is_none());
    }

    #[test]
    fn a_five_hour_meter_is_never_the_weekly_quota() {
        let line = r#"{"payload":{"rate_limits":{"primary":{"used_percent":40.0,"window_minutes":300,"resets_at":1}}}}"#;
        let (snapshot, _, _) = logged_codex_line(line).unwrap();
        assert!(snapshot.weekly.is_none());
        assert_eq!(snapshot.short.unwrap().used_percent, 40.0);
    }

    #[test]
    fn parses_live_codex_usage_with_reset_credits() {
        let body = json!({
            "plan_type": "plus",
            "rate_limit": {
                "primary_window": {"used_percent": 85, "limit_window_seconds": 604800, "reset_at": 1788954006},
                "secondary_window": null
            },
            "rate_limit_reset_credits": {"available_count": 2}
        });
        let (snapshot, plan) = parse_codex_usage(&body, 5).unwrap();
        assert_eq!(plan.as_deref(), Some("plus"));
        assert_eq!(snapshot.weekly.unwrap().window_minutes, 10080);
        assert_eq!(snapshot.weekly.unwrap().resets_at_ms, Some(1_788_954_006_000));
        assert_eq!(snapshot.reset_credits_available, Some(2));
    }

    fn weekly(used: f64, resets_at_ms: i64) -> CodexSnapshot {
        CodexSnapshot {
            source: "live",
            observed_at_ms: Some(0),
            weekly: Some(Window {
                used_percent: used,
                window_minutes: WEEKLY_MINUTES,
                resets_at_ms: Some(resets_at_ms),
            }),
            short: None,
            reset_credits_available: None,
        }
    }

    #[test]
    fn a_fresh_log_meter_corrects_a_live_overcount() {
        let mut logs = weekly(49.0, 1_000_000);
        logs.observed_at_ms = Some(9 * 60_000);
        let healed = heal_overcount(weekly(99.0, 1_010_000), Some(&logs), 10 * 60_000);
        assert_eq!(healed.weekly.unwrap().used_percent, 49.0);
        // A plausible live value is kept.
        let kept = heal_overcount(weekly(52.0, 1_000_000), Some(&logs), 10 * 60_000);
        assert_eq!(kept.weekly.unwrap().used_percent, 52.0);
        // A stale log cannot contradict the live meter.
        logs.observed_at_ms = Some(0);
        let stale = heal_overcount(weekly(99.0, 1_000_000), Some(&logs), 60 * 60_000);
        assert_eq!(stale.weekly.unwrap().used_percent, 99.0);
    }

    #[test]
    fn parses_daily_limit_usage_by_surface_and_model() {
        let body = r#"{"data":[
            {"date":"2026-09-02","product_surface_usage_values":{"cli":1.5,"desktop_app":4.0,"web":0.0},
             "models":[{"model":"gpt-5.6-sol","speed":"standard","credits":5.0},{"model":"x","speed":"fast","credits":0.0}]},
            {"date":"2026-09-01","product_surface_usage_values":{},"models":[]}
        ],"units":"percent"}"#;
        let days = parse_limit_usage(body);
        assert_eq!(days.len(), 2);
        assert_eq!(days[0].date, "2026-09-01");
        assert!(days[0].used_percent.is_sign_positive());
        assert_eq!(days[1].used_percent, 5.5);
        assert_eq!(days[1].surfaces[0].surface, "desktop_app");
        assert_eq!(days[1].models.len(), 1);
        assert!(parse_limit_usage(r#"{"data":[],"units":"credits"}"#).is_empty());
        assert!(parse_limit_usage("not json").is_empty());
    }

    #[test]
    fn reads_claude_tokens_without_exposing_other_fields() {
        let token = claude_token_from(
            r#"{"claudeAiOauth":{"accessToken":"t","refreshToken":"r","expiresAt":5}}"#,
        )
        .unwrap();
        assert_eq!(token.access_token, "t");
        assert_eq!(token.expires_at_ms, Some(5));
        assert!(claude_token_from(r#"{"claudeAiOauth":{"accessToken":""}}"#).is_none());
    }
}
