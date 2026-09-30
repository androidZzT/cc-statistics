# 事件协议（v1）

## 1) 事件 Envelope

```json
{
  "version": 1,
  "event_id": "evt_01J...",
  "type": "task_started",
  "task_id": "task_01J...",
  "session_id": "550e8400-e29b-41d4-a716-446655440000",
  "timestamp": "2026-04-18T08:10:00Z",
  "source": "bridge",
  "payload": {}
}
```

字段说明：

1. `version`: 协议版本（当前固定 `1`）
2. `event_id`: 全局唯一事件 ID
3. `type`: 事件类型
4. `task_id`: 任务 ID（同一任务生命周期不变）
5. `session_id`: Claude 会话 ID
6. `timestamp`: ISO8601 UTC 时间
7. `source`: 事件来源（当前固定 `bridge`）
8. `payload`: 事件体

## 2) 事件类型

1. `task_started`
2. `task_progress`
3. `approval_required`
4. `approval_resolved`
5. `task_completed`
6. `task_failed`
7. `task_canceled`

## 3) 各事件 Payload

### `task_started`

```json
{
  "title": "Run tests and fix failures",
  "repo": "/Users/alice/project",
  "branch": "main",
  "model": "claude-sonnet-4-6",
  "permission_mode": "default"
}
```

### `task_progress`

```json
{
  "phase": "tool_running",
  "summary": "Running pytest -q",
  "duration_sec": 93,
  "usage": {
    "input_tokens": 1250,
    "output_tokens": 620,
    "cost_usd": 0.0231
  },
  "last_tool": {
    "name": "Bash",
    "command_preview": "pytest -q",
    "status": "running"
  }
}
```

### `approval_required`

```json
{
  "approval_id": "apr_01J...",
  "tool": "Bash",
  "action": "git push origin main",
  "risk": "high",
  "reason": "Write to remote",
  "expires_in_sec": 120
}
```

### `approval_resolved`

```json
{
  "approval_id": "apr_01J...",
  "approved": true,
  "resolved_by": "ios_device",
  "resolved_at": "2026-04-18T08:11:40Z"
}
```

### `task_completed`

```json
{
  "duration_sec": 301,
  "usage": {
    "input_tokens": 10420,
    "output_tokens": 4890,
    "cost_usd": 0.1623
  },
  "result_summary": "All tests passed, 3 files updated."
}
```

### `task_failed`

```json
{
  "duration_sec": 210,
  "error_code": "permission_denied",
  "error_message": "Approval rejected by user."
}
```

## 4) 幂等与顺序

1. 客户端以 `event_id` 去重
2. 服务端按 `timestamp` + 内部递增序号排序
3. 审批事件同一 `approval_id` 只接受第一次有效决策
