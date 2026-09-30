import SwiftUI
import AppKit
import WebKit

private enum ShareExportPreset: String, CaseIterable, Identifiable {
    case balanced
    case x
    case linkedIn
    case slack
    case telegram

    var id: String { rawValue }

    var cardWidth: CGFloat {
        switch self {
        case .balanced: return 680
        case .x: return 540
        case .linkedIn: return 720
        case .slack: return 760
        case .telegram: return 800
        }
    }

    var scale: CGFloat {
        switch self {
        case .balanced: return 2.5
        case .x, .linkedIn, .slack, .telegram: return 2.0
        }
    }

    var maxPagePixelHeight: Int {
        switch self {
        case .balanced: return 2200
        case .x: return 1350
        case .linkedIn: return 1800
        case .slack: return 2400
        case .telegram: return 3000
        }
    }

    var slug: String { rawValue.lowercased() }

    var label: String {
        switch self {
        case .balanced:
            return L10n.isChinese ? "通用高清" : "Balanced"
        case .x:
            return "X"
        case .linkedIn:
            return "LinkedIn"
        case .slack:
            return "Slack"
        case .telegram:
            return "Telegram"
        }
    }
}

private enum ConversationSessionSource: Sendable {
    case claudeCode
    case codex
    case gemini
    case unknown

    static func infer(from session: Session) -> ConversationSessionSource {
        let path = session.filePath.lowercased()
        if path.contains("/.codex/") { return .codex }
        if path.contains("/.gemini/") { return .gemini }
        if path.contains("/.claude/") { return .claudeCode }
        return .unknown
    }

    var title: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .gemini: return "Gemini CLI"
        case .unknown: return L10n.assistant
        }
    }

    var assistantRole: String {
        switch self {
        case .claudeCode: return "Claude"
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        case .unknown: return L10n.assistant
        }
    }

    var shortLabel: String {
        switch self {
        case .claudeCode: return "Claude"
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        case .unknown: return "AI"
        }
    }

    var icon: String {
        switch self {
        case .claudeCode: return "sparkles"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .gemini: return "diamond"
        case .unknown: return "cpu"
        }
    }

    var accent: Color {
        switch self {
        case .claudeCode: return Theme.purple
        case .codex: return Theme.green
        case .gemini: return Theme.cyan
        case .unknown: return Theme.purple
        }
    }

    var shareSlug: String {
        switch self {
        case .claudeCode: return "claude"
        case .codex: return "codex"
        case .gemini: return "gemini"
        case .unknown: return "ai"
        }
    }
}

private enum ConversationSummaryError: LocalizedError {
    case unsupportedSource
    case commandFailed(String)
    case timedOut
    case emptyOutput

    var errorDescription: String? {
        switch self {
        case .unsupportedSource:
            return L10n.isChinese ? "当前来源暂不支持一键总结" : "This source is not supported yet"
        case .commandFailed(let message):
            return message.isEmpty
                ? (L10n.isChinese ? "总结命令执行失败" : "Summary command failed")
                : message
        case .timedOut:
            return L10n.isChinese ? "总结超时，请稍后重试" : "Summary timed out"
        case .emptyOutput:
            return L10n.isChinese ? "总结结果为空" : "Summary output is empty"
        }
    }
}

private enum ConversationSummaryRunner {
    static func run(prompt: String, source: ConversationSessionSource, cwd: String?) throws -> String {
        let args: [String]
        switch source {
        case .claudeCode:
            args = [
                "claude",
                "-p",
                "--output-format", "text",
                "--no-session-persistence",
                "--tools", "",
            ]
        case .codex:
            args = [
                "codex",
                "exec",
                "--skip-git-repo-check",
                "--ephemeral",
                "--sandbox", "read-only",
                "-",
            ]
        case .gemini, .unknown:
            throw ConversationSummaryError.unsupportedSource
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        environment["PATH"] = [home + "/.local/bin", home + "/.cargo/bin", "/opt/homebrew/bin",
                               "/usr/local/bin", environment["PATH"] ?? "/usr/bin:/bin"]
            .joined(separator: ":")
        process.environment = environment
        if let cwd, FileManager.default.fileExists(atPath: cwd) {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }

        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccstats-summary-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: workDirectory) }
        let inputURL = workDirectory.appendingPathComponent("input")
        let outputURL = workDirectory.appendingPathComponent("output")
        let errorURL = workDirectory.appendingPathComponent("error")
        try Data(prompt.utf8).write(to: inputURL)
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let inputHandle = try FileHandle(forReadingFrom: inputURL)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        defer {
            try? inputHandle.close()
            try? outputHandle.close()
            try? errorHandle.close()
        }
        process.standardInput = inputHandle
        process.standardOutput = outputHandle
        process.standardError = errorHandle
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        if exited.wait(timeout: .now() + 120) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                exited.wait()
            }
            throw ConversationSummaryError.timedOut
        }
        let output = String(decoding: try Data(contentsOf: outputURL), as: UTF8.self)
        let error = String(decoding: try Data(contentsOf: errorURL), as: UTF8.self)
        if process.terminationStatus != 0 {
            throw ConversationSummaryError.commandFailed(error.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw ConversationSummaryError.emptyOutput
        }
        return trimmed
    }
}

// MARK: - ConversationView

struct ConversationView: View {
    @ObservedObject var viewModel: StatsViewModel
    var onClose: () -> Void

    @State private var selectedSession: Session?
    @State private var toastMessage: String?
    @State private var searchText: String = ""
    @State private var isSelectMode = false
    @State private var selectedMessageIDs: Set<UUID> = []
    @State private var sharePreset: ShareExportPreset = .balanced
    @State private var isExportingShare = false
    @State private var isSummarizingSession = false
    @State private var summarySessionPath: String?
    @State private var summaryText: String?
    @State private var summaryError: String?
    private var sessions: [Session] { viewModel.conversationSessions }
    private var isLoading: Bool { viewModel.isConversationLoading }

