# Changelog

## v1.0.4 (2026-06-12)

### Pricing
- Refresh official model pricing for OpenAI, Claude, and Gemini model families.
- Add pricing coverage for newer GPT-5.5, Claude Fable/Mythos/Opus, and Gemini 3.x models.
- Reuse the shared Python pricing matcher in the web API to prevent CLI/Web cost-estimation drift.

## v1.0.3 (2026-06-02)

### Fixes
- Prevent macOS island from showing Permission Request panels when Claude Code runs in bypass permission mode.
- Treat regular `PreToolUse` events as live progress only; approvals now require an explicit `PermissionRequest` or `approval_required=true`.
- Auto-allow anomalous bypass-mode `PermissionRequest` hook events without creating pending approvals.

## v1.0.2 (2026-05-22)

### Fixes
- Fix Claude Code subagent token accounting in CLI and macOS app discovery.
- Keep date-filtered token totals, model breakdown, cost, and rhythm views aligned.
- Fix update detection for installed packages by reading package metadata when source files are unavailable.
- Preserve uv tool and pipx installation managers during app-triggered upgrades.
- Add `cc-stats -v/--version` and `cc-stats-app -v/--version`.

## v1.0.1 (2026-05-08)

### Island
- Add a live bridge client for macOS island task state, including running, approval, completed, failed, and canceled snapshots
- Expand Clawd island animations with thinking, typing, building, juggling, conducting, notification, error, happy, sweeping, carrying, idle, and sleeping motions
- Keep failed/canceled terminal states visible until dismissed so late completion/progress events cannot overwrite errors
- Refine island layout, sizing, outside-click dismissal, and approval controls; remove the orange approval dot from the header

### App & Data
- Improve large-session loading with streaming JSONL reads and lower peak memory usage
- Add cache-efficiency stats and token display support up to billion-scale units
- Improve Codex/Gemini/Cursor parsing, model attribution, and dashboard aggregation paths

### Hooks & Bridge
- Improve Claude Code hook event coverage for live task progress, permission requests, failures, compaction, subagents, and worktree events
- Harden bridge state transitions and approval resolution tests

## v1.0.0 (2026-04-21)

### Major Release
- Ship the first complete `1.0.0` release of CCStats across CLI, macOS app, web dashboard, hooks, and bridge tooling
- Stabilize Claude Code approval workflow with local bridge support, actionable Allow/Deny controls, and better hook coverage
- Add macOS notch-style island overlay with compact/expanded states aligned to the Claude island interaction model

### Performance
- Reduce dashboard memory pressure with streaming-style parsing and progressive rendering for large session histories
- Lazy-load full conversation details only when the conversation panel opens to lower startup overhead

### Data Coverage
- Add Codex session ingestion from `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`
- Improve model attribution, token accounting, and cost estimation for Codex/OpenAI, Claude, and Gemini families

### Sharing
- Rebuild conversation share export on top of HTML + WebKit rendering for sharper PNG/PDF output and more reliable long-content export
- Add preset-specific share themes for different social and communication surfaces

## v0.12.19 (2026-04-17)

### Share Export
- Rebuild conversation share export pipeline with HTML + WebKit rendering (instead of direct SwiftUI snapshot), improving content completeness and stability
- Fix truncated share content and pagination/cropping issues in exported PNG/PDF
- Add preset-specific visual themes (Balanced / X / LinkedIn / Slack / Telegram) with clearly different style languages

### macOS App
- Restore status bar usage text to white for stable readability
- Adjust panel/floating window behavior to avoid interfering with Dock auto-show

### Build
- Link WebKit framework in app compile scripts for local/dev and wheel builds

## v0.12.18 (2026-04-16)

### Pricing
- Recalibrate model pricing with latest official rates for OpenAI, Claude, and Gemini
- Add dedicated pricing matcher for Codex/OpenAI model families (including `gpt-5.3-codex`)
- Unify Python-side cost estimation across reporter/webhook/hooks to avoid drift

### Accuracy
- Improve Claude cache savings estimation by using per-model input vs cache-read price delta
- Keep app-side Swift pricing map aligned with CLI/backend pricing behavior

## v0.12.17 (2026-04-16)

### Performance
- Reduce macOS app memory pressure in parser/analyzer path (streaming-style line parsing, compact tool inputs, lower transient allocations)
- Add progressive loading for dashboard stats: render first batch quickly, then continue background parsing
- Add huge-dataset guardrail: prioritize recent 30-day sessions when file count is very large, then backfill history on demand

### UX
- Make Conversation panel lazy-load full session messages on open to shorten initial dashboard load time

## v0.12.16 (2026-04-16)

### Bug Fixes
- Add Codex sessions support for `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` in CLI/reporter/export/webhook
- Fix Codex parser token attribution and dedup of cumulative `token_count` events
- Fix Codex model attribution from `turn_context.payload.model` (avoid `unknown` model in token breakdown)
- Fix macOS app startup behavior in editable/development mode to recompile Swift sources when changed
- Fix macOS app Codex parser field mapping so Codex token usage is displayed correctly

## v0.12.4 (2026-03-29)

### Bug Fixes
- Fix Swift compilation error: `daySessions` undefined in daily stats calculation (#17)

## v0.12.3 (2026-03-27)

### Bug Fixes
- Fix PyPI package Swift binary version not synced with pyproject.toml (#14)

### New Features
- Cross-midnight session statistics — tokens are attributed by message timestamp date instead of session start date (#15)

## v0.12.2 (2026-03-26)

### Bug Fixes
- Fix status bar Auto Layout infinite loop causing 60%+ CPU usage
- Fix status bar text vertical centering
- Use native UNUserNotificationCenter for test notifications instead of osascript
- Auto-request notification authorization on first send

## v0.12.1 (2026-03-26)

### Bug Fixes
- Fix PyPI package missing Info.plist — pip install users could not compile Swift app locally (#14)
- Fix version mismatch: `__init__.__version__` and Swift `fallbackVersion` now sync with pyproject.toml
- Add `Info.plist` to `[tool.setuptools.package-data]` so it's included in wheel

## v0.12.0 (2026-03-26)

### New Features
- Session completion notification — macOS system notification when Claude Code tasks finish
- Cost alert notification — daily cost threshold warning with configurable limits
- Permission request notification — notify when Claude Code awaits user permission
- Smart notification suppression — auto-suppress when app window is focused
- Webhook support — send notifications to custom HTTP endpoints
- Hooks installation support (`cc-stats-hooks` CLI entry point)

## v0.11.0 (2026-03-25)

### New Features
- Add background version update checker with local cache (CLI, macOS app, web dashboard)
- Display update hint on CLI startup (cache-only, non-blocking)

### Bug Fixes
- Respect `$CODEX_HOME` env var in CodexParser (#5)

### Performance
- Split data loading from filtering + single-pass daily stats (#6)

### Refactoring
- Invalidate cache on refresh to load new session data (#12)

### Documentation
- Add security and performance review guidelines to CLAUDE.md
