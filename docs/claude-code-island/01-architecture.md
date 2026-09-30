# 架构设计（MVP）

## 一、组件与职责

### 1) `cc-bridge-daemon`（运行在开发机）

职责：

1. 采集 Claude Code 运行事件（`stream-json`、`system/init`、`system/api_retry`、hook）
2. 统一事件模型并持久化轻量审计日志
3. 维护任务状态机（`RUNNING/WAITING_APPROVAL/COMPLETED/FAILED`）
4. 对 iOS 提供订阅与控制 API（SSE + HTTP）
5. 处理审批回传，驱动本机会话继续或拒绝

### 2) `cc-island-ios`（iPhone）

职责：

1. 拉取任务列表与当前活动任务
2. 启动/更新/结束 Live Activity
3. 接收待审批动作并展示 `Approve/Reject`
4. 通过 App Intent 触发审批回传

## 二、数据流

1. 本机 Claude 会话产生事件流
2. bridge 将事件映射为标准事件（见 `02-event-protocol.md`）
3. iOS 订阅 `/v1/events/stream` 获取状态增量
4. iOS 更新 Live Activity 展示
5. 若出现待审批动作，bridge 发布 `approval_required`
6. 用户在岛上点 `Approve/Reject`，iOS 回调 `/v1/approvals/{id}:resolve`
7. bridge 写回会话控制通道并继续执行或拒绝

## 三、状态机

### 任务状态

1. `IDLE`: 无活动任务
2. `RUNNING`: 正常执行中
3. `WAITING_APPROVAL`: 因权限动作暂停
4. `COMPLETED`: 成功完成
5. `FAILED`: 失败结束
6. `CANCELED`: 用户主动取消

### 转移规则（核心）

1. `IDLE -> RUNNING`: 收到 `task_started`
2. `RUNNING -> WAITING_APPROVAL`: 收到 `approval_required`
3. `WAITING_APPROVAL -> RUNNING`: 收到 `approval_resolved(approved=true)`
4. `WAITING_APPROVAL -> FAILED`: 收到 `approval_resolved(approved=false)` 且任务终止
5. `RUNNING -> COMPLETED`: 收到 `task_completed`
6. `RUNNING -> FAILED`: 收到 `task_failed`

## 四、安全边界

1. iOS 与 bridge 使用设备配对令牌（短期 token + 过期时间）
2. 审批回传必须包含 `approval_id + nonce + timestamp + signature`
3. bridge 对重复审批请求做幂等处理（只接受首个有效决策）
4. 超时未审批动作自动拒绝（默认 120 秒）

## 五、性能与可靠性策略

1. 事件以增量方式推送，避免全量重算
2. UI 仅消费任务摘要字段，长日志延迟加载
3. 对频繁 token 更新做节流（建议 1s 合并一次）
4. 断线重连使用 `Last-Event-ID` 续传
5. 所有关键事件本地 WAL 记录，便于崩溃恢复