    private var filteredSessions: [Session] {
        let base: [Session]
        if searchText.isEmpty {
            base = sessions
        } else {
            let query = searchText.lowercased()
            base = sessions.filter { session in
                if session.sessionName.lowercased().contains(query) { return true }
                if let project = session.projectPath, project.lowercased().contains(query) { return true }
                return session.messages.contains { msg in
                    !msg.content.isEmpty && msg.content.lowercased().contains(query)
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
        .onChange(of: sessions.map(\.filePath)) { _ in
            guard let selected = selectedSession else {
                selectedSession = sessions.first
                return
            }
            if let updated = sessions.first(where: { $0.filePath == selected.filePath }) {
                selectedSession = updated
            } else {
                selectedSession = sessions.first
            }
        }
    }

    // MARK: - Session List

    private var sessionList: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.sessionList)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                }
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
        let source = source(for: session)
        let visible = visibleMessages(in: session)
        let userMessages = visible.filter { isUserMessage($0) }
        let preview = userMessages.first(where: { !$0.content.isEmpty }).map { String($0.content.prefix(80)) }
            ?? visible.first(where: { !$0.content.isEmpty }).map { String($0.content.prefix(80)) }
            ?? String(session.sessionName.prefix(80))

        return Button {
            selectedSession = session
            // 切换会话时退出选择模式
            isSelectMode = false
            selectedMessageIDs.removeAll()

            if let resume = resumeCommand(for: session) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(resume.command, forType: .string)
                showShareToast("\(L10n.copied): \(resume.label)")
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
                    HStack(spacing: 3) {
                        Image(systemName: source.icon)
                            .font(.system(size: 7, weight: .bold))
                        Text(source.shortLabel)
                            .font(.system(size: 8, weight: .bold))
                    }
                    .foregroundColor(source.accent)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(source.accent.opacity(0.12))
                    )

                    Text(session.sessionName.prefix(8) + "...")
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundColor(Theme.textTertiary.opacity(0.6))

                    Spacer()

                    Label("\(userMessages.count)", systemImage: "text.bubble")
                    Label("\(visible.count)", systemImage: "message")

                    // Context usage badge
                    let ctxPct = session.contextUsagePercent
                    if ctxPct > 0 {
                        let ctxColor = ctxPct >= 80 ? Theme.red : ctxPct >= 50 ? Theme.amber : Theme.green
                        Text(String(format: "ctx %.0f%%", ctxPct))
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundColor(ctxColor)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(ctxColor.opacity(0.15))
                            )
                    }
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
        let source = source(for: session)
        let visible = visibleMessages(in: session)
        let visibleIDs = Set(visible.map(\.id))
        let selectedVisibleCount = selectedMessageIDs.intersection(visibleIDs).count
        let allVisibleSelected = !visibleIDs.isEmpty && visibleIDs.isSubset(of: selectedMessageIDs)

        return VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        HStack(spacing: 4) {
                            Image(systemName: source.icon)
                                .font(.system(size: 8, weight: .bold))
                            Text(source.title)
                                .font(.system(size: 10, weight: .bold))
                        }
                        .foregroundColor(source.accent)

