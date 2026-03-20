# Launch Posts

## Hacker News (Show HN)

**Title:**
Show HN: cc-statistics – Track your Claude Code usage, costs and productivity locally

**Text:**
I built cc-statistics to answer a simple question: how much code is Claude actually writing for me, and what's it costing?

It reads the JSONL session files from ~/.claude/ locally (nothing uploaded) and gives you:

- Token usage & cost estimation (by model: Opus/Sonnet/Haiku)
- Code changes by language (from git commits + Edit/Write tool calls)
- AI vs human time breakdown
- Efficiency score (code output per token spent)
- Weekly/monthly reports in Markdown
- Multi-project comparison

Three modes: CLI (`cc-stats`), Web dashboard (`cc-stats-web`), and a native macOS menu bar panel (`cc-stats-app`) built in SwiftUI.

Some fun stats from my own usage: Claude wrote 100% of the git commits in this project (all detected via Co-Authored-By markers), and I'm spending ~$300/day on Opus.

Zero dependencies (Python stdlib only). pip install cc-statistics

GitHub: https://github.com/androidZzT/cc-statistics

---

## Reddit r/ClaudeAI

**Title:**
I built a tool to track exactly how much code Claude Code writes for me (and how much it costs)

**Body:**
After using Claude Code heavily for a few weeks, I wanted to know:
- How many tokens am I actually burning?
- How much code is Claude writing vs me?
- What's my daily/weekly cost?

So I built **cc-statistics** — a local-only tool that reads your `~/.claude/` session files and gives you detailed metrics.

**What it shows:**
- 📊 Token usage by model (Opus/Sonnet/Haiku) with cost estimation
- 💻 Code changes by language (from git + AI tool calls)
- ⏱️ Active time breakdown (AI processing vs your thinking time)
- 📈 Daily trend charts
- 🏆 Efficiency score (how much code per token spent)
- 📋 Weekly/monthly Markdown reports

**Three modes:**
- `cc-stats` — CLI terminal output
- `cc-stats-web` — browser dashboard (works on Windows/Linux too)
- `cc-stats-app` — native macOS menu bar panel (SwiftUI)

**Privacy:** Everything runs locally. No data leaves your machine.

**Install:** `pip install cc-statistics`

**GitHub:** https://github.com/androidZzT/cc-statistics

Some of my stats this week: 500+ instructions, $1800 in tokens, 37K lines of code added. Claude wrote 100% of the commits 😅

Would love feedback! What metrics would you want to see?

---

## Reddit r/commandline

**Title:**
cc-stats: CLI tool to analyze your Claude Code sessions (tokens, costs, code output)

**Body:**
Built a CLI tool that parses Claude Code's local JSONL session files and gives you engineering metrics.

```
$ cc-stats --compare --since 1w
  Project          Sessions  Instructions  Active Time   Token     Cost      Code
  cc-statistics         2       362        16h 45m       915M     $1673     +28K/-9K
  compose-album         4        90        12h 30m       124M      $254     +6K/-1K
  ...
```

Features:
- `cc-stats --last N` — analyze recent sessions
- `cc-stats --compare` — compare all projects side by side
- `cc-stats --report week` — Markdown weekly report
- `cc-stats --notify <webhook>` — push daily stats to Slack/Feishu/DingTalk

Zero dependencies, Python stdlib only. Also has a web dashboard and macOS native panel.

`pip install cc-statistics`

GitHub: https://github.com/androidZzT/cc-statistics

---

## Product Hunt

**Tagline:**
Track your Claude Code usage, costs, and AI coding productivity — 100% locally

**Description:**
cc-statistics analyzes your Claude Code sessions from local files to show you exactly how much AI is coding for you.

🔍 **What you get:**
- Token consumption & cost estimation by model
- Code changes by language from git + AI tools
- AI vs human time breakdown
- Efficiency scoring (S/A/B/C/D grade)
- Weekly/monthly reports
- Multi-project comparison

🖥️ **Three modes:**
- CLI for terminal lovers
- Web dashboard for cross-platform
- Native macOS menu bar panel (SwiftUI)

🔒 **100% local** — reads ~/.claude/ files, nothing uploaded

📦 **Zero dependencies** — just `pip install cc-statistics`
