import Foundation

@MainActor
final class BridgeSyncCoordinator: ObservableObject {
    @Published private(set) var currentTask: BridgeTask?
    @Published private(set) var approvals: [BridgeApprovalItem] = []
    @Published private(set) var lastError: String?

    private let client: BridgeClient
    private var syncTask: Task<Void, Never>?
    private var streamTask: Task<Void, Never>?
    private var activityManager: Any?
    private var lastEventID: String?

    init(client: BridgeClient = BridgeClient()) {
        self.client = client
        if #available(iOS 16.2, *) {
            self.activityManager = ClaudeCodeActivityManager()
        }
    }

    func start() {
        stop()
        syncTask = Task { [weak self] in
            await self?.pollLoop()
        }
        streamTask = Task { [weak self] in
            await self?.streamLoop()
        }
    }

    func stop() {
        syncTask?.cancel()
        streamTask?.cancel()
        syncTask = nil
        streamTask = nil
    }

    func resolveApproval(id: String, approved: Bool) async {
        do {
            _ = try await client.resolveApproval(approvalID: id, approved: approved)
            await refreshSnapshot()
        } catch {
            lastError = "resolve approval failed: \(error.localizedDescription)"
        }
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            await refreshSnapshot()
            do {
                try await Task.sleep(nanoseconds: 15_000_000_000)
            } catch {
                return
            }
        }
    }

    private func streamLoop() async {
        while !Task.isCancelled {
            do {
                let stream = client.eventStream(lastEventID: lastEventID)
                for try await event in stream {
                    lastEventID = event.eventID
                    let applied = await apply(event: event)
                    if !applied {
                        await refreshSnapshot()
                    }
                }
            } catch {
                lastError = "stream disconnected: \(error.localizedDescription)"
            }
            do {
                try await Task.sleep(nanoseconds: 2_000_000_000)
            } catch {
                return
            }
        }
    }

    private func refreshSnapshot() async {
        do {
            async let task = client.currentTask()
            async let pending = client.pendingApprovals()
            let latestTask = try await task
            let latestApprovals = try await pending

            currentTask = latestTask
            approvals = latestApprovals
            lastError = nil

            await syncLiveActivity()
        } catch {
            lastError = "refresh failed: \(error.localizedDescription)"
        }
    }

    private func apply(event: BridgeEventEnvelope) async -> Bool {
        var mutatedTask = currentTask
        var mutatedApprovals = approvals

        switch event.type {
        case .taskStarted:
            var task = placeholderTask(for: event)
            task.title = event.payload.string("title") ?? task.title
            task.repo = event.payload.string("repo") ?? task.repo
            task.model = event.payload.string("model") ?? task.model
            task.status = .running
            task.phase = ""
            task.summary = ""
            task.durationSec = 0
            task.usage = BridgeUsage(inputTokens: 0, outputTokens: 0, costUSD: 0)
            task.startedAt = event.timestamp
            task.updatedAt = event.timestamp
            task.errorMessage = ""
            mutatedTask = task
            mutatedApprovals.removeAll(where: { $0.taskID == event.taskID })

        case .taskProgress:
            guard var task = taskForNonStartEvent(event, from: mutatedTask) else {
                return false
            }
            if task.status != .waitingApproval {
                task.status = .running
            }
            if let phase = event.payload.string("phase"), !phase.isEmpty {
                task.phase = phase
            }
            if let summary = event.payload.string("summary"), !summary.isEmpty {
                task.summary = summary
            }
            if let durationSec = event.payload.int("duration_sec") {
                task.durationSec = max(0, durationSec)
            }
            if let usageObj = event.payload.object("usage") {
                task.usage = usage(from: usageObj, fallback: task.usage)
            }
            task.updatedAt = event.timestamp
            mutatedTask = task

        case .approvalRequired:
            guard var task = taskForNonStartEvent(event, from: mutatedTask) else {
                return false
            }
            let approvalID = event.payload.string("approval_id") ?? ""
            if !approvalID.isEmpty {
                let action = event.payload.string("action") ?? "Action requires approval"
                let tool = event.payload.string("tool") ?? "Unknown"
                let risk = event.payload.string("risk") ?? "medium"
                let reason = event.payload.string("reason") ?? ""
                let expiresInSec = max(1, event.payload.int("expires_in_sec") ?? 120)
                let expiresAt = event.timestamp.addingTimeInterval(TimeInterval(expiresInSec))
                let item = BridgeApprovalItem(
                    approvalID: approvalID,
                    taskID: event.taskID,
                    tool: tool,
                    action: action,
                    risk: risk,
                    reason: reason,
                    expiresAt: expiresAt,
                    resolved: false,
                    approved: nil
                )
                if let idx = mutatedApprovals.firstIndex(where: { $0.approvalID == approvalID }) {
                    mutatedApprovals[idx] = item
                } else {
                    mutatedApprovals.insert(item, at: 0)
                }
                mutatedApprovals.removeAll(where: { $0.resolved })
                task.summary = action
            }
            task.status = .waitingApproval
            task.phase = "waiting_user"
            task.updatedAt = event.timestamp
            mutatedTask = task

        case .approvalResolved:
            guard var task = taskForNonStartEvent(event, from: mutatedTask) else {
                return false
            }
            let approvalID = event.payload.string("approval_id") ?? ""
            let approved = event.payload.bool("approved") ?? false
            if !approvalID.isEmpty, let idx = mutatedApprovals.firstIndex(where: { $0.approvalID == approvalID }) {
                mutatedApprovals[idx].resolved = true
                mutatedApprovals[idx].approved = approved
            }
            mutatedApprovals.removeAll(where: { $0.resolved })
            task.status = approved ? .running : .failed
            task.phase = approved ? "running" : "failed"
            task.errorMessage = approved ? "" : "Approval rejected by user."
            if !approved {
                task.summary = task.errorMessage
            }
            task.updatedAt = event.timestamp
            mutatedTask = task

        case .taskCompleted:
            guard var task = taskForNonStartEvent(event, from: mutatedTask) else {
                return false
            }
            task.status = .completed
            task.phase = "completed"
            if let result = event.payload.string("result_summary"), !result.isEmpty {
                task.summary = result
            }
            if let durationSec = event.payload.int("duration_sec") {
                task.durationSec = max(0, durationSec)
            }
            if let usageObj = event.payload.object("usage") {
                task.usage = usage(from: usageObj, fallback: task.usage)
            }
            task.updatedAt = event.timestamp
            mutatedTask = task
            mutatedApprovals.removeAll(where: { $0.taskID == event.taskID })

        case .taskFailed:
            guard var task = taskForNonStartEvent(event, from: mutatedTask) else {
                return false
            }
            task.status = .failed
            task.phase = "failed"
            let msg = event.payload.string("error_message") ?? "Task failed"
            task.errorMessage = msg
            task.summary = msg
            if let durationSec = event.payload.int("duration_sec") {
                task.durationSec = max(0, durationSec)
            }
            task.updatedAt = event.timestamp
            mutatedTask = task
            mutatedApprovals.removeAll(where: { $0.taskID == event.taskID })

        case .taskCanceled:
            guard var task = taskForNonStartEvent(event, from: mutatedTask) else {
                return false
            }
            task.status = .canceled
            task.phase = "canceled"
            task.updatedAt = event.timestamp
            mutatedTask = task
            mutatedApprovals.removeAll(where: { $0.taskID == event.taskID })
        }

        currentTask = mutatedTask
        approvals = mutatedApprovals
        lastError = nil
        await syncLiveActivity()
        return true
    }

    private func taskForNonStartEvent(_ event: BridgeEventEnvelope, from task: BridgeTask?) -> BridgeTask? {
        if let task {
            if task.taskID == event.taskID {
                return task
            }
            return nil
        }
        return placeholderTask(for: event)
    }

    private func placeholderTask(for event: BridgeEventEnvelope) -> BridgeTask {
        BridgeTask(
            taskID: event.taskID,
            sessionID: event.sessionID,
            title: event.payload.string("title") ?? "Claude Code Task",
            repo: event.payload.string("repo") ?? "",
            model: event.payload.string("model") ?? "",
            status: .running,
            phase: "",
            summary: "",
            durationSec: 0,
            usage: BridgeUsage(inputTokens: 0, outputTokens: 0, costUSD: 0),
            startedAt: event.timestamp,
            updatedAt: event.timestamp,
            errorMessage: ""
        )
    }

    private func usage(from payload: [String: JSONValue], fallback: BridgeUsage) -> BridgeUsage {
        BridgeUsage(
            inputTokens: max(0, payload.int("input_tokens") ?? fallback.inputTokens),
            outputTokens: max(0, payload.int("output_tokens") ?? fallback.outputTokens),
            costUSD: max(0, payload.double("cost_usd") ?? fallback.costUSD)
        )
    }

    private func syncLiveActivity() async {
        if #available(iOS 16.2, *),
           let manager = activityManager as? ClaudeCodeActivityManager {
            if let latestTask = currentTask {
                let approval = approvals.first(where: { $0.taskID == latestTask.taskID && !$0.resolved })
                await manager.upsert(task: latestTask, approval: approval)
            } else {
                await manager.endIfNeeded()
            }
        }
    }
}
