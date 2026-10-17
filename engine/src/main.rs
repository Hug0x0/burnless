//! burnless-engine: reads local Claude Code and Codex history with ccusage and
//! prints one versioned JSON report on stdout.
//!
//! Usage: burnless-engine report [--timezone <IANA>] [--online-pricing]
//!        burnless-engine version
//!
//! The engine never writes to the history folders and never prints prompt or
//! conversation content: rows only carry dates, model names and token counts.

mod report;
mod sources;

use std::{
    panic::{AssertUnwindSafe, catch_unwind},
    process::ExitCode,
    time::{SystemTime, UNIX_EPOCH},
};

use ccusage_core::{
    PricingMap,
    cli::{AgentReportKind, CodexSpeed, CostMode, SharedArgs},
};
use serde::Serialize;

use report::{Row, SCHEMA_VERSION};
use sources::{Resolved, SourceId, SourceState, SourceStatus};

const CCUSAGE_REV: &str = "57e5658dcac4de42f50d059b62cddc1fec9bbdc9";
const LITELLM_REV: &str = "1fd7f81f97cffec77621964ba18998b224281726";
const LITELLM_SNAPSHOT_DATE: &str = "2026-10-17";

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Report {
    schema_version: u32,
    engine_version: &'static str,
    generated_at_ms: u64,
    timezone: Option<String>,
    pricing: PricingInfo,
    sources: Vec<SourceStatus>,
    rows: Vec<Row>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct PricingInfo {
    provider: &'static str,
    ccusage_revision: &'static str,
    litellm_revision: &'static str,
    snapshot_date: &'static str,
    /// True when this run also fetched current LiteLLM prices.
    online: bool,
}

struct Options {
    timezone: Option<String>,
    online_pricing: bool,
}

fn parse_args(mut args: impl Iterator<Item = String>) -> Result<(String, Options), String> {
    let command = args.next().unwrap_or_else(|| "report".into());
    let mut options = Options {
        timezone: None,
        online_pricing: false,
    };
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--timezone" => {
                options.timezone = Some(args.next().ok_or("--timezone needs a value")?);
            }
            "--online-pricing" => options.online_pricing = true,
            other => return Err(format!("unknown argument: {other}")),
        }
    }
    Ok((command, options))
}

fn shared_args(options: &Options) -> SharedArgs {
    let mut shared = SharedArgs::with_defaults();
    // JSON mode keeps ccusage's progress output off the terminal.
    shared.json = true;
    shared.offline = !options.online_pricing;
    shared.mode = CostMode::Auto;
    shared.timezone = options.timezone.clone();
    shared
}

fn status(id: SourceId, resolved: &Resolved, env_var: &'static str) -> SourceStatus {
    SourceStatus {
        id,
        state: if resolved.existing.is_empty() {
            SourceState::NotFound
        } else {
            SourceState::Ok
        },
        paths: sources::display(&resolved.existing),
        searched: sources::display(&resolved.searched),
        env_var,
        env_override: resolved.env_override,
        error: None,
    }
}

/// Runs one source in isolation: an error or panic in one adapter must never
/// hide the other source's data.
fn guarded(status: &mut SourceStatus, load: impl FnOnce() -> Result<Vec<Row>, String>) -> Vec<Row> {
    if status.state == SourceState::NotFound {
        return Vec::new();
    }
    match catch_unwind(AssertUnwindSafe(load)) {
        Ok(Ok(rows)) => rows,
        Ok(Err(error)) => {
            status.state = SourceState::Error;
            status.error = Some(error);
            Vec::new()
        }
        Err(_) => {
            status.state = SourceState::Error;
            status.error = Some("The usage reader stopped unexpectedly.".into());
            Vec::new()
        }
    }
}

fn run_report(options: &Options) -> Report {
    let shared = shared_args(options);
    let mut claude = status(SourceId::Claude, &sources::claude(), "CLAUDE_CONFIG_DIR");
    let mut codex = status(SourceId::Codex, &sources::codex(), "CODEX_HOME");

    let mut rows = guarded(&mut claude, || {
        let daily = ccusage_adapter_claude::load_daily_summaries_with_detection(&shared, None, false)
            .map_err(|error| error.to_string())?;
        Ok(report::claude_rows(&daily.summaries))
    });
    rows.extend(guarded(&mut codex, || {
        let pricing = PricingMap::load_with_overrides(shared.offline, false, std::iter::empty());
        let speed = ccusage_adapter_codex::resolve_codex_speed(CodexSpeed::Auto);
        let groups = ccusage_adapter_codex::load_groups(&shared, AgentReportKind::Daily)
            .map_err(|error| error.to_string())?;
        Ok(report::codex_rows(&groups, &pricing, speed))
    }));
    rows.sort_by(|a, b| {
        (a.date.as_str(), a.source as u8, a.model.as_deref())
            .cmp(&(b.date.as_str(), b.source as u8, b.model.as_deref()))
    });

    Report {
        schema_version: SCHEMA_VERSION,
        engine_version: env!("CARGO_PKG_VERSION"),
        generated_at_ms: SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|duration| duration.as_millis() as u64)
            .unwrap_or_default(),
        timezone: options.timezone.clone(),
        pricing: PricingInfo {
            provider: "LiteLLM model_prices_and_context_window.json via ccusage",
            ccusage_revision: CCUSAGE_REV,
            litellm_revision: LITELLM_REV,
            snapshot_date: LITELLM_SNAPSHOT_DATE,
            online: options.online_pricing,
        },
        sources: vec![claude, codex],
        rows,
    }
}

fn main() -> ExitCode {
    let (command, options) = match parse_args(std::env::args().skip(1)) {
        Ok(parsed) => parsed,
        Err(error) => {
            eprintln!("burnless-engine: {error}");
            return ExitCode::from(2);
        }
    };
    match command.as_str() {
        "report" => {
            let report = run_report(&options);
            match serde_json::to_string(&report) {
                Ok(json) => {
                    println!("{json}");
                    ExitCode::SUCCESS
                }
                Err(error) => {
                    eprintln!("burnless-engine: {error}");
                    ExitCode::FAILURE
                }
            }
        }
        "version" => {
            println!(
                "burnless-engine {} (schema {SCHEMA_VERSION}, ccusage {CCUSAGE_REV}, litellm {LITELLM_REV})",
                env!("CARGO_PKG_VERSION")
            );
            ExitCode::SUCCESS
        }
        other => {
            eprintln!("burnless-engine: unknown command {other}");
            ExitCode::from(2)
        }
    }
}
