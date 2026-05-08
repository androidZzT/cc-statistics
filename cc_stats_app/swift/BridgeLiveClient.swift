import Foundation

enum BridgeTaskStatus: String, Equatable {
    case running = "RUNNING"
    case waitingApproval = "WAITING_APPROVAL"
    case completed = "COMPLETED"
    case failed = "FAILED"
    case canceled = "CANCELED"
}

struct BridgeLiveTaskSnapshot: Equatable {
    let taskId: String
    let title: String
    let repo: String
    let model: String
    let status: BridgeTaskStatus
    let phase: String
    let summary: String
    let durationSec: Int
    let inputTokens: Int
    let outputTokens: Int
    let costUSD: Double
    let errorMessage: String
    let approvalId: String?
    let toolName: String?
    let action: String?
    let risk: String?
    let reason: String?
}

final class BridgeLiveClient {
    struct Configuration {
        var pollInterval: TimeInterval = 2.0
        var timeout: TimeInterval = 0.8
        var reconnectDelay: TimeInterval = 1.5
        var terminalHoldDuration: TimeInterval = 3.0
    }

    var onSnapshotChange: ((BridgeLiveTaskSnapshot?) -> Void)?

    private let config: Configuration
    private var timer: Timer?
    private var lastSnapshot: BridgeLiveTaskSnapshot?
    private var inFlight = false
    private var streamDelegate: BridgeSSEStreamDelegate?
    private var streamSession: URLSession?
    private var streamTask: URLSessionDataTask?
    private var lastEventId: String?
    private var reconnectWorkItem: DispatchWorkItem?
    private var terminalClearWorkItem: DispatchWorkItem?
    private var terminalHoldTaskId: String?
    private var streamEventIgnoreBefore: Date?
    private var isStarted = false

    init(config: Configuration = Configuration()) {
        self.config = config
    }

    deinit {
        stop()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        streamEventIgnoreBefore = Date().addingTimeInterval(-2.0)
        pollCurrentTask()
        startTimer()
        startEventStream()
    }

