//! Codex image generations.
//!
//! Codex's built-in image tool logs `image_generation_call` items (id `ig_…`)
//! that carry no token usage, so token-based cost misses them. Burnless counts
//! them per session day for a separate, clearly labelled estimate. Each image
//! emits several streaming events, so ids are deduplicated. Only the id is
//! extracted; the image payload is never parsed or kept.

use std::{collections::BTreeMap, collections::HashSet, fs};

use serde::Serialize;

use crate::quota::codex_session_files;

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ImageDay {
    /// Session start date from the file name, `YYYY-MM-DD`.
    pub date: String,
    pub count: usize,
}

/// Image generations in sessions that started on or after `since` (`YYYY-MM-DD`).
pub fn codex_image_days(since: &str) -> Vec<ImageDay> {
    let mut seen = HashSet::new();
    let mut days: BTreeMap<String, usize> = BTreeMap::new();
    for file in codex_session_files() {
        let Some(date) = file
            .file_name()
            .and_then(|name| name.to_str())
            .and_then(session_date)
        else {
            continue;
        };
        if date.as_str() < since {
            continue;
        }
        let Ok(contents) = fs::read_to_string(&file) else {
            continue;
        };
        for line in contents.lines() {
            if line.contains("image_generation_call")
                && let Some(id) = image_id(line)
                && seen.insert(id.to_string())
            {
                *days.entry(date.clone()).or_default() += 1;
            }
        }
    }
    days.into_iter()
        .map(|(date, count)| ImageDay { date, count })
        .collect()
}

/// `rollout-2026-06-13T10-00-00-….jsonl` → `2026-06-13`.
fn session_date(name: &str) -> Option<String> {
    let rest = name.strip_prefix("rollout-")?;
    let date = rest.get(..10)?;
    let bytes = date.as_bytes();
    (bytes[4] == b'-' && bytes[7] == b'-' && date.chars().filter(char::is_ascii_digit).count() == 8)
        .then(|| date.to_string())
}

fn image_id(line: &str) -> Option<&str> {
    let start = line.find("\"ig_")? + 1;
    let rest = &line[start..];
    Some(&rest[..rest.find('"')?])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_the_image_id_only() {
        let line = r#"{"type":"response_item","payload":{"type":"image_generation_call","id":"ig_abc123","result":"<base64>"}}"#;
        assert_eq!(image_id(line), Some("ig_abc123"));
        assert_eq!(image_id(r#"{"id":"resp_1"}"#), None);
    }

    #[test]
    fn reads_the_session_date_from_the_file_name() {
        assert_eq!(
            session_date("rollout-2026-06-13T10-00-00-x.jsonl").as_deref(),
            Some("2026-06-13")
        );
        assert_eq!(session_date("notes.jsonl"), None);
        assert_eq!(session_date("rollout-abc"), None);
    }
}
