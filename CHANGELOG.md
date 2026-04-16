# Changelog

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
