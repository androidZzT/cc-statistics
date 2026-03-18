# cc-statistics

Claude Code 会话统计工具 — 从本地 `~/.claude/` 数据中提取 AI Coding 工程指标。

<img src="docs/screenshot.png" width="420" alt="CC Stats Dashboard">

## 核心亮点

- **费用估算** — 根据 Opus / Sonnet / Haiku 定价自动计算每日、每项目的预估花费，状态栏实时展示
- **会话搜索 & 恢复** — 搜索历史会话内容，点击即可复制 `claude --resume` 命令，一键恢复之前的对话
- **多维统计** — 指令数、工具调用 Top 10、开发时长（AI vs 用户）、代码变更（按语言拆分）、Token 消耗（按模型拆分）
- **每日趋势** — 14 天费用趋势图，直观掌握 AI 使用规律
- **纯本地** — 所有数据读取自本地文件，不联网，不上传
- **双模式** — CLI 命令行 + macOS 原生 SwiftUI 状态栏面板
- **双语** — 自动跟随系统语言，支持中文 / English 手动切换

## 安装

```bash
# 推荐：pipx 全局安装（隔离环境，任意终端可用）
pipx install cc-statistics

# 或者 pip 安装
pip install cc-statistics
```

CLI 工具（`cc-stats`）无第三方依赖，仅使用 Python 标准库。

### 从源码安装（开发用）

```bash
git clone https://github.com/androidZzT/cc-statistics.git
cd cc-statistics
python3 -m venv .venv
source .venv/bin/activate
pip install -e .
```

## 使用

### CLI 命令行

```bash
cc-stats                     # 分析当前目录的所有会话
cc-stats --list              # 列出所有项目
cc-stats compose-album       # 按关键词匹配项目
cc-stats --all --since 3d    # 最近 3 天所有项目
cc-stats --all --since 2w    # 最近 2 周
cc-stats sailor --last 3     # 某项目最近 3 个会话
```

### macOS 状态栏面板

```bash
cc-stats-app
```

> 需要 macOS + Xcode Command Line Tools（`xcode-select --install`），Swift 组件首次启动自动编译。

**状态栏：**
- Claude logo + 当日 Token 用量 + 预估费用
- 右键菜单切换显示模式（Token+费用 / Token / 费用 / 会话数）
- 支持开机自启

**统计面板：**
- 项目选择器 + 时间范围切换（今天 / 本周 / 本月 / 全部）
- 4 项指标卡片：会话数、指令数、活跃时长、预估费用
- 每日趋势：14 天费用条形图
- 开发时间：AI 占比环形图 + 时长明细
- 代码变更：Git commit 统计 + 按语言拆分
- Token 用量：按模型堆叠条形图 + 每模型费用
- 工具调用：Top 10 排行

**会话管理：**
- 搜索历史会话内容
- 点击会话自动复制 `claude --resume` 命令
- 支持查看完整对话记录

**更多：**
- 全局快捷键 `Cmd+Shift+C`
- 导出统计数据（JSON / CSV，自动保存到桌面并打开）
- 设置页：开机自启、语言切换
- 点击面板外自动收起（带动画）

## 数据来源

所有数据读取自 `~/.claude/` 本地文件，不联网，不上传：

| 数据 | 来源 |
|------|------|
| 会话消息 | `~/.claude/projects/<project>/<session>.jsonl` |
| 工具调用 | JSONL 中 assistant 消息的 `tool_use` 块 |
| Token 用量 | JSONL 中 assistant 消息的 `usage` 字段 |
| Git 变更 | 项目目录的 `git log --numstat` |

## 请 cc 吃 Token

如果这个工具对你有帮助，欢迎请 cc 吃点 Token :)

<img src="docs/donate.jpg" width="200" alt="微信赞赏码">
