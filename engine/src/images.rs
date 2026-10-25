//! Codex image generations.
//!
//! Codex's built-in image tool logs `image_generation_call` items (id `ig_…`)
//! that carry no token usage, so token-based cost misses them. Burnless counts
//! them per session day for a separate, clearly labelled estimate. Each image
//! emits several streaming events, so ids are deduplicated. Only the id is
//! extracted; the image payload is never parsed or kept.

use std::{
    collections::{BTreeMap, HashSet},
    fs,
    time::{Duration, SystemTime},
};

use ccusage_core::{format_date_tz, parse_ts_timestamp, parse_tz};
use serde::Serialize;

use crate::quota::{codex_session_files, read_session};

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ImageDay {
    /// Local day the image was generated, `YYYY-MM-DD`.
    pub date: String,
    pub count: usize,
}

/// Image generations on or after `since` (`YYYY-MM-DD` in `timezone`), dated
/// by each event's own timestamp: sessions stay open for days, so the file
/// name's start date is only a fallback.
pub fn codex_image_days(since: &str, timezone: Option<&str>) -> Vec<ImageDay> {
    let tz = parse_tz(timezone);
    // A file last written before the period cannot hold an image in it.
    let cutoff = SystemTime::now() - Duration::from_secs(32 * 86_400);
    let mut seen = HashSet::new();
    let mut days: BTreeMap<String, usize> = BTreeMap::new();
    for file in codex_session_files() {
        if fs::metadata(&file)
            .and_then(|meta| meta.modified())
            .is_ok_and(|modified| modified < cutoff)
        {
            continue;
        }
        let fallback = file.file_name().and_then(|name| name.to_str()).and_then(session_date);
        let Some(contents) = read_session(&file) else {
            continue;
        };
        for line in contents.lines() {
            if !line.contains("image_generation_call") {
                continue;
            }
            let Some(id) = image_id(line) else { continue };
            let date = line_timestamp(line)
                .and_then(parse_ts_timestamp)
                .map(|time| format_date_tz(time, tz.as_ref()))
                .or_else(|| fallback.clone());
            if let Some(date) = date
                && date.as_str() >= since
                && seen.insert(id.to_string())
            {
                *days.entry(date).or_default() += 1;
            }
        }
    }
    days.into_iter()
        .map(|(date, count)| ImageDay { date, count })
        .collect()
}

/// The event's top-level `timestamp`, found without parsing the line (which
/// can hold the whole image).
fn line_timestamp(line: &str) -> Option<&str> {
    let start = line.find("\"timestamp\":\"")? + "\"timestamp\":\"".len();
    let rest = &line[start..];
    Some(&rest[..rest.find('"')?])
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
    fn reads_the_event_timestamp_without_parsing() {
        let line = r#"{"timestamp":"2026-10-18T09:00:00.000Z","payload":{"id":"ig_1"}}"#;
        assert_eq!(line_timestamp(line), Some("2026-10-18T09:00:00.000Z"));
        assert_eq!(line_timestamp(r#"{"id":"ig_1"}"#), None);
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
