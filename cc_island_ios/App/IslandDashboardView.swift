import SwiftUI

struct IslandDashboardView: View {
    @StateObject private var coordinator = BridgeSyncCoordinator()

    var body: some View {
        NavigationStack {
            List {
                Section("Bridge") {
                    if let error = coordinator.lastError, !error.isEmpty {
                        Text(error)
                            .foregroundStyle(.red)
                    } else {
                        Text("Connected")
                            .foregroundStyle(.green)
                    }
                }

                Section("Current Task") {
                    if let task = coordinator.currentTask {
                        LabeledContent("Title", value: task.title)
                        LabeledContent("Status", value: task.status.rawValue)
                        LabeledContent("Model", value: task.model)
                        LabeledContent("Summary", value: task.summary)
                        LabeledContent("Input Tokens", value: String(task.usage.inputTokens))
                        LabeledContent("Output Tokens", value: String(task.usage.outputTokens))
                        LabeledContent("Cost", value: String(format: "$%.4f", task.usage.costUSD))
                    } else {
                        Text("No active task")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Pending Approvals") {
                    if coordinator.approvals.isEmpty {
                        Text("No pending approvals")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(coordinator.approvals, id: \.approvalID) { item in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(item.tool).font(.headline)
                                Text(item.action)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                HStack {
                                    Button("Approve") {
                                        Task { await coordinator.resolveApproval(id: item.approvalID, approved: true) }
                                    }
                                    .buttonStyle(.borderedProminent)

                                    Button("Reject") {
                                        Task { await coordinator.resolveApproval(id: item.approvalID, approved: false) }
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("Claude Code Island")
            .toolbar {
                NavigationLink {
                    BridgeSettingsView()
                } label: {
                    Image(systemName: "gearshape")
                }
            }
        }
        .task { coordinator.start() }
        .onDisappear { coordinator.stop() }
    }
}

#Preview {
    IslandDashboardView()
}
