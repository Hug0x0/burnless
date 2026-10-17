//! Opt-in price refresh (`--online-pricing`).
//!
//! ccusage leaves the HTTP client to the binary. This one only fetches the two
//! public price lists ccusage asks for, sends no usage data, and records
//! whether the LiteLLM list really arrived so the app can say which prices it
//! used. Without `--online-pricing`, ccusage never calls it.

use std::{
    io,
    sync::atomic::{AtomicBool, Ordering},
};

static LITELLM_FETCHED: AtomicBool = AtomicBool::new(false);

const ALLOWED_PREFIXES: &[&str] = &[
    "https://raw.githubusercontent.com/BerriAI/litellm/",
    "https://models.dev/",
];

pub fn install() {
    ccusage_core::pricing::set_json_fetcher(fetch);
}

pub fn litellm_fetched() -> bool {
    LITELLM_FETCHED.load(Ordering::Relaxed)
}

fn fetch(url: &str) -> io::Result<String> {
    if !ALLOWED_PREFIXES.iter().any(|prefix| url.starts_with(prefix)) {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, format!("refusing to fetch {url}")));
    }
    let response = minreq::get(url)
        .with_header("User-Agent", "burnless-engine")
        .with_timeout(15)
        .send()
        .map_err(|error| io::Error::other(error.to_string()))?;
    if response.status_code != 200 {
        return Err(io::Error::other(format!("HTTP {}", response.status_code)));
    }
    let body = response
        .as_str()
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error.to_string()))?
        .to_string();
    if url.contains("BerriAI/litellm") {
        LITELLM_FETCHED.store(true, Ordering::Relaxed);
    }
    Ok(body)
}
