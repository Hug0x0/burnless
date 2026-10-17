//! Converts ccusage's daily aggregates into Burnless report rows.
//!
//! Every row is one (source, local date, model) cell. Token fields share one
//! meaning across sources:
//!
//! - `inputTokens`: input that was neither read from nor written to cache.
//! - `cacheReadTokens` / `cacheWriteTokens`: cached input read / written.
//! - `outputTokens`: generated output (Codex reasoning tokens included).
//! - `totalTokens`: exactly the sum of the four fields above.
//!
//! Claude Code reports input excluding cache; Codex reports input including
//! cached input, so ccusage's `non_cached_input_tokens` normalizes it.

use std::collections::BTreeMap;

use ccusage_adapter_codex::{
    CodexGroup, CodexSpeedPolicy, calculate_codex_model_cost, codex_model_missing_pricing,
    non_cached_input_tokens,
};
use ccusage_core::{PricingMap, UsageSummary};
use serde::Serialize;

use crate::sources::SourceId;

/// Bumped whenever a field changes meaning or is removed.
pub const SCHEMA_VERSION: u32 = 1;

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Row {
    pub source: SourceId,
    /// Local calendar date, `YYYY-MM-DD`, in the report's timezone.
    pub date: String,
    /// `None` for usage the source logs without a model name.
    pub model: Option<String>,
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cache_write_tokens: u64,
    pub cache_read_tokens: u64,
    /// Informational subset of `outputTokens` (Codex only).
    pub reasoning_tokens: u64,
    pub total_tokens: u64,
    /// Known API-equivalent cost. When `missingPricing` is true this is only
    /// the priced part (often 0) and must not be read as a complete cost.
    #[serde(rename = "costUSD")]
    pub cost_usd: f64,
    pub missing_pricing: bool,
    /// The model name was inferred by ccusage rather than logged (Codex).
    pub inferred_model: bool,
}

impl Row {
    fn new(source: SourceId, date: &str, model: Option<String>) -> Self {
        Self {
            source,
            date: date.to_string(),
            model,
            input_tokens: 0,
            output_tokens: 0,
            cache_write_tokens: 0,
            cache_read_tokens: 0,
            reasoning_tokens: 0,
            total_tokens: 0,
            cost_usd: 0.0,
            missing_pricing: false,
            inferred_model: false,
        }
    }

    fn finish(mut self) -> Self {
        self.total_tokens = self
            .input_tokens
            .saturating_add(self.output_tokens)
            .saturating_add(self.cache_write_tokens)
            .saturating_add(self.cache_read_tokens);
        if !self.cost_usd.is_finite() || self.cost_usd < 0.0 {
            self.cost_usd = 0.0;
            self.missing_pricing = true;
        }
        self
    }

    fn is_empty(&self) -> bool {
        self.total_tokens == 0 && self.cost_usd == 0.0
    }
}

/// Claude daily summaries carry per-model breakdowns. Entries logged without
/// a model contribute to the day but to no breakdown; that remainder becomes
/// an unattributed row so the day total is never lost.
pub fn claude_rows(summaries: &[UsageSummary]) -> Vec<Row> {
    let mut rows = Vec::new();
    for summary in summaries {
        let Some(date) = summary.date.as_deref() else {
            continue;
        };
        let mut attributed = Row::new(SourceId::Claude, date, None);
        for breakdown in &summary.model_breakdowns {
            let mut row = Row::new(SourceId::Claude, date, Some(breakdown.model_name.clone()));
            row.input_tokens = breakdown.input_tokens;
            row.output_tokens = breakdown.output_tokens;
            row.cache_write_tokens = breakdown.cache_creation_tokens;
            row.cache_read_tokens = breakdown.cache_read_tokens;
            row.cost_usd = breakdown.cost;
            row.missing_pricing = breakdown.missing_pricing;
            let row = row.finish();
            attributed.input_tokens += row.input_tokens;
            attributed.output_tokens += row.output_tokens;
            attributed.cache_write_tokens += row.cache_write_tokens;
            attributed.cache_read_tokens += row.cache_read_tokens;
            attributed.cost_usd += row.cost_usd;
            if !row.is_empty() {
                rows.push(row);
            }
        }
        let mut rest = Row::new(SourceId::Claude, date, None);
        rest.input_tokens = summary.input_tokens.saturating_sub(attributed.input_tokens);
        rest.output_tokens = summary.output_tokens.saturating_sub(attributed.output_tokens);
        rest.cache_write_tokens = summary
            .cache_creation_tokens
            .saturating_sub(attributed.cache_write_tokens);
        rest.cache_read_tokens = summary
            .cache_read_tokens
            .saturating_sub(attributed.cache_read_tokens);
        let rest_cost = summary.total_cost - attributed.cost_usd;
        // Float noise from summing the same costs in another order is not usage.
        rest.cost_usd = if rest_cost > 1e-9 { rest_cost } else { 0.0 };
        let mut rest = rest.finish();
        // Tokens without a model and without a logged cost cannot be valued.
        rest.missing_pricing = rest.total_tokens > 0 && rest.cost_usd == 0.0;
        if !rest.is_empty() {
            rows.push(rest);
        }
    }
    rows
}

