//! Source detection for status reporting.
//!
//! ccusage resolves the directories it reads on its own; this module mirrors
//! that resolution (same environment variables, same defaults) only to tell
//! the app which folders exist, so "no history" can be told apart from a
//! failure. Nothing here opens or modifies a log file.

use std::{
    env,
    path::{Path, PathBuf},
};

use serde::Serialize;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum SourceId {
    Claude,
    Codex,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum SourceState {
    /// History was read successfully (possibly with zero usage events).
    Ok,
    /// No history directory exists at any configured or default location.
    NotFound,
    /// A directory exists but reading or parsing it failed.
    Error,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SourceStatus {
    pub id: SourceId,
    pub state: SourceState,
    /// Directories that exist and are read, in ccusage's resolution order.
    pub paths: Vec<String>,
    /// Where history was looked for when nothing was found.
    pub searched: Vec<String>,
    /// Environment variable that overrides the default location.
    pub env_var: &'static str,
    pub env_override: bool,
    pub error: Option<String>,
}

pub struct Resolved {
    pub existing: Vec<PathBuf>,
    pub searched: Vec<PathBuf>,
    pub env_override: bool,
}

fn home() -> Option<PathBuf> {
    env::var_os("HOME").map(PathBuf::from)
}

fn expand_home(raw: &str) -> PathBuf {
    if let Some(rest) = raw.strip_prefix("~/")
        && let Some(home) = home()
    {
        return home.join(rest);
    }
    PathBuf::from(raw)
}

fn split_paths(value: &str) -> impl Iterator<Item = &str> {
    value.split(',').map(str::trim).filter(|path| !path.is_empty())
}

/// Claude Code: `CLAUDE_CONFIG_DIR` (comma separated) or
/// `$XDG_CONFIG_HOME/claude` and `~/.claude`, each holding `projects/`.
pub fn claude() -> Resolved {
    let mut candidates = Vec::new();
    let env_value = env::var("CLAUDE_CONFIG_DIR").ok();
    if let Some(value) = env_value.as_deref() {
        for raw in split_paths(value) {
            let path = expand_home(raw);
            let path = if path.file_name().is_some_and(|name| name == "projects") {
                path.parent().map(Path::to_path_buf).unwrap_or(path)
            } else {
                path
            };
            candidates.push(path);
        }
    } else if let Some(home) = home() {
        let xdg = env::var("XDG_CONFIG_HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|_| home.join(".config"));
        candidates.push(xdg.join("claude"));
        candidates.push(home.join(".claude"));
    }
    let existing = candidates
        .iter()
        .filter(|path| path.join("projects").is_dir())
        .cloned()
        .collect();
    Resolved {
        existing,
        searched: candidates.iter().map(|path| path.join("projects")).collect(),
        env_override: env_value.is_some(),
    }
}

/// Codex: `CODEX_HOME` (comma separated) or `~/.codex`, holding `sessions/`
/// and/or `archived_sessions/`.
pub fn codex() -> Resolved {
    let env_value = env::var("CODEX_HOME").ok();
    let homes: Vec<PathBuf> = match env_value.as_deref() {
        // ccusage uses CODEX_HOME entries verbatim (no `~` expansion).
        Some(value) => split_paths(value).map(PathBuf::from).collect(),
        None => home().map(|home| vec![home.join(".codex")]).unwrap_or_default(),
    };
    let mut existing = Vec::new();
    let mut searched = Vec::new();
    for home in &homes {
        let before = existing.len();
        for name in ["sessions", "archived_sessions"] {
            let dir = home.join(name);
            if dir.is_dir() {
                existing.push(dir.clone());
            }
            searched.push(dir);
        }
        // Like ccusage, a home without either folder is read as the folder itself.
        if existing.len() == before && home.is_dir() {
            existing.push(home.clone());
        }
    }
    Resolved {
        existing,
        searched,
        env_override: env_value.is_some(),
    }
}

pub fn display(paths: &[PathBuf]) -> Vec<String> {
    paths.iter().map(|path| path.display().to_string()).collect()
}
