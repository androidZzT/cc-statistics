# Changelog

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