                        if let start = session.startTime {
                            Text(start, format: .dateTime.month().day().hour().minute())
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(Theme.textPrimary)
                        }
                    }
                    Text("\(visible.count) \(L10n.messagesCount)")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textTertiary)
                }
                // Context usage indicator
                let ctxPct = session.contextUsagePercent
                if ctxPct > 0 {
                    let ctxColor = ctxPct >= 80 ? Theme.red : ctxPct >= 50 ? Theme.amber : Theme.green
                    HStack(spacing: 3) {
                        Circle()
                            .fill(ctxColor)
                            .frame(width: 6, height: 6)
                        Text(String(format: "ctx %.0f%%", ctxPct))
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundColor(ctxColor)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(ctxColor.opacity(0.1))
                    )
                }

                Spacer()

                // Select / Share buttons
                if isSelectMode {
                    Menu {
                        ForEach(ShareExportPreset.allCases) { preset in
                            Button {
                                sharePreset = preset
                            } label: {
                                HStack {
                                    Text(preset.label)
                                    if sharePreset == preset {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 9))
                            Text(sharePreset.label)
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundColor(Theme.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Theme.cardBackground)
                        )
                    }
                    .buttonStyle(.plain)

                    Button {
                        toggleAllVisibleMessages(in: session)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: allVisibleSelected ? "xmark.circle" : "checkmark.circle.fill")
                                .font(.system(size: 9))
                            Text(allVisibleSelected
                                 ? (L10n.isChinese ? "取消全选" : "Deselect All")
                                 : (L10n.isChinese ? "全选" : "Select All"))
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundColor(visibleIDs.isEmpty ? Theme.textTertiary : Theme.amber)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(visibleIDs.isEmpty ? Theme.cardBackground : Theme.amber.opacity(0.12))
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(visibleIDs.isEmpty || isExportingShare)

                    Button {
                        shareSelectedMessages(session: session)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 9))
                            Text(L10n.isChinese ? "分享(\(selectedVisibleCount))" : "Share(\(selectedVisibleCount))")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundColor(selectedVisibleCount == 0 ? Theme.textTertiary : Theme.cyan)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(selectedVisibleCount == 0 ? Theme.cardBackground : Theme.cyan.opacity(0.12))
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedVisibleCount == 0 || isExportingShare)

                    Button {
                        exportSelectedMessagesPDF(session: session)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "doc.richtext")
                                .font(.system(size: 9))
                            Text("PDF")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundColor(selectedVisibleCount == 0 ? Theme.textTertiary : Theme.green)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(selectedVisibleCount == 0 ? Theme.cardBackground : Theme.green.opacity(0.12))
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedVisibleCount == 0 || isExportingShare)

                    Button {
                        isSelectMode = false
                        selectedMessageIDs.removeAll()
                    } label: {
                        Text(L10n.isChinese ? "取消" : "Cancel")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(Theme.textTertiary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        summarizeSession(session)
                    } label: {
                        HStack(spacing: 3) {
                            if isSummarizingSession && summarySessionPath == session.filePath {
                                ProgressView()
                                    .controlSize(.small)
                                    .scaleEffect(0.55)
                                    .frame(width: 10, height: 10)
                            } else {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 9))
                            }
                            Text(L10n.isChinese ? "总结" : "Summarize")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundColor(visible.isEmpty ? Theme.textTertiary : source.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(visible.isEmpty ? Theme.cardBackground : source.accent.opacity(0.12))
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(visible.isEmpty || isSummarizingSession)

                    Button {
                        isSelectMode = true
                        selectedMessageIDs.removeAll()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: 9))
                            Text(L10n.isChinese ? "选择" : "Select")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundColor(Theme.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Theme.cardBackground)
                        )
                    }
                    .buttonStyle(.plain)

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
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider().background(Theme.border)

            // Messages
            ScrollView(.vertical, showsIndicators: true) {
                if visible.isEmpty {
                    VStack(spacing: 8) {
                        if isLoading {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(isLoading ? (L10n.isChinese ? "正在加载完整会话..." : "Loading full conversation...")
                             : L10n.noMessages)
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textTertiary)
                        Text(L10n.isChinese ? "已按需懒加载，打开面板后会逐步填充消息内容"
                             : "Messages are loaded on demand after opening the panel")
                            .font(.system(size: 10))
                            .foregroundColor(Theme.textTertiary.opacity(0.8))
                    }
                    .frame(maxWidth: .infinity, minHeight: 160)
                    .padding(.top, 18)
                } else {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if summarySessionPath == session.filePath,
                           isSummarizingSession || summaryText != nil || summaryError != nil {
                            summaryCard(source: source)
                        }

                        ForEach(visible) { message in
                            HStack(spacing: 6) {
                                if isSelectMode {
                                    Button {
                                        toggleMessage(message.id)
                                    } label: {
                                        Image(systemName: selectedMessageIDs.contains(message.id)
                                              ? "checkmark.circle.fill"
                                              : "circle")
                                            .font(.system(size: 14))
                                            .foregroundColor(selectedMessageIDs.contains(message.id)
                                                             ? Theme.cyan
                                                             : Theme.textTertiary.opacity(0.4))
                                    }
                                    .buttonStyle(.plain)
                                }

                                messageBubble(message, source: source)
                            }
                        }
                    }
                    .padding(12)
                }
            }
        }
        .background(Theme.background)
    }

    private func toggleMessage(_ id: UUID) {
        if selectedMessageIDs.contains(id) {
            selectedMessageIDs.remove(id)
        } else {
            selectedMessageIDs.insert(id)
        }
    }

    private func summarizeSession(_ session: Session) {
        guard !isSummarizingSession else { return }
        let source = source(for: session)
        let messages = visibleMessages(in: session)
        guard !messages.isEmpty else { return }

        let prompt = buildSummaryPrompt(session: session, source: source, messages: messages)
        let cwd = session.projectPath
        summarySessionPath = session.filePath
        summaryText = nil
        summaryError = nil
        isSummarizingSession = true

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    try ConversationSummaryRunner.run(prompt: prompt, source: source, cwd: cwd)
                }
            }.value

            guard summarySessionPath == session.filePath else { return }
            isSummarizingSession = false

            switch result {
            case .success(let text):
                summaryText = text
                summaryError = nil
                showShareToast(L10n.isChinese ? "会话总结已生成" : "Summary generated")
            case .failure(let error):
                summaryText = nil
                summaryError = (error as? LocalizedError)?.errorDescription
                    ?? (L10n.isChinese ? "总结失败" : "Summary failed")
            }
        }
    }

    @ViewBuilder
    private func summaryCard(source: ConversationSessionSource) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(source.accent)
                Text(L10n.isChinese ? "会话精简总结" : "Session Summary")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                Spacer()

                if let summaryText, !summaryText.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(summaryText, forType: .string)
                        showShareToast(L10n.isChinese ? "已复制总结" : "Summary copied")
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    summaryText = nil
                    summaryError = nil
                    summarySessionPath = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Theme.textTertiary)
                }
                .buttonStyle(.plain)
            }

            if isSummarizingSession {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(L10n.isChinese ? "正在调用 \(source.title) 生成总结..." : "Generating with \(source.title)...")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textSecondary)
                }
            } else if let summaryError {
                Text(summaryError)
                    .font(.system(size: 10))
                    .foregroundColor(Theme.red)
            } else if let summaryText {
                ConversationMarkdownView(text: summaryText)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(source.accent.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(source.accent.opacity(0.22), lineWidth: 0.6)
                )
        )
    }

    private func shareSelectedMessages(session: Session) {
        let visible = visibleMessages(in: session)
        selectedMessageIDs.formIntersection(Set(visible.map(\.id)))
        let selected = visible.filter { selectedMessageIDs.contains($0.id) }
        guard !selected.isEmpty else { return }
        Task { await exportSelectedMessages(session: session, selectedMessages: selected, asPDF: false) }
    }

    private func exportSelectedMessagesPDF(session: Session) {
        let visible = visibleMessages(in: session)
        selectedMessageIDs.formIntersection(Set(visible.map(\.id)))
        let selected = visible.filter { selectedMessageIDs.contains($0.id) }
        guard !selected.isEmpty else { return }
        Task { await exportSelectedMessages(session: session, selectedMessages: selected, asPDF: true) }
    }

    private func exportSelectedMessages(
        session: Session,
        selectedMessages: [Message],
        asPDF: Bool
    ) async {
        guard !isExportingShare else { return }
        isExportingShare = true
        defer { isExportingShare = false }

        let projectName = session.projectPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        let source = source(for: session)
        let html = buildShareHTML(
            messages: selectedMessages,
            projectName: projectName,
            startTime: session.startTime,
            source: source,
            preset: sharePreset
        )

        let renderer = HTMLShareRenderer(
            viewportWidth: max(360, Int(sharePreset.cardWidth)),
            scale: sharePreset.scale
        )

        do {
            try await renderer.load(html: html)
            let stamp = shareFileStamp()
            let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")

            if asPDF {
                let pdfData = try await renderer.renderPDFData()
                let fileName = "\(source.shareSlug)-chat-share-\(selectedMessages.count)msgs-\(sharePreset.slug)-\(stamp).pdf"
                let filePath = desktop.appendingPathComponent(fileName)
                try pdfData.write(to: filePath, options: .atomic)
                isSelectMode = false
                selectedMessageIDs.removeAll()
                NSWorkspace.shared.open(filePath)
                showShareToast(L10n.isChinese ? "已导出清晰 PDF" : "Exported PDF")
                return
            }

            let pages = try await renderer.renderPNGPages(maxPageHeight: sharePreset.maxPagePixelHeight)
            guard !pages.isEmpty else {
                showShareToast(L10n.isChinese ? "导出失败，请重试" : "Export failed")
                return
            }

            var outputURLs: [URL] = []
            for (index, pngData) in pages.enumerated() {
                let pageSuffix = pages.count > 1 ? "-p\(index + 1)" : ""
                let fileName = "\(source.shareSlug)-chat-share-\(selectedMessages.count)msgs-\(sharePreset.slug)-\(stamp)\(pageSuffix).png"
                let filePath = desktop.appendingPathComponent(fileName)
                try pngData.write(to: filePath, options: .atomic)
                outputURLs.append(filePath)
            }

            if let first = pages.first {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setData(first, forType: .png)
            }

            isSelectMode = false
            selectedMessageIDs.removeAll()

            if let firstURL = outputURLs.first {
                NSWorkspace.shared.open(firstURL)
            }

            let msg = pages.count > 1
                ? (L10n.isChinese ? "已导出 \(pages.count) 张高清图片并复制第一页" : "Exported \(pages.count) HD images")
                : (L10n.isChinese ? "已导出高清图片并复制到剪贴板" : "Exported HD image")
            showShareToast(msg)
        } catch {
            showShareToast(L10n.isChinese ? "导出失败，请重试" : "Export failed")
        }
    }

    private func buildShareHTML(
        messages: [Message],
        projectName: String,
        startTime: Date?,
        source: ConversationSessionSource,
        preset: ShareExportPreset
    ) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let start = startTime.map { formatter.string(from: $0) } ?? ""

        let messageHTML = messages.map { msg in
            let isUser = isUserMessage(msg)
            let role = isUser ? "You" : source.assistantRole
            let roleClass = isUser ? "user" : "assistant"
            let timeText: String
            if let ts = msg.timestamp {
                let t = DateFormatter()
                t.dateFormat = "HH:mm"
                timeText = t.string(from: ts)
            } else {
                timeText = ""
            }
            return """
            <section class="bubble \(roleClass)">
              <header class="meta">
                <span class="role">\(escapeHTML(role))</span>
                <span class="time">\(escapeHTML(timeText))</span>
              </header>
              <article class="content">\(escapeHTML(msg.content))</article>
            </section>
            """
        }.joined(separator: "\n")

        return """
        <!doctype html>
        <html lang="zh-CN">
        <head>
          <meta charset="utf-8" />
          <meta name="viewport" content="width=device-width, initial-scale=1" />
          <style>
            :root {
              --font-main: -apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", "Helvetica Neue", sans-serif;
              --canvas: #0a0a0a;
              --text: #f2f5ff;
              --muted: rgba(255,255,255,0.62);
              --card-bg: #16213E;
              --top-bg: #1A1A2E;
              --footer-bg: #0F3460;
              --card-border: rgba(255,255,255,0.08);
              --card-radius: 12px;
              --bubble-radius: 10px;
              --bubble-user-bg: rgba(0,212,170,0.10);
              --bubble-user-border: rgba(0,212,170,0.28);
              --bubble-assist-bg: rgba(123,97,255,0.10);
              --bubble-assist-border: rgba(123,97,255,0.28);
              --role-user: #00D4AA;
              --role-assist: #8F81FF;
              --content: rgba(255,255,255,0.9);
            }
            body {
              margin: 0;
              background: var(--canvas);
              font-family: var(--font-main);
              color: var(--text);
              padding: 12px;
            }
            .card {
              width: \(Int(preset.cardWidth))px;
              border-radius: var(--card-radius);
              overflow: hidden;
              border: 1px solid var(--card-border);
              background: var(--card-bg);
            }
            .top {
              background: var(--top-bg);
              padding: 16px;
              border-bottom: 1px solid var(--card-border);
            }
            .title { font-size: 14px; font-weight: 700; color: var(--text); margin: 0 0 3px 0; }
            .sub { font-size: 10px; color: var(--muted); display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }
            .preset {
              font-size: 9px;
              padding: 2px 6px;
              border-radius: 999px;
              border: 1px solid var(--card-border);
              color: var(--muted);
            }
            .msgs { padding: 16px; display: flex; flex-direction: column; gap: 10px; }
            .bubble {
              border-radius: var(--bubble-radius);
              padding: 12px;
              border: 1px solid transparent;
            }
            .bubble.user { background: var(--bubble-user-bg); border-color: var(--bubble-user-border); }
            .bubble.assistant { background: var(--bubble-assist-bg); border-color: var(--bubble-assist-border); }
            .meta { display: flex; justify-content: space-between; align-items: center; margin-bottom: 6px; }
            .role { font-size: 11px; font-weight: 700; color: var(--role-assist); }
            .bubble.user .role { color: var(--role-user); }
            .time { font-size: 9px; color: rgba(255,255,255,0.36); font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
            .content {
              font-size: 12px;
              line-height: 1.55;
              color: var(--content);
              white-space: pre-wrap;
              word-break: break-word;
            }
            .footer {
              background: var(--footer-bg);
              padding: 10px 16px;
              display: flex;
              justify-content: space-between;
              font-size: 9px;
              color: rgba(255,255,255,0.3);
              font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
            }

            /* X: 极简黑白，硬边框，报纸感标题 */
            body.theme-x {
              --font-main: "Helvetica Neue", "PingFang SC", Arial, sans-serif;
              --canvas: #0d0d0d;
              --text: #f3f3f3;
              --muted: rgba(243,243,243,0.62);
              --card-bg: #111;
              --top-bg: #000;
              --footer-bg: #000;
              --card-border: rgba(255,255,255,0.22);
              --card-radius: 2px;
              --bubble-radius: 2px;
              --bubble-user-bg: rgba(255,255,255,0.05);
              --bubble-user-border: rgba(255,255,255,0.30);
              --bubble-assist-bg: rgba(255,255,255,0.02);
              --bubble-assist-border: rgba(255,255,255,0.18);
              --role-user: #fff;
              --role-assist: #d8d8d8;
            }
            body.theme-x .title { text-transform: uppercase; letter-spacing: .08em; font-weight: 800; }
            body.theme-x .bubble { box-shadow: inset 0 0 0 1px rgba(255,255,255,0.06); }

            /* LinkedIn: 亮色商务卡片 */
            body.theme-linkedin {
              --font-main: "Avenir Next", "PingFang SC", "Helvetica Neue", sans-serif;
              --canvas: #f3f6fb;
              --text: #0f172a;
              --muted: rgba(15,23,42,0.62);
              --card-bg: #ffffff;
              --top-bg: linear-gradient(135deg, #0a66c2, #005fb8);
              --footer-bg: #eef3fb;
              --card-border: rgba(10,102,194,0.24);
              --card-radius: 16px;
              --bubble-radius: 14px;
              --bubble-user-bg: #e8f3ff;
              --bubble-user-border: #a8cff6;
              --bubble-assist-bg: #f6f8fc;
              --bubble-assist-border: #d9e2f2;
              --role-user: #0a66c2;
              --role-assist: #334155;
              --content: #1f2937;
            }
            body.theme-linkedin .card { box-shadow: 0 14px 32px rgba(15,23,42,0.12); }
            body.theme-linkedin .top { color: #fff; border-bottom: none; }
            body.theme-linkedin .top .title, body.theme-linkedin .top .sub, body.theme-linkedin .top .preset { color: #fff; border-color: rgba(255,255,255,0.35); }
            body.theme-linkedin .time { color: rgba(30,41,59,0.45); }

            /* Slack: 终端频道风，等宽正文，左侧信道条 */
            body.theme-slack {
              --font-main: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace;
              --canvas: #1d1c1d;
              --text: #f8f8f8;
              --muted: rgba(248,248,248,0.65);
              --card-bg: #252327;
              --top-bg: #2c2a30;
              --footer-bg: #2c2a30;
              --card-border: rgba(255,255,255,0.10);
              --card-radius: 10px;
              --bubble-radius: 8px;
              --bubble-user-bg: rgba(46,182,125,0.10);
              --bubble-user-border: rgba(46,182,125,0.36);
              --bubble-assist-bg: rgba(255,255,255,0.04);
              --bubble-assist-border: rgba(255,255,255,0.14);
              --role-user: #2eb67d;
              --role-assist: #f2c744;
            }
            body.theme-slack .bubble { border-left-width: 4px; }
            body.theme-slack .content { font-size: 11px; letter-spacing: .01em; }

            /* Telegram: 轻快蓝白，更圆润聊天气泡 */
            body.theme-telegram {
              --font-main: "SF Pro Rounded", "PingFang SC", -apple-system, sans-serif;
              --canvas: #dceefb;
              --text: #0b1f33;
              --muted: rgba(11,31,51,0.62);
              --card-bg: #f6fbff;
              --top-bg: #5ca9e6;
              --footer-bg: #eaf5ff;
              --card-border: rgba(20,93,161,0.20);
              --card-radius: 20px;
              --bubble-radius: 18px;
              --bubble-user-bg: #dcf8c6;
              --bubble-user-border: rgba(73,174,79,0.25);
              --bubble-assist-bg: #ffffff;
              --bubble-assist-border: rgba(92,169,230,0.35);
              --role-user: #2d8f2d;
              --role-assist: #1f6cb2;
              --content: #0c2a44;
            }
            body.theme-telegram .msgs { background: linear-gradient(180deg, rgba(92,169,230,0.08), rgba(92,169,230,0.02)); }
            body.theme-telegram .time { color: rgba(11,31,51,0.42); }
          </style>
        </head>
        <body class="theme-\(preset.slug)">
          <main class="card">
            <header class="top">
              <h1 class="title">\(escapeHTML(source.title))</h1>
              <div class="sub">
                <span class="preset">\(escapeHTML(preset.label))</span>
                <span>\(escapeHTML(projectName))</span>
                <span>\(escapeHTML(start))</span>
              </div>
            </header>
            <section class="msgs">
              \(messageHTML)
            </section>
            <footer class="footer">
              <span>cc-statistics</span>
              <span>github.com/androidZzT/cc-statistics</span>
            </footer>
          </main>
        </body>
        </html>
        """
    }

    private func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private func shareFileStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private func showShareToast(_ message: String) {
        withAnimation {
            toastMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation {
                toastMessage = nil
            }
        }
    }

    private func messageBubble(_ message: Message, source: ConversationSessionSource) -> some View {
        let isUser = isUserMessage(message)
        let assistantColor = source.accent
        let bubbleColor = isUser ? Theme.cyan.opacity(0.1) : assistantColor.opacity(0.1)
        let borderColor = isUser ? Theme.cyan.opacity(0.2) : assistantColor.opacity(0.2)
        let roleLabel = isUser ? L10n.you : source.assistantRole
        let roleColor = isUser ? Theme.cyan : assistantColor

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: isUser ? "person.fill" : source.icon)
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

            ConversationMarkdownView(text: String(message.content.prefix(800)))

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

    private func source(for session: Session) -> ConversationSessionSource {
        ConversationSessionSource.infer(from: session)
    }

    private func isUserMessage(_ message: Message) -> Bool {
        message.role == "human" || message.role == "user"
    }

    private func isVisibleMessage(_ message: Message) -> Bool {
        !message.isToolResult
            && !message.isMeta
            && !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func visibleMessages(in session: Session) -> [Message] {
        session.messages.filter(isVisibleMessage)
    }

    private func toggleAllVisibleMessages(in session: Session) {
        let ids = Set(visibleMessages(in: session).map(\.id))
        guard !ids.isEmpty else { return }
        selectedMessageIDs.formIntersection(ids)
        if ids.isSubset(of: selectedMessageIDs) {
            selectedMessageIDs.subtract(ids)
        } else {
            selectedMessageIDs.formUnion(ids)
        }
    }

    private func buildSummaryPrompt(
        session: Session,
        source: ConversationSessionSource,
        messages: [Message]
    ) -> String {
        let projectName = session.projectPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Unknown"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let start = session.startTime.map { formatter.string(from: $0) } ?? "Unknown"
        let transcript = compactTranscript(messages: messages, source: source)

        return """
        你是一个严谨的 AI Coding 会话整理助手。请只基于下面的会话内容，把原始对话压缩成一份“过程型精简记录”。不要调用工具，不要读取文件，不要执行命令。

        输出要求：
        - 使用中文。
        - 控制在 800-1200 字以内；如果会话很短，可以更短。
        - 用 Markdown。
        - 重点展示“我们是怎么一路聊到结果的”，而不是只写最终任务报告。
        - 保留用户诉求的变化、用户指出的问题、我们做出的判断、关键决策、最终落地结果。
        - 精简冗余工具过程、重复确认、编译/安装流水账；只有影响决策或结论时才提。
        - 对“关键决策”要单独列出，写清为什么这么定。
        - 如果 transcript 中间被省略，不要假装看到了省略内容。
        - 不要编造会话中没有的信息。

        会话来源：\(source.title)
        项目：\(projectName)
        开始时间：\(start)
        可见消息数：\(messages.count)

        请按这个结构输出：
        ## 一句话概括
        ## 对话过程
        按时间线用 4-8 条 bullet 写出用户诉求如何推进、问题如何暴露、方案如何调整。
        ## 关键决策
        用 bullet 保留关键拍板及原因。
        ## 最终状态
        说明已经完成什么、还剩什么风险或下一步。

        <transcript>
        \(transcript)
        </transcript>
        """
    }

    private func compactTranscript(messages: [Message], source: ConversationSessionSource) -> String {
        let maxMessageChars = 1_800
        let maxTotalChars = 60_000
        let headBudget = 36_000
        let tailBudget = 24_000

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"

        let entries = messages.enumerated().map { index, message -> String in
            let role = isUserMessage(message) ? "User" : source.assistantRole
            var content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if content.count > maxMessageChars {
                content = String(content.prefix(maxMessageChars)) + "\n...[message truncated]"
            }
            let time = message.timestamp.map { timeFormatter.string(from: $0) } ?? "--:--"
            return "### \(String(format: "%03d", index + 1)) \(time) \(role)\n\(content)"
        }

        let full = entries.joined(separator: "\n\n")
        guard full.count > maxTotalChars else { return full }

        var head: [String] = []
        var headCount = 0
        for entry in entries {
            let nextCount = headCount + entry.count + 2
            if nextCount > headBudget { break }
            head.append(entry)
            headCount = nextCount
        }

        var tail: [String] = []
        var tailCount = 0
        for entry in entries.reversed() {
            let nextCount = tailCount + entry.count + 2
            if nextCount > tailBudget { break }
            tail.insert(entry, at: 0)
            tailCount = nextCount
        }

        return """
        \(head.joined(separator: "\n\n"))

        ...[middle of transcript omitted to keep the summary prompt compact]...

        \(tail.joined(separator: "\n\n"))
        """
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func resumeCommand(for session: Session) -> (command: String, label: String)? {
        switch source(for: session) {
        case .claudeCode:
            return ("claude --resume \(shellQuote(session.sessionName))", "claude --resume")
        case .codex:
            return ("codex resume \(shellQuote(codexSessionID(from: session)))", "codex resume")
        case .gemini, .unknown:
            return nil
        }
    }

    private func codexSessionID(from session: Session) -> String {
        let name = session.sessionName
        if let range = name.range(
            of: #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#,
            options: .regularExpression
        ) {
            return String(name[range])
        }
        if name.hasPrefix("rollout-") {
            return String(name.dropFirst("rollout-".count))
        }
        return name
    }

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

// MARK: - HTML Share Renderer

@MainActor
private final class HTMLShareRenderer: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private let viewportWidth: Int
    private let scale: CGFloat
    private var loadContinuation: CheckedContinuation<Void, Error>?

    init(viewportWidth: Int, scale: CGFloat) {
        self.viewportWidth = viewportWidth
        self.scale = scale
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = false
        self.webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.frame = CGRect(x: 0, y: 0, width: CGFloat(viewportWidth), height: 1)
    }

    func load(html: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            loadContinuation = continuation
            webView.loadHTMLString(html, baseURL: nil)
        }
        // 等待一次布局稳定，避免刚加载完抓图出现空白/跳动
        try await Task.sleep(nanoseconds: 120_000_000)
    }

    func renderPNGPages(maxPageHeight: Int) async throws -> [Data] {
        let size = try await contentSize()
        let pageHeight = max(600, maxPageHeight)
        var offsetY: CGFloat = 0
        var pages: [Data] = []

        while offsetY < size.height - 0.5 {
            let thisHeight = min(CGFloat(pageHeight), size.height - offsetY)
            let snapshot = try await webView.snapshotImage(
                rect: CGRect(x: 0, y: offsetY, width: size.width, height: thisHeight),
                scale: scale
            )
            guard let tiff = snapshot.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let pngData = rep.representation(using: .png, properties: [:]) else {
                throw NSError(domain: "ccstats.share", code: 2)
            }
            pages.append(pngData)
            offsetY += thisHeight
        }

        return pages
    }

    func renderPDFData() async throws -> Data {
        let size = try await contentSize()
        if #available(macOS 11.0, *) {
            return try await webView.pdfData(rect: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        }
        return webView.dataWithPDF(inside: CGRect(x: 0, y: 0, width: size.width, height: size.height))
    }

    private func contentSize() async throws -> CGSize {
        let raw = try await webView.evaluateJS("""
        (() => {
          const d = document.documentElement;
          const b = document.body;
          const w = Math.max(d.scrollWidth, b.scrollWidth, d.clientWidth, \(viewportWidth));
          const h = Math.max(d.scrollHeight, b.scrollHeight, d.clientHeight);
          return JSON.stringify({ width: w, height: h });
        })();
        """)

        guard let str = raw as? String,
              let data = str.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let w = obj["width"] as? Double,
              let h = obj["height"] as? Double else {
            throw NSError(domain: "ccstats.share", code: 1)
        }

        let width = max(CGFloat(viewportWidth), CGFloat(w))
        let height = max(1, CGFloat(h))
        webView.frame = CGRect(x: 0, y: 0, width: width, height: height)
        return CGSize(width: width, height: height)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadContinuation?.resume()
        loadContinuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadContinuation?.resume(throwing: error)
        loadContinuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadContinuation?.resume(throwing: error)
        loadContinuation = nil
    }
}

