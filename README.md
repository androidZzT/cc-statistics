<div align="center">
  <img src="docs/desktop_now.png" width="480" alt="cc-statistics macOS App" style="border-radius: 16px;">
  <h1>cc-statistics</h1>
  <p><strong>The only AI coding tracker that unifies Claude Code, Gemini CLI, Codex CLI, and Cursor — in one native macOS app.</strong></p>
  <p><em>Track every token, cost, and session across all your AI tools. 100% local. Zero dependencies.</em></p>

  <p>
    <a href="https://pypi.org/project/cc-statistics/"><img src="https://img.shields.io/pypi/v/cc-statistics?color=blue&style=flat-square&logo=python" alt="PyPI"></a>
    <a href="https://pypi.org/project/cc-statistics/"><img src="https://img.shields.io/pypi/dm/cc-statistics?color=green&style=flat-square" alt="Downloads"></a>
    <a href="https://github.com/androidZzT/cc-statistics/stargazers"><img src="https://img.shields.io/github/stars/androidZzT/cc-statistics?style=flat-square" alt="Stars"></a>
    <a href="LICENSE"><img src="https://img.shields.io/github/license/androidZzT/cc-statistics?style=flat-square" alt="License"></a>
    <img src="https://img.shields.io/badge/zero--dependencies-stdlib%20only-orange?style=flat-square" alt="Zero Dependencies">
    <img src="https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20Windows-lightgrey?style=flat-square" alt="Platform">
  </p>

  <p>
    <a href="#-why-cc-statistics">Why?</a> &bull;
    <a href="#-features">Features</a> &bull;
    <a href="#%EF%B8%8F-screenshots">Screenshots</a> &bull;
    <a href="#-quick-start">Quick Start</a> &bull;
    <a href="#-cli-reference">CLI</a> &bull;
    <a href="README_CN.md">中文</a>
  </p>
</div>

---

## 🤔 Why cc-statistics?

You're using multiple AI coding tools. But do you actually know:

- 💸 **What your combined spend is** across Claude Code, Gemini CLI, Codex, and Cursor?
- 🔧 **Which MCP tools are being called most** — and whether they're worth the tokens?
- ⏱️ **How much time Claude is actually working** versus waiting for you?
- 📈 **Which projects are consuming the most** — and across which models?

Most tools only answer this for Claude Code. cc-statistics answers it for all four.

### How does it compare?

| | cc-statistics | CCDash | claude-usage | ccflare |
|---|:---:|:---:|:---:|:---:|
| **Claude Code** | ✅ | ✅ | ✅ | ✅ |
| **Gemini CLI** | ✅ | ❌ | ❌ | ❌ |
| **Codex CLI** | ✅ | ❌ | ❌ | ❌ |
| **Cursor** | ✅ | ❌ | ❌ | ❌ |
| **Native macOS App** | ✅ | ❌ | ❌ | ❌ |
| **Pixel-Art Mascot (Clawd)** | ✅ | ❌ | ❌ | ❌ |
| **Session Search & Resume** | ✅ | ✅ | ❌ | ❌ |
| **Weekly / Monthly Reports** | ✅ | ✅ | ❌ | ❌ |
| **Webhook** (Slack / Feishu / DingTalk) | ✅ | ✅ Slack/Discord | ❌ | ❌ |
| **Tool Call Analytics** | ✅ | ✅ | ❌ | ❌ |
| **Code Changes by Language** | ✅ | ❌ | ❌ | ❌ |
| **AI vs User Time** | ✅ | ❌ | ❌ | ❌ |
| **Usage Alerts** | ✅ | ✅ | ❌ | ❌ |
| **Usage Quota Predictor** | ✅ | ✅ | ❌ | ❌ |
| **Share Session Messages** | ✅ | ❌ | ❌ | ❌ |
| **Web Dashboard** | ✅ | ✅ | ✅ | ✅ |
| **CLI Tool** | ✅ | ✅ | ❌ | ✅ |
| **Zero Dependencies** | ✅ | ✅ | ❌ | ❌ |
| Cache Efficiency Grade | ⏳ planned | ✅ | ❌ | ❌ |
| Live Stream | ⏳ planned | ✅ | ❌ | ❌ |

> cc-statistics is a community project, not affiliated with Anthropic, Google, or OpenAI.

---

## 🚀 Features

### 🌐 4-Platform Unified View
> Claude Code · Gemini CLI · Codex CLI · Cursor — switch between platforms or aggregate all four into a single report. Each source is read entirely from local files; no API keys, no accounts, no network requests.

