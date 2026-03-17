# cc-statistics

Claude Code 会话统计工具 — 从本地 `~/.claude/` 数据中提取 AI Coding 工程指标。

## 统计指标

| # | 指标 | 说明 |
|---|------|------|
| ① | 用户指令数 | 对话轮次（不含工具返回和系统消息） |
| ② | AI 工具调用 | 总次数 + 按工具拆分（附带柱状图和工具说明） |
| ③ | 开发时长 | 总时长 / AI 处理时长 / 用户活跃时长 / 活跃率 / 平均轮次耗时 |
| ④ | 代码变更 | Git 已提交变更 + AI 工具变更（Edit/Write），按语言拆分 |
| ⑤ | Token 消耗 | input / output / cache，按模型拆分 |

### 时长计算方式

将会话切分为**对话轮次**（用户发消息 → AI 处理 → AI 回复），分别统计：

- **AI 处理时长**：每轮从用户消息到 AI 最后一条响应的耗时
- **用户活跃时长**：上轮 AI 回复到下轮用户消息的间隔（超过 5 分钟视为离开，不计入）
- **活跃时长** = AI 处理 + 用户活跃

### 代码变更来源

- **Git 已提交**：会话时间段内 `git log --numstat` 的所有 commit（包含用户和 AI 的提交）
- **AI 工具变更**：从 JSONL 中 `Edit`/`Write` 工具调用的参数提取（仅 AI 侧）

## 安装

```bash
# 推荐：pipx 全局安装（隔离环境，任意终端可用）
pipx install cc-statistics

# 或者 pip 安装
pip install cc-statistics
```

无第三方依赖，仅使用 Python 标准库。

### 从源码安装（开发用）

```bash
git clone https://github.com/androidZzT/cc-statistics.git
cd cc-statistics
python3 -m venv .venv
source .venv/bin/activate
pip install -e .
```

## 使用

```bash
# 列出所有项目
cc-stats --list

# 分析当前目录的所有会话
cc-stats

# 按关键词匹配项目
cc-stats compose-album

# 分析指定项目目录
cc-stats /path/to/project

# 分析指定 JSONL 文件
cc-stats ~/.claude/projects/-Users-foo-bar/SESSION_ID.jsonl

# 只看最近 N 个会话
cc-stats compose-album --last 3

# 时间范围过滤
cc-stats --all --since 3d           # 最近 3 天
cc-stats --all --since 2w           # 最近 2 周
cc-stats --all --since 1h           # 最近 1 小时
cc-stats --all --since 2026-03-01 --until 2026-03-15  # 指定日期区间
cc-stats sailor --since 2026-03-13T10:00               # 精确到分钟
```

## 示例输出

```
╔══════════════════════════════════════════════════════════╗
║           Claude Code 会话统计报告                      ║
╚══════════════════════════════════════════════════════════╝

  会话数: 3
  时间范围: 2026-03-13 07:24 ~ 2026-03-14 14:16

  ① 用户指令数
────────────────────────────────────────────────────────────
  对话轮次: 58

  ② AI 工具调用
────────────────────────────────────────────────────────────
  总调用次数: 336

  Bash        ███████████████    90  执行 Shell 命令
  Read        ██████████░░░░░    61  读取文件内容
  Edit        █████████░░░░░░    56  编辑文件（精确替换）
  TaskUpdate  ███████░░░░░░░░    44  更新任务状态
  Agent       ████░░░░░░░░░░░    24  启动子代理执行子任务
  Grep        ████░░░░░░░░░░░    24  按内容搜索文件
  TaskCreate  ██░░░░░░░░░░░░░    17  创建任务

  ③ 开发时长
────────────────────────────────────────────────────────────
  总时长:       30h 51m 52s
  活跃时长:     2h 13m 5s
    AI 处理:    1h 42m 42s
    用户活跃:   30m 22s
  活跃率:       7%
  AI 占比:      77%
  平均轮次耗时: 2m 13s/轮 (46 轮)

  ④ 代码变更
────────────────────────────────────────────────────────────
  [Git 已提交]  60 个 commit
  总新增: +30342  总删除: -18228  净增: +12114

  Kotlin    +11472  -1894   net +9578
  Markdown  +490    -50     net +440

  [AI 工具变更]  来自 Edit/Write 调用
  总新增: +1538  总删除: -315  净增: +1223

  Kotlin    +810    -196    net +614
  Markdown  +591    -43     net +548
  Swift     +137    -76     net +61

  ⑤ Token 消耗
────────────────────────────────────────────────────────────
  Input tokens:                 924
  Output tokens:              98.0K
  Cache read tokens:          53.6M
  Cache creation tokens:     814.3K
  ────────────────────────────────────────
  合计:                       54.6M

  按模型拆分:
    claude-opus-4-6: input=924 output=98.0K cache_read=53.6M total=54.6M
```

## 数据来源

所有数据读取自 `~/.claude/` 本地文件，不联网，不上传：

| 数据 | 来源 |
|------|------|
| 会话消息 | `~/.claude/projects/<project>/<session>.jsonl` |
| 工具调用 | JSONL 中 assistant 消息的 `tool_use` 块 |
| Token 用量 | JSONL 中 assistant 消息的 `usage` 字段 |
| Git 变更 | 项目目录的 `git log --numstat` |
