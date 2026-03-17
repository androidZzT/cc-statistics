# cc-statistics

A CLI tool that extracts AI coding engineering metrics from local `~/.claude/` Claude Code session data.

## Metrics

| # | Metric | Description |
|---|--------|-------------|
| ① | User Instructions | Conversation turns (excluding tool results and system messages) |
| ② | AI Tool Calls | Total count + per-tool breakdown (with bar chart and descriptions) |
| ③ | Dev Duration | Total / AI processing / User active / Activity rate / Avg turn time |
| ④ | Code Changes | Git committed changes + AI tool changes (Edit/Write), split by language |
| ⑤ | Token Usage | input / output / cache, split by model |

### Duration Calculation

Sessions are split into **conversation turns** (user message → AI processing → AI response):

- **AI Processing**: Time from user message to AI's last response per turn
- **User Active**: Gap between previous AI response and next user message (gaps > 5 min are treated as idle)
- **Active Duration** = AI Processing + User Active

### Code Change Sources

- **Git Committed**: All commits within the session time range via `git log --numstat` (includes both user and AI commits)
- **AI Tool Changes**: Extracted from `Edit`/`Write` tool call parameters in JSONL (AI-side only)

## Installation

```bash
# Recommended: pipx for global install (isolated env, available in any terminal)
pipx install cc-statistics

# Or via pip
pip install cc-statistics
```

Zero dependencies — Python stdlib only.

### From Source (development)

```bash
git clone https://github.com/androidZzT/cc-statistics.git
cd cc-statistics
python3 -m venv .venv
source .venv/bin/activate
pip install -e .
```

## Usage

```bash
# List all projects
cc-stats --list

# Analyze all sessions for current directory
cc-stats

# Match project by keyword
cc-stats compose-album

# Analyze a specific project directory
cc-stats /path/to/project

# Analyze a specific JSONL file
cc-stats ~/.claude/projects/-Users-foo-bar/SESSION_ID.jsonl

# Only the last N sessions
cc-stats compose-album --last 3

# Time range filters
cc-stats --all --since 3d           # Last 3 days
cc-stats --all --since 2w           # Last 2 weeks
cc-stats --all --since 1h           # Last 1 hour
cc-stats --all --since 2026-03-01 --until 2026-03-15  # Date range
cc-stats sailor --since 2026-03-13T10:00               # Down to the minute
```

## Sample Output

```
╔══════════════════════════════════════════════════════════╗
║        Claude Code Session Statistics                   ║
╚══════════════════════════════════════════════════════════╝

  Sessions: 3
  Time Range: 2026-03-13 15:24 ~ 2026-03-14 22:16

  ① User Instructions
────────────────────────────────────────────────────────────
  Turns: 58

  ② AI Tool Calls
────────────────────────────────────────────────────────────
  Total: 336

  Bash        ███████████████    90  Run shell commands
  Read        ██████████░░░░░    61  Read file contents
  Edit        █████████░░░░░░    56  Edit file (exact replace)
  TaskUpdate  ███████░░░░░░░░    44  Update task status
  Agent       ████░░░░░░░░░░░    24  Launch sub-agent
  Grep        ████░░░░░░░░░░░    24  Search file contents
  TaskCreate  ██░░░░░░░░░░░░░    17  Create task

  ③ Dev Duration
────────────────────────────────────────────────────────────
  Total:          30h 51m 52s
  Active:         2h 13m 5s
    AI Processing:  1h 42m 42s
    User Active:    30m 22s
  Activity Rate:  7%
  AI Share:       77%
  Avg Turn Time:  2m 13s/turn (46 turns)

  ④ Code Changes
────────────────────────────────────────────────────────────
  [Git Committed]  60 commits
  Added: +30342  Removed: -18228  Net: +12114

  Kotlin    +11472  -1894   net +9578
  Markdown  +490    -50     net +440

  [AI Tool Changes]  from Edit/Write calls
  Added: +1538  Removed: -315  Net: +1223

  Kotlin    +810    -196    net +614
  Markdown  +591    -43     net +548
  Swift     +137    -76     net +61

  ⑤ Token Usage
────────────────────────────────────────────────────────────
  Input tokens:                 924
  Output tokens:              98.0K
  Cache read tokens:          53.6M
  Cache creation tokens:     814.3K
  ────────────────────────────────────────
  Total:                      54.6M

  By model:
    claude-opus-4-6: input=924 output=98.0K cache_read=53.6M total=54.6M
```

## Data Sources

All data is read from local `~/.claude/` files. Nothing is sent over the network.

| Data | Source |
|------|--------|
| Session messages | `~/.claude/projects/<project>/<session>.jsonl` |
| Tool calls | `tool_use` blocks in assistant messages |
| Token usage | `usage` field in assistant messages |
| Git changes | `git log --numstat` in project directory |
