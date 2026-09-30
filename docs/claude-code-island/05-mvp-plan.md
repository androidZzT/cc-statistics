# 两周 MVP 执行计划

## Week 1：打通状态与通知链路

### D1-D2：bridge 骨架

1. 搭建 daemon 进程入口
2. 定义内存状态存储（当前任务 + 审批队列）
3. 定义统一事件结构与序列化

### D3-D4：事件采集与映射

1. 接入 Claude `stream-json` 采集
2. 映射到标准事件类型（`task_started/progress/completed/failed`）
3. 加入幂等与事件去重

### D5：iOS 订阅展示（无审批）

1. `GET /v1/tasks/current`
2. `GET /v1/events/stream`（SSE）
3. Live Activity 启动/更新/结束

## Week 2：确权闭环与稳定性

### D6-D7：审批事件

1. 解析需用户确认动作 -> 生成 `approval_required`
2. bridge 暂停任务执行分支
3. iOS 展示审批卡片

### D8-D9：审批回传闭环

1. `POST /v1/approvals/{id}:resolve`
2. 审批决策回写会话控制通道
3. 状态机转移与恢复执行

### D10：稳态处理

1. 审批超时自动拒绝
2. 断线重连与 `Last-Event-ID`
3. 审计日志落盘（便于排障）

## 验收标准（MVP Done）

1. 在任务开始 2 秒内显示 Live Activity
2. token/cost 每 1 秒内可见更新（节流后）
3. 审批请求在 1 秒内到达手机端
4. 审批回传后 2 秒内任务状态恢复
5. 任务完成/失败可稳定结束 Live Activity
