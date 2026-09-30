# Claude Code Dynamic Island Companion (MVP)

## 目标

构建一个 iOS Companion，将 Claude Code 的关键运行状态投射到 Live Activities / Dynamic Island：

1. 任务运行中状态可视化（模型、耗时、token/cost、最近动作）
2. 任务完成/失败即时通知
3. 需要用户手动确权的动作（approve/reject）可在手机端完成

## 项目拆分

```
cc-bridge-daemon/          # macOS 本机桥接服务（采集 Claude 事件并对外提供 API）
  cmd/
  internal/
    collector/             # 采集 stream-json / hook 事件
    state/                 # 任务状态机 + 审批队列
    transport/             # SSE / WS / HTTP API
    auth/                  # 配对令牌与签名校验
  api/
    openapi.yaml

cc-island-ios/             # iOS App + Widget Extension
  App/
  Widgets/                 # Live Activity + Dynamic Island UI
  Intents/                 # Approve/Reject App Intent
  Networking/
  Storage/
```

> 注：本仓库当前先产出协议与设计文档，不引入跨平台构建脚手架。

## 文档索引

1. [01-architecture.md](./01-architecture.md): 架构、数据流、状态机
2. [02-event-protocol.md](./02-event-protocol.md): 事件协议（JSON）
3. [03-openapi.yaml](./03-openapi.yaml): 首版 API 规范
4. [04-live-activity-spec.md](./04-live-activity-spec.md): Live Activity 字段与 UI 映射
5. [05-mvp-plan.md](./05-mvp-plan.md): 两周 MVP 执行计划
6. [06-ios-integration.md](./06-ios-integration.md): iOS App + Widget 集成步骤

## iOS 代码骨架

可直接使用仓库中的 `cc_island_ios/` 目录作为 Xcode 集成模板。

## 本地运行（当前已实现）

1. 仅启动 bridge API（生成一个 synthetic task）：

```bash
cc-stats-bridge --host 127.0.0.1 --port 8765
```

2. 从 stdin 读取 `stream-json`：

```bash
cat sample-stream.jsonl | cc-stats-bridge --stdin-stream --task-title "Fix CI"
```

3. 由 bridge 直接拉起命令并消费 stdout（命令参数放在 `--` 后）：

```bash
cc-stats-bridge --stream-command -- claude --output-format stream-json "fix tests"
```

4. 可选：让 Claude hooks 直接推事件到 bridge（用于审批/完成）

```bash
export CC_STATS_BRIDGE_URL="http://127.0.0.1:8765"
# 之后按现有方式安装 hooks
cc-stats --install-hooks
```
