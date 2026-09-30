# Live Activity / Dynamic Island 字段规范（MVP）

## 1) ActivityAttributes（静态字段）

建议字段：

1. `taskId: String`
2. `sessionId: String`
3. `title: String`（任务标题）
4. `repoName: String`
5. `modelShort: String`（例如 `S46` / `O47`）

说明：

1. 静态字段不频繁变化，保证体积小
2. 避免塞入长文本，防止超过 ActivityKit 数据上限

## 2) ContentState（动态字段）

建议字段：

1. `status: String` (`RUNNING|WAITING_APPROVAL|COMPLETED|FAILED`)
2. `phase: String`（thinking/tool_running/waiting_user）
3. `elapsedSec: Int`
4. `inputTokens: Int`
5. `outputTokens: Int`
6. `costUsd: Double`
7. `summary: String`（最近一步摘要，建议 <= 80 chars）
8. `approvalId: String?`
9. `approvalAction: String?`（待审批时显示）
10. `approvalRisk: String?` (`low|medium|high`)
11. `approvalExpiresAt: Date?`

## 3) Dynamic Island 映射

### Compact（高频）

1. 左区：`modelShort`
2. 右区：`status + elapsed`

### Expanded（交互）

1. 顶部：`title` + `repoName`
2. 中部：`summary`
3. 底部：`token/cost`
4. 若 `WAITING_APPROVAL`：
   - 按钮：`Approve`
   - 按钮：`Reject`
   - 倒计时：`approvalExpiresAt - now`

### Minimal

1. 仅显示状态点 + 模型简写（避免拥挤）

## 4) 交互动作（App Intents）

1. `ApproveActionIntent(approvalId)`
2. `RejectActionIntent(approvalId)`
3. `OpenTaskIntent(taskId)`（点击跳 App 详情页）

## 5) 通知策略

1. `task_completed`：发送一次高优先更新并结束活动
2. `task_failed`：发送错误摘要并结束活动
3. `approval_required`：优先触发可见提醒（含倒计时）

## 6) 降级策略

1. 设备不支持 Dynamic Island 时，沿用锁屏 Live Activity
2. 用户关闭 Live Activities 时，退化为普通本地通知
3. 更新频率受限时，仅推送关键状态变化（phase 切换、审批、结束）