private extension WKWebView {
    func evaluateJS(_ script: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            self.evaluateJavaScript(script) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: result)
            }
        }
    }

    func snapshotImage(rect: CGRect, scale: CGFloat) async throws -> NSImage {
        try await withCheckedThrowingContinuation { continuation in
            let config = WKSnapshotConfiguration()
            config.rect = rect
            config.snapshotWidth = NSNumber(value: Double(rect.width * scale))
            self.takeSnapshot(with: config) { image, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let image else {
                    continuation.resume(throwing: NSError(domain: "ccstats.share", code: 3))
                    return
                }
                continuation.resume(returning: image)
            }
        }
    }

    @available(macOS 11.0, *)
    func pdfData(rect: CGRect) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let config = WKPDFConfiguration()
            config.rect = rect
            self.createPDF(configuration: config) { result in
                switch result {
                case .success(let data):
                    continuation.resume(returning: data)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

// MARK: - Share Card (渲染为长图)

struct ShareCardView: View {
    let messages: [Message]
    let projectName: String
    let startTime: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                // Claude logo circle
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color(hex: "00D4AA"), Color(hex: "7B61FF")],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 28, height: 28)
                    Text("CC")
                        .font(.system(size: 11, weight: .black, design: .rounded))
                        .foregroundColor(.white)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Claude Code")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                    HStack(spacing: 6) {
                        if !projectName.isEmpty {
                            Text(projectName)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(Color.white.opacity(0.6))
                        }
                        if let start = startTime {
                            let formatter: DateFormatter = {
                                let f = DateFormatter()
                                f.dateFormat = "yyyy-MM-dd HH:mm"
                                return f
                            }()
                            Text(formatter.string(from: start))
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundColor(Color.white.opacity(0.5))
                        }
                    }
                }
                Spacer()
            }
            .padding(16)
            .background(Color(hex: "1A1A2E"))

            // Messages
            VStack(alignment: .leading, spacing: 10) {
                ForEach(messages) { msg in
                    shareMessageBubble(msg)
                }
            }
            .padding(16)
            .background(Color(hex: "16213E"))

            // Footer
            HStack {
                Text("cc-statistics")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color.white.opacity(0.3))
                Spacer()
                Text("github.com/androidZzT/cc-statistics")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.25))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(hex: "0F3460"))
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .padding(8)
        .background(Color(hex: "0A0A0A"))
    }

    private func shareMessageBubble(_ message: Message) -> some View {
        let isUser = message.role == "human" || message.role == "user"
        let bgColor = isUser ? Color(hex: "00D4AA").opacity(0.1) : Color(hex: "7B61FF").opacity(0.1)
        let borderColor = isUser ? Color(hex: "00D4AA").opacity(0.25) : Color(hex: "7B61FF").opacity(0.25)
        let roleLabel = isUser ? "You" : "Claude"
        let roleColor = isUser ? Color(hex: "00D4AA") : Color(hex: "7B61FF")

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: isUser ? "person.fill" : "cpu")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(roleColor)
                Text(roleLabel)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(roleColor)
                Spacer()
                if let ts = message.timestamp {
                    let formatter: DateFormatter = {
                        let f = DateFormatter()
                        f.dateFormat = "HH:mm"
                        return f
                    }()
                    Text(formatter.string(from: ts))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(Color.white.opacity(0.35))
                }
            }

            MarkdownContentView(text: message.content)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(bgColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(borderColor, lineWidth: 0.5)
                )
        )
    }
}