    func stop() {
        isStarted = false
        timer?.invalidate()
        timer = nil
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        terminalClearWorkItem?.cancel()
        terminalClearWorkItem = nil
        terminalHoldTaskId = nil
        streamEventIgnoreBefore = nil
        streamTask?.cancel()
        streamTask = nil
        streamSession?.invalidateAndCancel()
        streamSession = nil
        streamDelegate = nil
        inFlight = false
    }

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: config.pollInterval, repeats: true) { [weak self] _ in
            self?.pollCurrentTask()
        }
    }

    private func pollCurrentTask() {
        guard !inFlight else { return }
        guard let url = URL(string: "/v1/tasks/current", relativeTo: bridgeBaseURL()) else { return }

        inFlight = true
        var request = URLRequest(url: url)
        request.timeoutInterval = config.timeout

        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            guard let self else { return }
            defer { self.inFlight = false }

            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let data else {
                return
            }

            let snapshot = Self.parseTaskSnapshot(from: data)
            if let snapshot, snapshot.status == .waitingApproval {
                self.fetchApproval(for: snapshot) { [weak self] merged in
                    guard let self else { return }
                    self.publishPolledSnapshot(merged)
                }
            } else {
                self.publishPolledSnapshot(snapshot)
            }
        }.resume()
    }

    private func startEventStream() {
        guard isStarted else { return }
        guard streamTask == nil else { return }
        guard let url = URL(string: "/v1/events/stream", relativeTo: bridgeBaseURL()) else { return }

        var request = URLRequest(url: url)
        request.timeoutInterval = .infinity
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let lastEventId {
            request.setValue(lastEventId, forHTTPHeaderField: "Last-Event-ID")
        }

        let delegate = BridgeSSEStreamDelegate(
            onEvent: { [weak self] event in
                DispatchQueue.main.async {
                    self?.handleStreamEvent(event)
                }
            },
            onComplete: { [weak self] in
                DispatchQueue.main.async {
                    guard self?.isStarted == true else { return }
                    self?.streamTask = nil
                    self?.streamSession?.finishTasksAndInvalidate()
                    self?.streamSession = nil
                    self?.streamDelegate = nil
                    self?.scheduleStreamReconnect()
                }
            }
        )
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let task = session.dataTask(with: request)

        streamDelegate = delegate
        streamSession = session
        streamTask = task
        task.resume()
    }

    private func scheduleStreamReconnect() {
        guard isStarted else { return }
        guard reconnectWorkItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            self?.reconnectWorkItem = nil
            self?.startEventStream()
            self?.pollCurrentTask()
        }
        reconnectWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + config.reconnectDelay, execute: item)
    }

    private func handleStreamEvent(_ event: BridgeSSEEvent) {
        if let id = event.id, !id.isEmpty {
            lastEventId = id
        }
        guard let data = event.data.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        guard let eventType = raw["type"] as? String,
              let taskId = raw["task_id"] as? String,
              !taskId.isEmpty else {
            return
        }
        if shouldIgnoreReplayEvent(raw) {
            return
        }
        let payload = raw["payload"] as? [String: Any] ?? [:]
        applyEvent(type: eventType, taskId: taskId, payload: payload)
    }

    private func shouldIgnoreReplayEvent(_ raw: [String: Any]) -> Bool {
        guard let cutoff = streamEventIgnoreBefore,
              let timestamp = bridgeDateValue(raw["timestamp"]) else {
            return false
        }
        return timestamp < cutoff
    }

    private func applyEvent(type: String, taskId: String, payload: [String: Any]) {
        let previous = lastSnapshot?.taskId == taskId ? lastSnapshot : nil
        if shouldKeepTerminalSnapshot(previous, forIncomingEvent: type) {
            return
        }
        let usage = usageValues(from: payload, fallback: previous)
        let duration = intValue(payload["duration_sec"]) ?? previous?.durationSec ?? 0
        let tool = toolValues(from: payload, fallback: previous)

        switch type {
        case "task_started":
            clearTerminalHold()
            publish(BridgeLiveTaskSnapshot(
                taskId: taskId,
                title: stringValue(payload["title"]) ?? previous?.title ?? "Claude task",
                repo: stringValue(payload["repo"]) ?? previous?.repo ?? "",
                model: stringValue(payload["model"]) ?? previous?.model ?? "",
                status: .running,
                phase: previous?.phase ?? "",
                summary: previous?.summary ?? "",
                durationSec: duration,
                inputTokens: usage.input,
                outputTokens: usage.output,
                costUSD: usage.cost,
                errorMessage: "",
                approvalId: nil,
                toolName: nil,
                action: nil,
                risk: nil,
                reason: nil
            ))
        case "task_progress":
            clearTerminalHold()
            publish(BridgeLiveTaskSnapshot(
                taskId: taskId,
                title: previous?.title ?? "Claude task",
                repo: previous?.repo ?? "",
                model: previous?.model ?? "",
                status: .running,
                phase: stringValue(payload["phase"]) ?? previous?.phase ?? "running",
                summary: stringValue(payload["summary"]) ?? previous?.summary ?? "",
                durationSec: duration,
                inputTokens: usage.input,
                outputTokens: usage.output,
                costUSD: usage.cost,
                errorMessage: "",
                approvalId: nil,
                toolName: tool.name,
                action: tool.action,
                risk: nil,
                reason: nil
            ))
        case "approval_required":
            clearTerminalHold()
            publish(BridgeLiveTaskSnapshot(
                taskId: taskId,
                title: previous?.title ?? "Claude task",
                repo: previous?.repo ?? "",
                model: previous?.model ?? "",
                status: .waitingApproval,
                phase: "waiting_user",
                summary: stringValue(payload["action"]) ?? previous?.summary ?? "Action requires approval",
                durationSec: duration,
                inputTokens: usage.input,
                outputTokens: usage.output,
                costUSD: usage.cost,
                errorMessage: "",
                approvalId: stringValue(payload["approval_id"]),
                toolName: stringValue(payload["tool"]),
                action: stringValue(payload["action"]),
                risk: stringValue(payload["risk"]),
                reason: stringValue(payload["reason"])
            ))
        case "approval_resolved":
            let approved = boolValue(payload["approved"]) ?? false
            let resolvedSnapshot = BridgeLiveTaskSnapshot(
                taskId: taskId,
                title: previous?.title ?? "Claude task",
                repo: previous?.repo ?? "",
                model: previous?.model ?? "",
                status: approved ? .running : .failed,
                phase: approved ? "running" : "approval_denied",
                summary: approved ? "Approval accepted. Continuing task." : "Approval rejected.",
                durationSec: duration,
                inputTokens: usage.input,
                outputTokens: usage.output,
                costUSD: usage.cost,
                errorMessage: approved ? "" : "Approval rejected by user.",
                approvalId: nil,
                toolName: nil,
                action: nil,
                risk: nil,
                reason: nil
            )
            if approved {
                clearTerminalHold()
                publish(resolvedSnapshot)
            } else {
                publishTerminal(resolvedSnapshot)
            }
        case "task_completed":
            publishTerminal(BridgeLiveTaskSnapshot(
                taskId: taskId,
                title: previous?.title ?? "Claude task",
                repo: previous?.repo ?? "",
                model: previous?.model ?? "",
                status: .completed,
                phase: "completed",
                summary: stringValue(payload["result_summary"]) ?? stringValue(payload["summary"]) ?? previous?.summary ?? "Task completed.",
                durationSec: duration,
                inputTokens: usage.input,
                outputTokens: usage.output,
                costUSD: usage.cost,
                errorMessage: "",
                approvalId: nil,
                toolName: nil,
                action: nil,
                risk: nil,
                reason: nil
            ))
        case "task_failed":
            let message = stringValue(payload["error_message"]) ?? previous?.errorMessage ?? "Task failed."
            publishTerminal(BridgeLiveTaskSnapshot(
                taskId: taskId,
                title: previous?.title ?? "Claude task",
                repo: previous?.repo ?? "",
                model: previous?.model ?? "",
                status: .failed,
                phase: "failed",
                summary: message,
                durationSec: duration,
                inputTokens: usage.input,
                outputTokens: usage.output,
                costUSD: usage.cost,
                errorMessage: message,
                approvalId: nil,
                toolName: nil,
                action: nil,
                risk: nil,
                reason: nil
            ))
        case "task_canceled":
            publishTerminal(BridgeLiveTaskSnapshot(
                taskId: taskId,
                title: previous?.title ?? "Claude task",
                repo: previous?.repo ?? "",
                model: previous?.model ?? "",
                status: .canceled,
                phase: "canceled",
                summary: "Task canceled.",
                durationSec: duration,
                inputTokens: usage.input,
                outputTokens: usage.output,
                costUSD: usage.cost,
                errorMessage: "",
                approvalId: nil,
                toolName: nil,
                action: nil,
                risk: nil,
                reason: nil
            ))
        default:
            pollCurrentTask()
        }
    }

    private func shouldKeepTerminalSnapshot(
        _ previous: BridgeLiveTaskSnapshot?,
        forIncomingEvent eventType: String
    ) -> Bool {
        guard let previous, previous.isTerminal else { return false }
        if eventType == "task_started" {
            return false
        }
        if previous.status == .failed || previous.status == .canceled {
            return true
        }
        return eventType != "task_failed" && eventType != "task_canceled"
    }

    private func publishTerminal(_ snapshot: BridgeLiveTaskSnapshot) {
        terminalClearWorkItem?.cancel()
        let taskId = snapshot.taskId
        terminalHoldTaskId = taskId
        publish(snapshot)
        guard snapshot.status == .completed else {
            terminalClearWorkItem = nil
            return
        }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.lastSnapshot?.taskId == taskId else { return }
            guard let status = self.lastSnapshot?.status,
                  status == .completed || status == .failed || status == .canceled else { return }
            self.terminalHoldTaskId = nil
            self.terminalClearWorkItem = nil
            self.publish(nil)
        }
        terminalClearWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + config.terminalHoldDuration, execute: item)
    }

    private func publishPolledSnapshot(_ snapshot: BridgeLiveTaskSnapshot?) {
        let update = { [weak self] in
            guard let self else { return }
            if snapshot == nil, self.terminalHoldTaskId != nil {
                return
            }
            if snapshot == nil || snapshot?.isTerminal == false {
                self.clearTerminalHold()
            }
            self.publish(snapshot)
        }
        if Thread.isMainThread {
            update()
        } else {
            DispatchQueue.main.async(execute: update)
        }
    }

    private func clearTerminalHold() {
        terminalClearWorkItem?.cancel()
        terminalClearWorkItem = nil
        terminalHoldTaskId = nil
    }

    private func publish(_ snapshot: BridgeLiveTaskSnapshot?) {
        let update = { [weak self] in
            guard let self else { return }
            guard snapshot != self.lastSnapshot else { return }
            self.lastSnapshot = snapshot
            self.onSnapshotChange?(snapshot)
        }
        if Thread.isMainThread {
            update()
        } else {
            DispatchQueue.main.async(execute: update)
        }
    }

    private func fetchApproval(
        for snapshot: BridgeLiveTaskSnapshot,
        completion: @escaping (BridgeLiveTaskSnapshot?) -> Void
    ) {
        guard let url = URL(string: "/v1/approvals", relativeTo: bridgeBaseURL()) else {
            completion(snapshot)
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = config.timeout
        URLSession.shared.dataTask(with: request) { data, response, _ in
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let data,
                  let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = raw["items"] as? [[String: Any]] else {
                completion(snapshot)
                return
            }
            let matched = items.first { ($0["task_id"] as? String) == snapshot.taskId } ?? items.first
            guard let item = matched else {
                completion(snapshot)
                return
            }
            completion(snapshot.withApproval(item))
        }.resume()
    }

    private static func parseTaskSnapshot(from data: Data) -> BridgeLiveTaskSnapshot? {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let taskId = raw["task_id"] as? String, !taskId.isEmpty else {
            return nil
        }
        guard let statusRaw = raw["status"] as? String,
              let status = BridgeTaskStatus(rawValue: statusRaw) else {
            return nil
        }

        let usage = raw["usage"] as? [String: Any] ?? [:]
        return BridgeLiveTaskSnapshot(
            taskId: taskId,
            title: raw["title"] as? String ?? "",
            repo: raw["repo"] as? String ?? "",
            model: raw["model"] as? String ?? "",
            status: status,
            phase: raw["phase"] as? String ?? "",
            summary: raw["summary"] as? String ?? "",
            durationSec: max(0, raw["duration_sec"] as? Int ?? 0),
            inputTokens: max(0, usage["input_tokens"] as? Int ?? 0),
            outputTokens: max(0, usage["output_tokens"] as? Int ?? 0),
            costUSD: max(0, usage["cost_usd"] as? Double ?? 0),
            errorMessage: raw["error_message"] as? String ?? "",
            approvalId: nil,
            toolName: nil,
            action: nil,
            risk: nil,
            reason: nil
        )
    }

    private func usageValues(
        from payload: [String: Any],
        fallback: BridgeLiveTaskSnapshot?
    ) -> (input: Int, output: Int, cost: Double) {
        let usage = payload["usage"] as? [String: Any] ?? [:]
        return (
            max(0, intValue(usage["input_tokens"]) ?? fallback?.inputTokens ?? 0),
            max(0, intValue(usage["output_tokens"]) ?? fallback?.outputTokens ?? 0),
            max(0, doubleValue(usage["cost_usd"]) ?? fallback?.costUSD ?? 0)
        )
    }

    private func toolValues(
        from payload: [String: Any],
        fallback: BridgeLiveTaskSnapshot?
    ) -> (name: String?, action: String?) {
        let lastTool = payload["last_tool"] as? [String: Any]
        let name = stringValue(lastTool?["name"])
            ?? stringValue(payload["tool"])
            ?? fallback?.toolName
        let action = stringValue(lastTool?["command_preview"])
            ?? stringValue(payload["action"])
            ?? stringValue(payload["summary"])
            ?? fallback?.action
        return (name, action)
    }

    private func bridgeBaseURL() -> URL {
        let env = ProcessInfo.processInfo.environment["CC_STATS_BRIDGE_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaults = UserDefaults.standard.string(forKey: "cc_stats_bridge_url")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = (env?.isEmpty == false ? env : defaults) ?? "http://127.0.0.1:8765"
        return URL(string: raw) ?? URL(string: "http://127.0.0.1:8765")!
    }
}

private struct BridgeSSEEvent {
    let id: String?
    let type: String?
    let data: String
}

private final class BridgeSSEStreamDelegate: NSObject, URLSessionDataDelegate {
    private let onEvent: (BridgeSSEEvent) -> Void
    private let onComplete: () -> Void
    private var buffer = ""

    init(onEvent: @escaping (BridgeSSEEvent) -> Void, onComplete: @escaping () -> Void) {
        self.onEvent = onEvent
        self.onComplete = onComplete
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty else { return }
        buffer += chunk.replacingOccurrences(of: "\r\n", with: "\n")
        drainBuffer()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        onComplete()
    }

    private func drainBuffer() {
        while let range = buffer.range(of: "\n\n") {
            let block = String(buffer[..<range.lowerBound])
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            if let event = parse(block: block) {
                onEvent(event)
            }
        }
    }

    private func parse(block: String) -> BridgeSSEEvent? {
        var id: String?
        var type: String?
        var dataLines: [String] = []

        for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix(":") {
                continue
            }
            if line.hasPrefix("id:") {
                id = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("event:") {
                type = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            }
        }

        guard !dataLines.isEmpty else { return nil }
        return BridgeSSEEvent(id: id, type: type, data: dataLines.joined(separator: "\n"))
    }
}

private extension BridgeLiveTaskSnapshot {
    var isTerminal: Bool {
        status == .completed || status == .failed || status == .canceled
    }

    func withApproval(_ item: [String: Any]) -> BridgeLiveTaskSnapshot {
        BridgeLiveTaskSnapshot(
            taskId: taskId,
            title: title,
            repo: repo,
            model: model,
            status: .waitingApproval,
            phase: "waiting_user",
            summary: stringValue(item["action"]) ?? summary,
            durationSec: durationSec,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            costUSD: costUSD,
            errorMessage: errorMessage,
            approvalId: stringValue(item["approval_id"]),
            toolName: stringValue(item["tool"]),
            action: stringValue(item["action"]),
            risk: stringValue(item["risk"]),
            reason: stringValue(item["reason"])
        )
    }
}

private func stringValue(_ raw: Any?) -> String? {
    guard let raw else { return nil }
    if let value = raw as? String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    return nil
}

private func intValue(_ raw: Any?) -> Int? {
    if let value = raw as? Int { return value }
    if let value = raw as? Double { return Int(value) }
    if let value = raw as? NSNumber { return value.intValue }
    if let value = raw as? String { return Int(value) }
    return nil
}

private func doubleValue(_ raw: Any?) -> Double? {
    if let value = raw as? Double { return value }
    if let value = raw as? Int { return Double(value) }
    if let value = raw as? NSNumber { return value.doubleValue }
    if let value = raw as? String { return Double(value) }
    return nil
}

private func bridgeDateValue(_ raw: Any?) -> Date? {
    guard let value = raw as? String, !value.isEmpty else { return nil }
    return bridgeTimestampFormatterWithFractional.date(from: value)
        ?? bridgeTimestampFormatter.date(from: value)
}

private let bridgeTimestampFormatterWithFractional: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

private let bridgeTimestampFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
}()

private func boolValue(_ raw: Any?) -> Bool? {
    if let value = raw as? Bool { return value }
    if let value = raw as? NSNumber { return value.boolValue }
    if let value = raw as? String {
        let lower = value.lowercased()
        if ["true", "1", "yes"].contains(lower) { return true }
        if ["false", "0", "no"].contains(lower) { return false }
    }
    return nil
}
