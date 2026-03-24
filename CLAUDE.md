# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

cc-statistics — CLI 工具，用于统计 Claude Code 会话的 AI Coding 工程指标。

数据源：`~/.claude/projects/` 下的 JSONL 会话文件。

## Setup

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -e .
```

## Usage

```bash
cc-stats --list              # 列出所有项目
cc-stats                     # 分析当前目录项目
cc-stats <project-keyword>   # 按关键词匹配项目
cc-stats <path/to/file.jsonl> # 分析指定 JSONL
cc-stats --all               # 分析所有项目
cc-stats --last N            # 只看最近 N 个会话
```

## Architecture

- `cc_stats/parser.py` — 解析 JSONL 为 Session/Message 数据结构
- `cc_stats/analyzer.py` — 从 Session 计算 5 项工程指标（指令数、工具调用、时长、代码行数、token）
- `cc_stats/formatter.py` — 将统计结果格式化为终端表格输出
- `cc_stats/cli.py` — argparse CLI 入口，负责文件发现和参数处理

## Key conventions

- 纯 Python stdlib，无第三方依赖
- 用户消息判定：`type == "user"` 且 `is_tool_result == False` 且 `is_meta == False`
- 活跃时间：消息间隔 ≤ 5 分钟视为活跃
- 代码行数来自 Edit/Write 工具调用的 input 参数

## Code Review 规范

所有代码变更（包括社区 PR）在合并前必须通过以下安全和性能检查。

### 安全检查清单

- [ ] **Shell/Script 注入防护**：所有拼接到 AppleScript、shell command、osascript 的字符串必须转义（反斜杠、双引号等特殊字符）。禁止直接字符串插值到脚本模板中
- [ ] **外部输入不可信**：文件名、项目名、路径等来自用户或文件系统的值，不可直接拼入命令或脚本。必须经过清洗或转义
- [ ] **JSONL 解析防御**：解析外部 JSONL 文件时，对缺失字段、类型不匹配、格式异常做防御性处理，不可因单条脏数据导致整体崩溃
- [ ] **无硬编码敏感信息**：代码中不包含 API key、token、密码等敏感信息

### 性能检查清单

- [ ] **禁止循环中同步子进程**：不可在 for 循环内调用 `Process()`/`subprocess` 等同步外部命令。如需批量执行，使用批处理或异步方式
- [ ] **时间复杂度评估**：对遍历全量 sessions/messages 的逻辑，评估时间复杂度。避免 O(N²) 或更高复杂度的嵌套循环；优先使用单次遍历 + 分桶/索引
- [ ] **IO 密集操作需异步或缓存**：磁盘读取、文件遍历等 IO 操作应考虑缓存策略，避免重复读取。大量文件操作应在后台线程执行
- [ ] **避免不必要的全量重算**：筛选条件变更时，如果数据源未变，应复用缓存而非重新加载

### PR Review 流程

1. **自动检查**：PR 提交后，CI 必须通过编译检查
2. **安全审查**：涉及字符串拼接、外部输入处理、命令执行的变更，必须逐行确认转义和清洗
3. **性能审查**：涉及数据遍历、子进程调用、IO 操作的变更，必须评估大数据量下的表现
4. **社区 PR 额外要求**：社区贡献者的 PR 需项目维护者 approve 后方可合并，重点关注安全和性能两项
