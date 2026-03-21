# cc-statistics

[![PyPI](https://img.shields.io/pypi/v/cc-statistics?color=blue)](https://pypi.org/project/cc-statistics/)
[![Downloads](https://img.shields.io/pypi/dm/cc-statistics?color=green)](https://pypi.org/project/cc-statistics/)
[![GitHub stars](https://img.shields.io/github/stars/androidZzT/cc-statistics?style=social)](https://github.com/androidZzT/cc-statistics)
[![License](https://img.shields.io/github/license/androidZzT/cc-statistics)](LICENSE)

[English](README_EN.md) | 中文

AI Coding 会话统计工具 — 支持 Claude Code / Gemini CLI / Codex / Cursor，从本地数据中提取工程指标。

<img src="docs/screenshot.png" width="420" alt="CC Stats Dashboard">

### CLI Demo

<img src="docs/demo.gif" width="600" alt="CC Stats CLI Demo">

## 核心亮点

- **多数据源** — 支持 Claude Code、Gemini CLI、Codex、Cursor，可切换或聚合统计
- **费用估算** — 内置 Opus / Sonnet / Haiku / Gemini 2.5 Pro / Flash / GPT-4o 等模型定价
- **多维统计** — 指令数、工具调用 Top 10、开发时长（AI vs 用户）、代码变更（按语言）、Token（按模型）
- **每日趋势** — 14 天费用趋势图，直观掌握 AI 使用规律
- **用量预警** — 设置单日/每周费用上限，超限时状态栏变红 + 系统通知
- **周报/月报** — 自动生成 Markdown 统计报告，支持飞书/钉钉/Slack 推送
- **纯本地** — 所有数据读取自本地文件，不联网，不上传
- **三种模式** — CLI 命令行 + Web Dashboard（跨平台）+ macOS 原生状态栏面板
- **双语** — 自动跟随系统语言，支持中文 / English 手动切换

## 会话管理：搜索、恢复、分享

> Claude Code 原生只提供 `claude --resume`（交互式选择器）和 `claude --continue`（续最近一个），**没有内容搜索、没有导出、没有分享**。cc-stats 补齐了这些能力。

### 搜索

按关键词搜索所有历史会话内容，快速定位到目标对话：

```bash
# CLI：按关键词搜索并导出
cc-stats --export-chat "登录bug"
```

macOS 面板内置搜索框，实时过滤会话列表，输入关键词即可匹配对话内容。

### 恢复

找到目标会话后，一键复制 `claude --resume <session-id>` 命令恢复对话：

- **macOS 面板** — 点击会话卡片的「恢复」按钮，命令自动复制到剪贴板，粘贴到终端即可继续
- **CLI** — `--export-chat` 导出的 Markdown 文件头部包含 session ID，配合 `claude --resume` 使用

### 导出 & 分享

将对话导出为可读格式，方便存档或分享给团队：

```bash
# 导出为 Markdown（自动保存到桌面）
cc-stats --export-chat "重构方案"

# 包含工具调用详情
cc-stats --export-chat "重构方案" --include-tools
```

macOS 面板支持选中多条消息，一键生成**分享长图**（PNG），直接发到微信/飞书/Slack。

## 请 cc 吃 Token

如果这个工具对你有帮助，欢迎请 cc 吃点 Token :)

<img src="docs/donate.jpg" width="200" alt="微信赞赏码">

## 安装

```bash
# uv（推荐，速度最快）
uv tool install cc-statistics

# pipx（隔离环境，任意终端可用）
pipx install cc-statistics

# pip
pip install cc-statistics

# Homebrew（macOS / Linux）
brew install androidZzT/tap/cc-statistics  # TODO: 待上架
```

零依赖，纯 Python 标准库。

### 从源码安装（开发用）

```bash
git clone https://github.com/androidZzT/cc-statistics.git
cd cc-statistics
uv sync           # 或 pip install -e .
```

## 使用

### CLI 命令行（全平台）

```bash
cc-stats                     # 分析当前目录的所有会话
cc-stats --list              # 列出所有项目（Claude + Gemini）
cc-stats compose-album       # 按关键词匹配项目
cc-stats --all --since 3d    # 最近 3 天所有项目
cc-stats --all --since 2w    # 最近 2 周
cc-stats sailor --last 3     # 某项目最近 3 个会话
cc-stats --report week       # 生成周报（Markdown）
cc-stats --report month      # 生成月报
cc-stats --compare           # 多项目对比
cc-stats --compare --since 1w # 最近一周项目对比
```

### Webhook 通知（飞书 / 钉钉 / Slack）

将每日统计摘要推送到团队群：

```bash
# 飞书（自动检测）
cc-stats --notify https://open.feishu.cn/open-apis/bot/v2/hook/xxx

# 钉钉
cc-stats --notify https://oapi.dingtalk.com/robot/send?access_token=xxx

# Slack
cc-stats --notify https://hooks.slack.com/services/xxx

# 手动指定平台
cc-stats --notify <url> --platform feishu
```

推送内容包括：指令数、活跃时长、Token、费用、代码变更、效率评分。

配合 cron 实现每日自动推送：

```bash
# 每天 21:00 推送日报到飞书
0 21 * * * cc-stats --notify https://open.feishu.cn/open-apis/bot/v2/hook/xxx
```

### Web Dashboard（全平台：macOS / Windows / Linux）

```bash
cc-stats-web
```

启动后自动打开浏览器，展示暗色主题统计面板：

- 数据源切换：Claude Code / Gemini CLI / All Sources
- 项目选择器 + 时间范围切换（Today / 7d / 30d / All）
- 4 项指标卡片：指令数、工具调用、活跃时长、预估费用
- 每日趋势：14 天费用条形图
- 开发时间：AI 占比环形图 + 时长明细
- 代码变更：Git commit 统计 + 按语言拆分
- Token 用量：按模型堆叠条形图 + 每模型费用
- 工具调用：Top 10 排行

### macOS 状态栏面板（仅 macOS）

```bash
cc-stats-app
```

> 需要 Xcode Command Line Tools（`xcode-select --install`），Swift 组件首次启动自动编译。

**状态栏：**
- Claude logo + 当日 Token 用量 + 预估费用
- 右键菜单切换显示模式（Token+费用 / Token / 费用 / 会话数）
- 超限变红预警

**统计面板（原生 SwiftUI）：**
- 多数据源：Claude Code / Gemini CLI / Codex / Cursor，可切换或聚合展示
- 主题切换：跟随系统 / 深色 / 浅色
- 用量预警：单日/每周费用上限，超限系统通知
- 导出统计数据（JSON / CSV，自动保存到桌面并打开）
- 设置页：开机自启、语言切换、主题切换、版本更新检测
- 会话搜索 + 一键恢复（复制 `claude --resume`）
- 进程管理：查看所有 Claude 进程内存占用
- 工具调用拆分：Skill 和 MCP 工具展开为具体名称
- 全局快捷键 `Cmd+Shift+C`

## 命令总览

| 命令 | 平台 | 说明 |
|------|------|------|
| `cc-stats` | 全平台 | CLI 终端输出 |
| `cc-stats-web` | 全平台 | 浏览器 Web 面板 |
| `cc-stats-app` | 仅 macOS | 原生状态栏面板 |

## 数据来源

所有数据读取自本地文件，不联网，不上传：

| 数据源 | 路径 |
|--------|------|
| Claude Code | `~/.claude/projects/<project>/<session>.jsonl` |
| Gemini CLI | `~/.gemini/tmp/<project>/chats/<session>.json` |
| Codex | `~/.codex/sessions/*.jsonl` |
| Cursor | `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` |
| Git 变更 | 项目目录的 `git log --numstat` |
