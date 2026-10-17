# Third-party notices

Burnless includes or adapts the following MIT-licensed work.

## ccusage

Used as a Cargo dependency (crates `ccusage-core`, `ccusage-adapter-claude`,
`ccusage-adapter-codex` and their workspace dependencies), pinned to revision
`57e5658dcac4de42f50d059b62cddc1fec9bbdc9` of https://github.com/ccusage/ccusage.
The engine binary statically links this code. ccusage also embeds its own
models.dev pricing snapshot from that revision.

```
MIT License

Copyright (c) 2025 ryoppippi

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Agent Burn

Burnless's dashboard layout, card/metric/share-bar components (`Theme.swift`),
spend histogram (`SpendChart.swift`) and model table follow and adapt code from
https://github.com/Melvynx/agent-burn at revision
`9ce6d8e1f9ae4bfb3ca62a2d3fee6cd831171105`, mainly
`apps/macos/Sources/AgentBurn/{NativeUsageView,Theme,Usage}.swift`.

```
MIT License

Copyright (c) 2025 ryoppippi
Copyright (c) 2026 Melvynx

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## LiteLLM pricing data

`engine/pricing/litellm-model-prices.json` is LiteLLM's
`model_prices_and_context_window.json` at revision
`1fd7f81f97cffec77621964ba18998b224281726`
(https://github.com/BerriAI/litellm). Its license is in
`engine/pricing/LITELLM-LICENSE.txt` (MIT outside `enterprise/`).

## Rust crates

The engine's other Rust dependencies (serde, serde_json, jiff, zstd, and the
transitive crates locked in `engine/Cargo.lock`) are distributed under MIT
and/or Apache-2.0 licenses. Run `cargo metadata --manifest-path engine/Cargo.toml`
for the complete list.

## Provider logos

`app/Sources/Burnless/Resources/Brands/{claude,codex}.png` come from Agent Burn,
which exported them from the installed Claude and ChatGPT macOS apps. They belong
to Anthropic and OpenAI respectively and only identify the supported
integrations; no endorsement is implied.