/// Codex daily groups are already split by model, including models ccusage
/// infers for old logs without one (`inferredModel`).
pub fn codex_rows(
    groups: &BTreeMap<String, CodexGroup>,
    pricing: &PricingMap,
    speed: CodexSpeedPolicy,
) -> Vec<Row> {
    let mut rows = Vec::new();
    for (date, group) in groups {
        for (model, usage) in &group.models {
            let mut row = Row::new(SourceId::Codex, date, Some(model.clone()));
            row.input_tokens = non_cached_input_tokens(
                usage.input_tokens,
                usage.cached_input_tokens,
                usage.cache_creation_tokens,
            );
            row.cache_read_tokens = usage.cached_input_tokens;
            row.cache_write_tokens = usage.cache_creation_tokens;
            row.output_tokens = usage.output_tokens;
            row.reasoning_tokens = usage.reasoning_output_tokens;
            row.cost_usd = calculate_codex_model_cost(model, usage, pricing, speed);
            row.missing_pricing = codex_model_missing_pricing(model, usage, pricing);
            row.inferred_model = usage.is_fallback;
            let row = row.finish();
            if !row.is_empty() {
                rows.push(row);
            }
        }
    }
    rows
}

#[cfg(test)]
mod tests {
    use super::*;
    use ccusage_core::ModelBreakdown;

    fn summary(date: &str, input: u64, output: u64, cost: f64) -> UsageSummary {
        UsageSummary {
            date: Some(date.into()),
            month: None,
            week: None,
            session_id: None,
            project_path: None,
            last_activity: None,
            first_activity: None,
            input_tokens: input,
            output_tokens: output,
            cache_creation_tokens: 0,
            cache_read_tokens: 0,
            extra_total_tokens: 0,
            total_cost: cost,
            credits: None,
            message_count: None,
            models_used: vec![],
            model_breakdowns: vec![],
            project: None,
            versions: None,
        }
    }

    fn breakdown(model: &str, input: u64, output: u64, cost: f64, missing: bool) -> ModelBreakdown {
        ModelBreakdown {
            model_name: model.into(),
            input_tokens: input,
            output_tokens: output,
            cost,
            missing_pricing: missing,
            ..ModelBreakdown::default()
        }
    }

    #[test]
    fn claude_remainder_without_model_is_unattributed_and_unpriced() {
        let mut day = summary("2026-03-01", 150, 30, 1.0);
        day.model_breakdowns = vec![breakdown("claude-sonnet-4-5", 100, 20, 1.0, false)];
        let rows = claude_rows(&[day]);
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].model.as_deref(), Some("claude-sonnet-4-5"));
        assert_eq!(rows[1].model, None);
        assert_eq!(rows[1].input_tokens, 50);
        assert_eq!(rows[1].output_tokens, 10);
        assert_eq!(rows[1].total_tokens, 60);
        assert!(rows[1].missing_pricing);
    }

    #[test]
    fn claude_fully_attributed_day_has_no_remainder() {
        let mut day = summary("2026-03-01", 100, 20, 1.0 + 1e-12);
        day.model_breakdowns = vec![breakdown("claude-opus-4-1", 100, 20, 1.0, false)];
        let rows = claude_rows(&[day]);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].total_tokens, 120);
    }

    #[test]
    fn unknown_price_is_flagged_not_silently_zero() {
        let mut day = summary("2026-03-01", 10, 5, 0.0);
        day.model_breakdowns = vec![breakdown("mystery-model", 10, 5, 0.0, true)];
        let rows = claude_rows(&[day]);
        assert_eq!(rows.len(), 1);
        assert!(rows[0].missing_pricing);
        assert_eq!(rows[0].cost_usd, 0.0);
    }

    #[test]
    fn non_finite_cost_becomes_missing_pricing() {
        let mut day = summary("2026-03-01", 10, 5, f64::NAN);
        day.model_breakdowns = vec![breakdown("m", 10, 5, f64::NAN, false)];
        let rows = claude_rows(&[day]);
        assert!(rows.iter().all(|row| row.cost_usd.is_finite()));
        assert!(rows[0].missing_pricing);
    }
}
