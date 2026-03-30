# cc-statistics

[![PyPI](https://img.shields.io/pypi/v/cc-statistics?color=blue)](https://pypi.org/project/cc-statistics/)
[![Downloads](https://img.shields.io/pypi/dm/cc-statistics?color=green)](https://pypi.org/project/cc-statistics/)
[![GitHub stars](https://img.shields.io/github/stars/androidZzT/cc-statistics?style=social)](https://github.com/androidZzT/cc-statistics)
[![License](https://img.shields.io/github/license/androidZzT/cc-statistics)](LICENSE)

English | [中文](README.md)

AI Coding session stats — Claude Code / Gemini CLI / Codex / Cursor, all from local files.

<img src="docs/screenshot.png" width="420" alt="CC Stats Dashboard">

### CLI Demo

<img src="docs/demo.gif" width="600" alt="CC Stats CLI Demo">

## Installation

```bash
# uv (recommended, fastest)
uv tool install cc-statistics

# pipx
pipx install cc-statistics

# Homebrew (macOS / Linux)
brew install androidZzT/tap/cc-statistics
```

Zero dependencies — Python stdlib only.

## Key Features

- **Clawd Status Bar Animation** — Real-time AI work state awareness with pixel-art animations that auto-switch as Claude runs/pauses/finishes
- **Multi-Source** — Claude Code, Gemini CLI, Codex, Cursor — switch or aggregate stats across all sources
- **macOS Native Menu Bar** — Pre-built binary, no local compilation; Claude logo + Token + Cost, turns red when over limit
- **Cost Estimation** — Built-in pricing for Opus / Sonnet / Haiku / Gemini 2.5 Pro / Flash / GPT-4o
- **Usage Alerts** — Daily/weekly cost limits with system notifications when exceeded
- **Session Search / Resume / Export** — Search past conversations by keyword, one-click resume command, export Markdown / share as image
- **Weekly / Monthly Reports** — Auto-generate Markdown reports, push to Feishu / DingTalk / Slack via Webhook
- **Multi-dimensional Stats** — Instructions, Tool calls Top 10, AI vs User time, Code changes (by language), Tokens (by model)
- **100% Local** — All data read from local files, nothing sent over the network
- **Bilingual** — Auto-follows system language, supports manual Chinese / English switch

## Usage

### CLI (All Platforms)

```bash
cc-stats                     # Analyze current directory sessions
cc-stats --list              # List all projects (Claude + Gemini)
cc-stats --all --since 3d    # Last 3 days, all projects
cc-stats sailor --last 3     # Last 3 sessions for a project
cc-stats --report week       # Generate weekly report (Markdown)
cc-stats --compare --since 1w # Compare projects (last week)
cc-stats --notify https://hooks.slack.com/services/xxx  # Webhook push
```

### Web Dashboard (All Platforms)

```bash
cc-stats-web
```

Auto-opens browser with a dark-themed statistics dashboard.

### macOS Menu Bar Panel

```bash
cc-stats-app
```

**Status Bar:**
- Claude logo + today's token usage + estimated cost
- Right-click to switch display mode (Token+Cost / Token / Cost / Sessions)
- Turns red when over limit

**Dashboard Panel (Native SwiftUI):**
- Multi-source: Claude Code / Gemini CLI / Codex / Cursor, switch or aggregate
- Theme: Follow System / Dark / Light
- Usage alerts: daily/weekly cost limits with system notifications
- Export stats to JSON / CSV (auto-saves to Desktop)
- Settings: Launch at login, language switch, theme, version update check
- Session search + one-click resume (`claude --resume`)
- Process manager: view all Claude process memory usage
- Tool call breakdown: Skill and MCP tools expanded to specific names
- Global hotkey `Cmd+Shift+C`

## Data Sources

All data is read from local files. Nothing is sent over the network.

| Source | Path |
|--------|------|
| Claude Code | `~/.claude/projects/<project>/<session>.jsonl` |
| Gemini CLI | `~/.gemini/tmp/<project>/chats/<session>.json` |
| Codex | `~/.codex/sessions/*.jsonl` |
| Cursor | `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` |
| Git Changes | `git log --numstat` in project directory |

## Acknowledgments

- Status bar Clawd animation sprites from [clawd-on-desk](https://github.com/rullerzhou-afk/clawd-on-desk) — an Electron desktop pet that senses AI coding agent state via hooks and plays pixel-art animations.

## Buy cc Some Tokens

If this tool helps you, feel free to buy cc some tokens :)

<img src="docs/donate.jpg" width="200" alt="WeChat Donation">
