import ActivityKit
import Foundation

struct ClaudeCodeIslandAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var status: Status
        var phase: String
        var elapsedSec: Int
        var inputTokens: Int
        var outputTokens: Int
        var costUSD: Double
        var summary: String
        var approvalID: String?
        var approvalAction: String?
        var approvalRisk: String?
        var approvalExpiresAt: Date?
    }

    enum Status: String, Codable, Hashable {
        case running = "RUNNING"
        case waitingApproval = "WAITING_APPROVAL"
        case completed = "COMPLETED"
        case failed = "FAILED"
        case canceled = "CANCELED"
    }

    var taskID: String
    var sessionID: String
    var title: String
    var repoName: String
    var modelShort: String
}

extension ClaudeCodeIslandAttributes.ContentState {
    static func from(task: BridgeTask, approval: BridgeApprovalItem?) -> Self {
        Self(
            status: .init(rawValue: task.status.rawValue) ?? .running,
            phase: task.phase,
            elapsedSec: task.durationSec,
            inputTokens: task.usage.inputTokens,
            outputTokens: task.usage.outputTokens,
            costUSD: task.usage.costUSD,
            summary: task.summary,
            approvalID: approval?.approvalID,
            approvalAction: approval?.action,
            approvalRisk: approval?.risk,
            approvalExpiresAt: approval?.expiresAt
        )
    }
}

extension ClaudeCodeIslandAttributes {
    static func from(task: BridgeTask) -> Self {
        let repoName: String
        if task.repo.isEmpty {
            repoName = "Unknown Repo"
        } else {
            repoName = URL(fileURLWithPath: task.repo).lastPathComponent
        }
        return Self(
            taskID: task.taskID,
            sessionID: task.sessionID,
            title: task.title.isEmpty ? "Claude Code Task" : task.title,
            repoName: repoName,
            modelShort: modelShortName(task.model)
        )
    }

    private static func modelShortName(_ model: String) -> String {
        let lower = model.lowercased()
        if lower.contains("opus") { return "OPUS" }
        if lower.contains("sonnet") { return "SON" }
        if lower.contains("haiku") { return "HAI" }
        if lower.contains("gpt") { return "GPT" }
        if lower.isEmpty { return "AI" }
        return String(model.prefix(3)).uppercased()
    }
}
