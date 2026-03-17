# cc-stats — Claude Code 会话统计

分析 Claude Code 会话的 AI Coding 工程指标。

## 使用方式

```
/cc-stats                          # 当前项目
/cc-stats --last 3                 # 最近 3 个会话
/cc-stats --since 3d               # 最近 3 天
/cc-stats --since 2026-03-01 --until 2026-03-15  # 日期区间
/cc-stats compose-album            # 按关键词匹配项目
/cc-stats --list                   # 列出所有项目
/cc-stats --all --since 1w         # 所有项目最近一周
```

## 统计指标

1. **用户指令数** — 对话轮次
2. **AI 工具调用** — 总次数 + 按工具拆分（柱状图 + 工具说明）
3. **开发时长** — AI 处理 / 用户活跃 / 活跃率 / AI 占比 / 平均轮次耗时
4. **代码变更** — Git 已提交（所有人）+ AI 工具变更（Edit/Write），按语言拆分
5. **Token 消耗** — input / output / cache，按模型拆分

## 执行

运行 `scripts/run.sh`，将用户参数透传给 `cc-stats` CLI。

如果 `cc-stats` 未安装，执行 `scripts/install.sh` 自动安装。

## 数据来源

所有数据读取自 `~/.claude/` 本地文件，不联网，不上传。

| 数据 | 来源 |
|------|------|
| 会话消息 | `~/.claude/projects/<project>/<session>.jsonl` |
| 工具调用 | JSONL 中 assistant 消息的 `tool_use` 块 |
| Token 用量 | JSONL 中 assistant 消息的 `usage` 字段 |
| Git 变更 | 项目目录的 `git log --numstat` |

## 要求

- Python >= 3.10
- 无第三方依赖
