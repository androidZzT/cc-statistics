import SwiftUI
import AppKit

// MARK: - ConversationView

struct ConversationView: View {
    let sessions: [Session]
    var onClose: () -> Void

    @State private var selectedSession: Session?
    @State private var toastMessage: String?
    @State private var searchText: String = ""

    private var filteredSessions: [Session] {
        let base: [Session]
        if searchText.isEmpty {
            base = sessions
        } else {
            let query = searchText.lowercased()
            base = sessions.filter { session in
                session.messages.contains { msg in
                    msg.content.lowercased().contains(query)
                }
            }
        }
        return base
    }

    var body: some View {
        ZStack {
            HSplitView {
                // Session list
                sessionList
                    .frame(minWidth: 160, idealWidth: 180)

                // Message detail
                if let session = selectedSession {
                    messageDetail(session: session)
                        .frame(minWidth: 220)
                } else {
                    emptySelection
                        .frame(minWidth: 220)
                }
            }

            // Toast overlay
            if let msg = toastMessage {
                VStack {
                    Spacer()
                    Text(msg)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Theme.green.opacity(0.9))
                        )
                        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .padding(.bottom, 16)
                }
                .animation(.easeInOut(duration: 0.25), value: toastMessage != nil)
            }
        }
        .frame(minWidth: 420, minHeight: 400)
        .background(Theme.background)
        .onAppear {
            selectedSession = sessions.first
        }
    }

    // MARK: - Session List

    private var sessionList: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.sessionList)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Text("\(filteredSessions.count)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(Theme.textTertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Theme.cardBackground)
                    )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            // Search field
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textTertiary)
                TextField(L10n.search, text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textPrimary)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.cardBackground)
            )
            .padding(.horizontal, 8)
            .padding(.bottom, 6)

            Divider().background(Theme.border)

            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 2) {
                    ForEach(filteredSessions) { session in
                        sessionRow(session)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .background(Theme.background)
    }

    private func sessionRow(_ session: Session) -> some View {
        let isSelected = selectedSession?.id == session.id
        let userMessages = session.messages.filter { $0.role == "human" || $0.role == "user" }
        let preview = userMessages.first.map { String($0.content.prefix(80)) } ?? L10n.noMessages

        return Button {
            selectedSession = session

            // Copy resume command
            let cmd = "claude --resume \"\(session.sessionName)\""
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(cmd, forType: .string)

            withAnimation {
                toastMessage = "\(L10n.copied): claude --resume"
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation {
                    toastMessage = nil
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    if let start = session.startTime {
                        HStack(spacing: 4) {
                            Text(start, style: .date)
                            Text(start, style: .time)
                        }
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(isSelected ? Theme.cyan : Theme.textSecondary)
                    }
                    Spacer()
                    if let dur = formattedDuration(session.duration) {
                        Text(dur)
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundColor(Theme.textTertiary)
                    }
                }

                Text(preview)
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Text(session.sessionName.prefix(8) + "...")
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundColor(Theme.textTertiary.opacity(0.6))

                    Spacer()

                    Label("\(userMessages.count)", systemImage: "text.bubble")
                    Label("\(session.messages.count)", systemImage: "message")
                }
                .font(.system(size: 9))
                .foregroundColor(Theme.textTertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Theme.cyan.opacity(0.12) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
    }

    // MARK: - Message Detail

    private func messageDetail(session: Session) -> some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    if let start = session.startTime {
                        Text(start, format: .dateTime.month().day().hour().minute())
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Theme.textPrimary)
                    }
                    Text("\(session.messages.count) \(L10n.messagesCount)")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textTertiary)
                }
                Spacer()
                if let duration = formattedDuration(session.duration) {
                    Text(duration)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(Theme.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Theme.cardBackground)
                        )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider().background(Theme.border)

            // Messages
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(session.messages) { message in
                        messageBubble(message)
                    }
                }
                .padding(12)
            }
        }
        .background(Theme.background)
    }

    private func messageBubble(_ message: Message) -> some View {
        let isUser = message.role == "human" || message.role == "user"
        let bubbleColor = isUser ? Theme.cyan.opacity(0.1) : Theme.purple.opacity(0.1)
        let borderColor = isUser ? Theme.cyan.opacity(0.2) : Theme.purple.opacity(0.2)
        let roleLabel = isUser ? L10n.you : L10n.assistant
        let roleColor = isUser ? Theme.cyan : Theme.purple

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: isUser ? "person.fill" : "cpu")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(roleColor)
                Text(roleLabel)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(roleColor)
                Spacer()
                if let ts = message.timestamp {
                    Text(ts, style: .time)
                        .font(.system(size: 9))
                        .foregroundColor(Theme.textTertiary)
                }
            }

            Text(message.content.prefix(500))
                .font(.system(size: 11))
                .foregroundColor(Theme.textPrimary)
                .textSelection(.enabled)
                .lineLimit(12)

            if !message.toolCalls.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "hammer.fill")
                        .font(.system(size: 8))
                    Text("\(message.toolCalls.count) \(L10n.toolCallsCount)")
                        .font(.system(size: 9, weight: .medium))
                }
                .foregroundColor(Theme.textTertiary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(bubbleColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(borderColor, lineWidth: 0.5)
                )
        )
    }

    // MARK: - Empty Selection

    private var emptySelection: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 32, weight: .light))
                .foregroundColor(Theme.textTertiary)
            Text(L10n.selectSession)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private func formattedDuration(_ seconds: TimeInterval) -> String? {
        guard seconds > 0 else { return nil }
        let totalSeconds = Int(seconds)
        if totalSeconds < 60 {
            return "\(totalSeconds)s"
        } else if totalSeconds < 3600 {
            let m = totalSeconds / 60
            let s = totalSeconds % 60
            return s > 0 ? "\(m)m \(s)s" : "\(m)m"
        } else {
            let h = totalSeconds / 3600
            let m = (totalSeconds % 3600) / 60
            return m > 0 ? "\(h)h \(m)m" : "\(h)h"
        }
    }
}
