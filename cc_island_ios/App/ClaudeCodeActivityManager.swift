import ActivityKit
import Foundation

@MainActor
@available(iOS 16.2, *)
final class ClaudeCodeActivityManager {
    private(set) var currentActivity: Activity<ClaudeCodeIslandAttributes>?

    func upsert(task: BridgeTask, approval: BridgeApprovalItem?) async {
        let attributes = ClaudeCodeIslandAttributes.from(task: task)
        let contentState = ClaudeCodeIslandAttributes.ContentState.from(task: task, approval: approval)
        let content = ActivityContent(state: contentState, staleDate: Date().addingTimeInterval(120))

        if let activity = currentActivity, activity.attributes.taskID == task.taskID {
            await activity.update(content)
            if shouldEnd(status: task.status) {
                await activity.end(content, dismissalPolicy: .immediate)
                currentActivity = nil
            }
            return
        }

        if let activity = currentActivity {
            await activity.end(content, dismissalPolicy: .immediate)
            currentActivity = nil
        }

        guard !shouldEnd(status: task.status) else { return }

        do {
            currentActivity = try Activity<ClaudeCodeIslandAttributes>.request(
                attributes: attributes,
                content: content,
                pushType: nil
            )
        } catch {
            // Keep app logic resilient if user disables Live Activities.
            currentActivity = nil
        }
    }

    func endIfNeeded() async {
        guard let activity = currentActivity else { return }
        let finalState = activity.content.state
        let content = ActivityContent(state: finalState, staleDate: nil)
        await activity.end(content, dismissalPolicy: .immediate)
        currentActivity = nil
    }

    private func shouldEnd(status: BridgeTaskStatus) -> Bool {
        switch status {
        case .completed, .failed, .canceled:
            return true
        case .idle, .running, .waitingApproval:
            return false
        }
    }
}
