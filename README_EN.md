# cc-statistics

Claude Code session statistics tool — extract AI coding metrics from local `~/.claude/` data.

<img src="docs/screenshot.png" width="420" alt="CC Stats Dashboard">

## Highlights

- **Cost Estimation** — Auto-calculate daily/per-project costs based on Opus / Sonnet / Haiku pricing, shown in real-time on status bar
- **Session Search & Resume** — Search past conversations by keyword, click to copy `claude --resume` command and instantly restore any session
- **Multi-dimensional Stats** — Instructions, Tool calls Top 10, Dev time (AI vs User), Code changes (by language), Token usage (by model)
- **Daily Trend** — 14-day cost trend chart to spot usage patterns
- **100% Local** — All data read from local files, nothing uploaded
- **Dual Mode** — CLI command line + macOS native SwiftUI menu bar panel
- **Bilingual** — Auto-follows system language, supports manual Chinese / English switch

## Installation

```bash
# Recommended: pipx for global install
pipx install cc-statistics

# Or via pip
pip install cc-statistics
```

The CLI tool (`cc-stats`) has zero dependencies — Python stdlib only.

### From Source

```bash
git clone https://github.com/androidZzT/cc-statistics.git
cd cc-statistics
python3 -m venv .venv
source .venv/bin/activate
pip install -e .
```

## Usage

### CLI

```bash
cc-stats                     # Analyze current directory sessions
cc-stats --list              # List all projects
cc-stats compose-album       # Match project by keyword
cc-stats --all --since 3d    # Last 3 days, all projects
cc-stats --all --since 2w    # Last 2 weeks
cc-stats sailor --last 3     # Last 3 sessions for a project
```

### macOS Menu Bar Panel

```bash
cc-stats-app
```

> Requires macOS + Xcode Command Line Tools (`xcode-select --install`). Swift component auto-compiles on first launch.

**Status Bar:**
- Claude logo + today's token usage + estimated cost
- Right-click to switch display mode (Token+Cost / Token / Cost / Sessions)
- Launch at login support

**Dashboard Panel:**
- Project selector + time range filter (Today / Week / Month / All)
- 4 stat cards: Sessions, Instructions, Duration, Estimated Cost
- Daily trend: 14-day cost bar chart
- Dev time: AI ratio ring + time breakdown
- Code changes: Git commits + per-language breakdown
- Token usage: stacked bar by model + per-model cost
- Tool calls: Top 10 ranking

**Session Management:**
- Search past sessions by content
- Click to copy `claude --resume` command
- View full conversation history

**More:**
- Global hotkey `Cmd+Shift+C`
- Export stats to JSON / CSV (auto-saves to Desktop)
- Settings: Launch at login, language switch
- Click outside to dismiss (with animation)

## Data Sources

All data is read from local `~/.claude/` files. Nothing is sent over the network.

| Data | Source |
|------|--------|
| Session messages | `~/.claude/projects/<project>/<session>.jsonl` |
| Tool calls | `tool_use` blocks in assistant messages |
| Token usage | `usage` field in assistant messages |
| Git changes | `git log --numstat` in project directory |

## Buy cc Some Tokens

If this tool helps you, feel free to buy cc some tokens :)

<img src="docs/donate.jpg" width="200" alt="WeChat Donation">