// MARK: - Markdown Content Renderer

struct MarkdownContentView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(parseMdSegments(text).enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .heading(let level, let title):
                    let fontSize: CGFloat = level == 1 ? 16 : level == 2 ? 14 : 13
                    Text(title)
                        .font(.system(size: fontSize, weight: .bold))
                        .foregroundColor(Color.white.opacity(0.92))
                        .padding(.top, level == 1 ? 4 : 2)
                case .code(let lang, let code):
                    VStack(alignment: .leading, spacing: 0) {
                        if !lang.isEmpty {
                            Text(lang)
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundColor(Color.white.opacity(0.4))
                                .padding(.horizontal, 10)
                                .padding(.top, 6)
                                .padding(.bottom, 2)
                        }
                        Text(code)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Color(hex: "E0E0E0"))
                            .lineSpacing(2)
                            .padding(.horizontal, 10)
                            .padding(.vertical, lang.isEmpty ? 8 : 4)
                            .padding(.bottom, 4)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                    )
                case .table(let headers, let rows):
                    MdTableView(headers: headers, rows: rows, textColor: Color.white.opacity(0.88), headerColor: Color.white.opacity(0.6), borderColor: Color.white.opacity(0.15))
                case .text(let md):
                    let trimmed = md.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        if let attr = try? AttributedString(markdown: trimmed, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                            Text(attr)
                                .font(.system(size: 12))
                                .foregroundColor(Color.white.opacity(0.88))
                                .lineSpacing(3)
                        } else {
                            Text(trimmed)
                                .font(.system(size: 12))
                                .foregroundColor(Color.white.opacity(0.88))
                                .lineSpacing(3)
                        }
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Shared Markdown Parser