### 🖥️ Native macOS Menu Bar App
> Pre-built SwiftUI binary — launch with `cc-stats-app` and it lives in your menu bar permanently. Shows Claude logo + today's token count + estimated cost at a glance. Turns **red** when you hit your daily usage quota. Right-click to switch display modes. Global hotkey `Cmd+Shift+C` opens the full dashboard from anywhere.

### 🏝️ Claude-Style Island Overlay
> A notch-aware island overlay for macOS that surfaces Claude Code activity and permission requests in compact and expanded states. Review approvals, jump into chat context, and keep the flow visible without constantly context-switching back to the terminal.

### 🐾 Clawd — Pixel-Art Status Bar Mascot
> A pixel-art Clawd mascot reacts to Claude Code's agent state in real time: idle, thinking, typing, happy, sleeping, and error — each with its own animated sprite. Built on [clawd-on-desk](https://github.com/rullerzhou-afk/clawd-on-desk) hook integration.

<img src="docs/clawd-states.png" width="600" alt="Clawd Animation States">

### 📊 Usage Quota Predictor
> Real-time prediction of when you'll hit your usage quota based on current burn rate. Displays estimated time remaining, projected reset time, and risk level — so you can pace your usage and avoid unexpected throttling.

### 🔍 Session Search & Resume
> Search your entire session history by keyword across all platforms. Results show timestamps and a ready-to-run resume command — one copy-paste and you're back in context:
> ```bash
> claude --resume <session-id>
> ```

### 💬 Share Session Messages
> Export and share individual session conversations as clean, formatted text — useful for documenting AI-assisted work, sharing context with teammates, or archiving important sessions.

### 📊 Multi-Dimensional Analytics
> Instructions count · Tool calls Top 10 (Skill and MCP tools broken out by name) · AI processing time vs user active time · Code changes by language (via `git log --numstat`) · Token breakdown by model · Cost estimation with built-in pricing for Opus / Sonnet / Haiku / Gemini 2.5 Pro / Flash / GPT-4o

### 🔔 Usage Alerts
> Set daily and weekly cost limits. When you're over threshold, the macOS menu bar icon turns red and a native system notification fires — respecting your Focus modes, no app in foreground required.

### 📋 Weekly & Monthly Reports
> Auto-generate Markdown summaries for any period: total tokens, cost by model, most active projects, top tool calls, code changes by language. Push directly to your team channel:
> ```bash
> cc-stats --report week
> cc-stats --notify https://hooks.slack.com/services/xxx
> ```
> Slack, Feishu, and DingTalk webhooks all supported.

### ⚡ Project Comparison
> See which projects are consuming the most resources side by side:
> ```bash
> cc-stats --compare --since 1w
> ```

### 🌐 Web Dashboard
> Browser-based dark-themed dashboard for all platforms — useful on Linux/Windows or when you want a larger view than the menu bar panel.

### 🔒 100% Local & Zero Dependencies
> All data is read from local files. Nothing is sent over the network. Pure Python standard library — no `pip install`, no npm, no Docker.

---

## 🖼️ Screenshots

<table>
  <tr>
    <td align="center"><strong>🖥️ macOS App — Dark Mode</strong></td>
    <td align="center"><strong>🖥️ macOS App — Light Mode</strong></td>
  </tr>
  <tr>
    <td><img src="docs/screenshots/cc-stat-dark.png" alt="macOS App Dark" width="100%"></td>
    <td><img src="docs/screenshots/cc-stat-light.png" alt="macOS App Light" width="100%"></td>
  </tr>
  <tr>
    <td align="center"><strong>📊 Usage Quota Predictor</strong></td>
    <td align="center"><strong>🔴 Max Usage Reached</strong></td>
  </tr>
  <tr>
    <td><img src="docs/screenshots/cc-stat-predict.png" alt="Usage Quota Predictor" width="100%"></td>
    <td><img src="docs/screenshots/cc-stat-max-usage.png" alt="Max Usage" width="100%"></td>
  </tr>
  <tr>
    <td align="center"><strong>🔍 Session List</strong></td>
    <td align="center"><strong>🔧 Tool Call Analytics</strong></td>
  </tr>
  <tr>
    <td><img src="docs/screenshots/cc-stat-sessions.png" alt="Session List" width="100%"></td>
    <td><img src="docs/screenshots/cc-stat-tools.png" alt="Tool Call Analytics" width="100%"></td>
  </tr>
  <tr>
    <td align="center"><strong>⚡ Skill / MCP Analytics</strong></td>
    <td align="center"><strong>💬 Share Session Messages</strong></td>
  </tr>
  <tr>
    <td><img src="docs/screenshots/cc-stat-skill.png" alt="Skill Analytics" width="100%"></td>
    <td><img src="docs/screenshots/cc-stat-share-msgs.png" alt="Share Messages" width="100%"></td>
  </tr>
  <tr>
    <td align="center"><strong>🌐 4-Platform Unified View</strong></td>
    <td align="center"><strong>⚙️ Settings</strong></td>
  </tr>
  <tr>
    <td><img src="docs/screenshots/cc-stat-multiplatform.png" alt="Multi-Platform" width="100%"></td>
    <td><img src="docs/screenshots/cc-stat-settings.png" alt="Settings" width="100%"></td>
  </tr>
  <tr>
    <td align="center"><strong>🔔 Notifications</strong></td>
    <td align="center"><strong>🌐 Web Dashboard</strong></td>
  </tr>
  <tr>
    <td><img src="docs/screenshots/cc-stat-notification.png" alt="Notifications" width="100%"></td>
    <td><img src="docs/screenshots/cc-stat-web.png" alt="Web Dashboard" width="100%"></td>
  </tr>
