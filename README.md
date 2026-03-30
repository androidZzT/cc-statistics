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

## 安装

```bash
# uv（推荐，速度最快）
uv tool install cc-statistics

# pipx（隔离环境，任意终端可用）
pipx install cc-statistics

# Homebrew（macOS / Linux）
brew install androidZzT/tap/cc-statistics
```

零依赖，纯 Python 标准库。

## 核心功能

- **Clawd 状态栏动画** — 实时感知 AI 工作状态，像素风动画随 Claude 任务运行/暂停/完成自动切换
- **多数据源** — 支持 Claude Code、Gemini CLI、Codex、Cursor，可切换或聚合统计
- **macOS 原生状态栏** — 预编译二进制，无需本地编译；Claude logo + Token + 费用，超限变红预警
- **费用估算** — 内置主流模型定价（Opus / Sonnet / Haiku / Gemini 2.5 Pro / Flash / GPT-4o）
- **用量预警** — 单日/每周费用上限，超限系统通知
- **会话搜索 / 恢复 / 导出** — 按关键词搜索历史对话，一键复制恢复命令，导出 Markdown / 分享长图
- **周报 / 月报** — 自动生成 Markdown 报告，支持飞书 / 钉钉 / Slack Webhook 推送
- **多维统计** — 指令数、工具调用 Top 10、AI vs 用户时长、代码变更（按语言）、Token（按模型）
- **纯本地** — 所有数据读取自本地文件，不联网，不上传
- **双语** — 自动跟随系统语言，支持中文 / English 手动切换

## 使用

### CLI 命令行（全平台）

```bash
cc-stats                     # 分析当前目录的所有会话
cc-stats --list              # 列出所有项目（Claude + Gemini）
cc-stats --all --since 3d    # 最近 3 天所有项目
cc-stats sailor --last 3     # 某项目最近 3 个会话
cc-stats --report week       # 生成周报（Markdown）
cc-stats --compare --since 1w # 最近一周项目对比
cc-stats --notify https://hooks.slack.com/services/xxx  # Webhook 推送
```

### Web Dashboard（全平台）

```bash
cc-stats-web
```

自动打开浏览器，展示暗色主题统计面板。

### macOS 状态栏面板

```bash
cc-stats-app
```

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

## 数据来源

所有数据读取自本地文件，不联网，不上传：

| 数据源 | 路径 |
|--------|------|
| Claude Code | `~/.claude/projects/<project>/<session>.jsonl` |
| Gemini CLI | `~/.gemini/tmp/<project>/chats/<session>.json` |
| Codex | `~/.codex/sessions/*.jsonl` |
| Cursor | `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` |
| Git 变更 | 项目目录的 `git log --numstat` |

## 致谢

- 状态栏 Clawd 动画素材来自 [clawd-on-desk](https://github.com/rullerzhou-afk/clawd-on-desk) — 一个 Electron 桌面宠物应用，通过 hook 系统实时感知 AI coding agent 的工作状态并播放像素风动画。

## 请 cc 吃 Token

如果这个工具对你有帮助，欢迎请 cc 吃点 Token :)

<img src="docs/donate.jpg" width="200" alt="微信赞赏码">