enum MdSegment {
    case text(String)
    case code(lang: String, code: String)
    case heading(level: Int, text: String)
    case table(headers: [String], rows: [[String]])
}

func parseMdSegments(_ text: String) -> [MdSegment] {
    var segments: [MdSegment] = []
    let lines = text.components(separatedBy: "\n")
    var currentText = ""
    var inCodeBlock = false
    var codeLang = ""
    var codeLines: [String] = []
    var tableHeaders: [String] = []
    var tableRows: [[String]] = []
    var inTable = false

    func flushText() {
        if !currentText.isEmpty {
            segments.append(.text(currentText))
            currentText = ""
        }
    }

    func flushTable() {
        if inTable && !tableHeaders.isEmpty {
            segments.append(.table(headers: tableHeaders, rows: tableRows))
            tableHeaders = []
            tableRows = []
            inTable = false
        }
    }

    func parseTableRow(_ line: String) -> [String] {
        return line.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    func isSeparatorRow(_ line: String) -> Bool {
        let cleaned = line.replacingOccurrences(of: " ", with: "")
        return cleaned.contains("|") && cleaned.allSatisfy { $0 == "|" || $0 == "-" || $0 == ":" }
    }

    for line in lines {
        if line.hasPrefix("```") && !inCodeBlock {
            flushText()
            flushTable()
            inCodeBlock = true
            codeLang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            codeLines = []
        } else if line.hasPrefix("```") && inCodeBlock {
            segments.append(.code(lang: codeLang, code: codeLines.joined(separator: "\n")))
            inCodeBlock = false
        } else if inCodeBlock {
            codeLines.append(line)
        } else if line.contains("|") && !inCodeBlock {
            let cells = parseTableRow(line)
            if isSeparatorRow(line) {
                // 分隔行，跳过
                continue
            } else if !inTable {
                flushText()
                tableHeaders = cells
                tableRows = []
                inTable = true
            } else {
                tableRows.append(cells)
            }
        } else {
            flushTable()
            if line.hasPrefix("#") {
                flushText()
                var level = 0
                for ch in line { if ch == "#" { level += 1 } else { break } }
                let title = String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                if !title.isEmpty {
                    segments.append(.heading(level: min(level, 4), text: title))
                }
            } else {
                if !currentText.isEmpty { currentText += "\n" }
                currentText += line
            }
        }
    }

    if inCodeBlock {
        segments.append(.code(lang: codeLang, code: codeLines.joined(separator: "\n")))
    }
    flushTable()
    if !currentText.isEmpty {
        segments.append(.text(currentText))
    }
    return segments
}

// MARK: - Conversation Markdown View (面板用，跟随 Theme 颜色)

struct ConversationMarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(parseMdSegments(text).enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .heading(let level, let title):
                    let fontSize: CGFloat = level == 1 ? 15 : level == 2 ? 13 : 12
                    Text(title)
                        .font(.system(size: fontSize, weight: .bold))
                        .foregroundColor(Theme.textPrimary)
                        .padding(.top, level == 1 ? 4 : 2)
                case .code(let lang, let code):
                    VStack(alignment: .leading, spacing: 0) {
                        if !lang.isEmpty {
                            Text(lang)
                                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                                .foregroundColor(Theme.textTertiary)
                                .padding(.horizontal, 8)
                                .padding(.top, 5)
                                .padding(.bottom, 1)
                        }
                        Text(code)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Theme.textPrimary)
                            .lineSpacing(2)
                            .padding(.horizontal, 8)
                            .padding(.vertical, lang.isEmpty ? 6 : 3)
                            .padding(.bottom, 3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Theme.background.opacity(0.6))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Theme.border.opacity(0.3), lineWidth: 0.5)
                    )
                case .table(let headers, let rows):
                    MdTableView(headers: headers, rows: rows, textColor: Theme.textPrimary, headerColor: Theme.textSecondary, borderColor: Theme.border)
                case .text(let md):
                    let trimmed = md.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        if let attr = try? AttributedString(markdown: trimmed, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                            Text(attr)
                                .font(.system(size: 11))
                                .foregroundColor(Theme.textPrimary)
                                .lineSpacing(2)
                                .textSelection(.enabled)
                        } else {
                            Text(trimmed)
                                .font(.system(size: 11))
                                .foregroundColor(Theme.textPrimary)
                                .lineSpacing(2)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Markdown Table View

struct MdTableView: View {
    let headers: [String]
    let rows: [[String]]
    var textColor: Color = .white
    var headerColor: Color = .gray
    var borderColor: Color = .gray.opacity(0.3)

    var body: some View {
        VStack(spacing: 0) {
            // Header row
            HStack(spacing: 0) {
                ForEach(Array(headers.enumerated()), id: \.offset) { i, header in
                    Text(header)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(headerColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                    if i < headers.count - 1 {
                        Rectangle().fill(borderColor).frame(width: 0.5)
                    }
                }
            }
            .background(borderColor.opacity(0.15))

            Rectangle().fill(borderColor).frame(height: 0.5)

            // Data rows
            ForEach(Array(rows.enumerated()), id: \.offset) { ri, row in
                HStack(spacing: 0) {
                    ForEach(Array(row.prefix(headers.count).enumerated()), id: \.offset) { i, cell in
                        Text(cell)
                            .font(.system(size: 10))
                            .foregroundColor(textColor)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                        if i < headers.count - 1 {
                            Rectangle().fill(borderColor).frame(width: 0.5)
                        }
                    }
                }
                if ri < rows.count - 1 {
                    Rectangle().fill(borderColor).frame(height: 0.5)
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}