</table>

### CLI Demo

<img src="docs/screenshots/cc-stat-cli.png" width="680" alt="CC Stats CLI Demo">

---

## ⚡ Quick Start

### Prerequisites

- Python 3.8+
- At least one of: Claude Code CLI, Gemini CLI, Codex CLI, or Cursor installed and used

### 3 steps

```bash
# 1. Install
uv tool install cc-statistics   # or: pipx install cc-statistics

# 2. Run your first report (all platforms, last 7 days)
cc-stats --all --since 7d

# 3. Launch macOS menu bar app (macOS only)
cc-stats-app
```

That's it. No configuration file needed.

**Alternative install methods:**

```bash
# pipx
pipx install cc-statistics

# Homebrew (macOS / Linux)
brew install androidZzT/tap/cc-statistics
```

---

## 📖 CLI Reference

```bash
cc-stats                      # Analyze current directory sessions
cc-stats --list               # List all detected projects (all platforms)
cc-stats --all --since 3d     # Last 3 days, all projects, all platforms
cc-stats --all --since 1w     # Last week
cc-stats myproject --last 3   # Last 3 sessions for a specific project
cc-stats --report week        # Generate weekly Markdown report
cc-stats --report month       # Generate monthly Markdown report
cc-stats --compare --since 1w # Side-by-side project comparison
cc-stats --notify <url>       # Push report to Slack / Feishu / DingTalk webhook
cc-stats-web                  # Open web dashboard in browser
cc-stats-app                  # Launch macOS menu bar app
```

---

## 🗂️ Data Sources

All data is read from local files. Nothing is sent over the network.

| Source | Local path |
|--------|-----------|
| Claude Code | `~/.claude/projects/<project>/<session>.jsonl` |
| Gemini CLI | `~/.gemini/tmp/<project>/chats/<session>.json` |
| Codex CLI | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` |
| Cursor | `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` |
| Git Changes | `git log --numstat` in project directory |

> **Source coverage notes:**
> - **Skill / MCP Analytics** is Claude Code-specific (Codex/Gemini do not expose a `Skill` tool wrapper).
> - **Usage Quota Forecast** stacks every applicable rolling window in one section: Claude 5-min (output tokens, calibrated to Claude Pro tiers), Codex 5h, and Codex 7d. For Codex windows, the report **prefers the real subscription `used_percent` that Codex CLI cached from OpenAI's backend** (extracted from `event_msg / token_count.rate_limits` in the JSONL — no API call required); if a session has no snapshot it falls back to a local estimate based on token count and per-model pricing.
> - **Git cost attribution** (`--git`) prices each commit window using the actual model that produced the tokens (Claude / Codex / Gemini); sessions without a recorded model fall back to Claude Sonnet pricing.

---

## Acknowledgments

Status bar Clawd animation sprites from [clawd-on-desk](https://github.com/rullerzhou-afk/clawd-on-desk) — an Electron desktop pet that senses AI coding agent state via hooks and plays pixel-art animations.

Special thanks to [Farouq Aldori](https://github.com/farouqaldori) and the [claude-island / vibe-notch](https://github.com/farouqaldori/vibe-notch) project for the inspiration behind the macOS notch island interaction model, compact/expanded motion language, and approval-panel design direction.

---

## Support

If cc-statistics saves you money on your AI coding bills, consider [sponsoring](https://github.com/sponsors/androidZzT) the project.
