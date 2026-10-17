# Pricing snapshot

`litellm-model-prices.json` is LiteLLM's `model_prices_and_context_window.json` at
revision `1fd7f81f97cffec77621964ba18998b224281726` (committed 2026-10-17), the same
revision the pinned ccusage commit (`57e5658`) locks in its `flake.lock`.

- Source: https://github.com/BerriAI/litellm/blob/1fd7f81f97cffec77621964ba18998b224281726/model_prices_and_context_window.json
- SHA-256: `e28c17a093ce39e8bce119ba6dcf5630f2f2d1167a70147532cff73720a64e26`
- License: MIT (see `LITELLM-LICENSE.txt`)

`ccusage-core`'s build script embeds it into `burnless-engine` through
`CCUSAGE_PRICING_JSON_PATH` (set in `engine/.cargo/config.toml`), so the app prices
usage fully offline. ccusage also embeds its own models.dev snapshot from the
pinned source tree for long-context rates and fallbacks.

To update: fetch the file at the revision listed in the new ccusage `flake.lock`,
replace it here, update the revision/date constants in `engine/src/main.rs`, and
rebuild.
