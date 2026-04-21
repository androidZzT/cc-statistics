import ActivityKit
import SwiftUI
import WidgetKit

@available(iOSApplicationExtension 16.1, *)
struct ClaudeCodeIslandWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ClaudeCodeIslandAttributes.self) { context in
            LockScreenActivityView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.85))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.modelShort)
                            .font(.caption2).bold()
                        Text(context.attributes.repoName)
                            .font(.caption2)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(statusText(context.state.status))
                            .font(.caption2).bold()
                        Text(elapsed(context.state.elapsedSec))
                            .font(.caption2)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(context.attributes.title)
                            .font(.subheadline).bold()
                            .lineLimit(1)
                        Text(context.state.summary.isEmpty ? "Running..." : context.state.summary)
                            .font(.caption)
                            .lineLimit(2)
                        HStack {
                            Text("In \(context.state.inputTokens)")
                            Text("Out \(context.state.outputTokens)")
                            Text(String(format: "$%.4f", context.state.costUSD))
                        }
                        .font(.caption2)
                        if context.state.status == .waitingApproval {
                            if #available(iOSApplicationExtension 17.0, *) {
                                ApprovalActionRow(state: context.state)
                            } else {
                                Text("Open app to approve")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }
            } compactLeading: {
                Text(context.attributes.modelShort)
                    .font(.caption2).bold()
            } compactTrailing: {
                Text(shortStatus(context.state.status))
                    .font(.caption2).bold()
            } minimal: {
                Circle()
                    .fill(statusColor(context.state.status))
                    .frame(width: 8, height: 8)
            }
            .widgetURL(URL(string: "ccisland://task/\(context.attributes.taskID)"))
            .keylineTint(statusColor(context.state.status))
        }
    }
}

@available(iOSApplicationExtension 16.1, *)
private struct LockScreenActivityView: View {
    let context: ActivityViewContext<ClaudeCodeIslandAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(context.attributes.title).bold()
                Spacer()
                Text(statusText(context.state.status))
            }
            Text(context.state.summary.isEmpty ? "Running..." : context.state.summary)
                .font(.caption)
                .lineLimit(3)
            HStack {
                Text(context.attributes.modelShort)
                Text("·")
                Text(elapsed(context.state.elapsedSec))
                Spacer()
                Text(String(format: "$%.4f", context.state.costUSD))
            }
            .font(.caption2)
            if context.state.status == .waitingApproval {
                if #available(iOSApplicationExtension 17.0, *) {
                    ApprovalActionRow(state: context.state)
                } else {
                    Text("Open app to approve")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.vertical, 2)
    }
}

@available(iOSApplicationExtension 17.0, *)
private struct ApprovalActionRow: View {
    let state: ClaudeCodeIslandAttributes.ContentState

    var body: some View {
        HStack(spacing: 8) {
            Button(intent: ApproveApprovalIntent(approvalID: state.approvalID ?? "")) {
                Text("Approve")
                    .font(.caption2).bold()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.green.opacity(0.2))
                    .clipShape(Capsule())
            }
            Button(intent: RejectApprovalIntent(approvalID: state.approvalID ?? "")) {
                Text("Reject")
                    .font(.caption2).bold()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.red.opacity(0.2))
                    .clipShape(Capsule())
            }
            Spacer()
            if let expires = state.approvalExpiresAt {
                Text(timerText(expires))
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }
}

@available(iOSApplicationExtension 16.1, *)
private func statusText(_ status: ClaudeCodeIslandAttributes.Status) -> String {
    switch status {
    case .running: return "RUNNING"
    case .waitingApproval: return "WAITING"
    case .completed: return "DONE"
    case .failed: return "FAILED"
    case .canceled: return "CANCELED"
    }
}

@available(iOSApplicationExtension 16.1, *)
private func shortStatus(_ status: ClaudeCodeIslandAttributes.Status) -> String {
    switch status {
    case .running: return "RUN"
    case .waitingApproval: return "ASK"
    case .completed: return "OK"
    case .failed: return "ERR"
    case .canceled: return "STOP"
    }
}

@available(iOSApplicationExtension 16.1, *)
private func statusColor(_ status: ClaudeCodeIslandAttributes.Status) -> Color {
    switch status {
    case .running: return .blue
    case .waitingApproval: return .orange
    case .completed: return .green
    case .failed: return .red
    case .canceled: return .gray
    }
}

private func elapsed(_ sec: Int) -> String {
    let s = max(0, sec)
    let m = s / 60
    let r = s % 60
    return String(format: "%02d:%02d", m, r)
}

private func timerText(_ expiresAt: Date) -> String {
    let remain = max(0, Int(expiresAt.timeIntervalSinceNow))
    let m = remain / 60
    let s = remain % 60
    return String(format: "%d:%02d", m, s)
}
