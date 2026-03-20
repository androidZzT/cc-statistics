import SwiftUI
import AppKit

// MARK: - ConversationView

struct ConversationView: View {
    let sessions: [Session]
    var onClose: () -> Void

    @State private var selectedSession: Session?
    @State private var toastMessage: String?
    @State private var searchText: String = ""
    @State private var isSelectMode = false
    @State private var selectedMessageIDs: Set<UUID> = []

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
            // 切换会话时退出选择模式
            isSelectMode = false
            selectedMessageIDs.removeAll()

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
                    Button {
                        shareSelectedMessages(session: session)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 9))
                            Text(L10n.isChinese ? "分享(\(selectedMessageIDs.count))" : "Share(\(selectedMessageIDs.count))")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundColor(selectedMessageIDs.isEmpty ? Theme.textTertiary : Theme.cyan)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(selectedMessageIDs.isEmpty ? Theme.cardBackground : Theme.cyan.opacity(0.12))
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedMessageIDs.isEmpty)

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
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(session.messages) { message in
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

                            messageBubble(message)
                        }
                    }
                }
                .padding(12)
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

    private func shareSelectedMessages(session: Session) {
        let selected = session.messages.filter { selectedMessageIDs.contains($0.id) }
        guard !selected.isEmpty else { return }

        // 构建分享卡片视图
        let cardView = ShareCardView(
            messages: selected,
            projectName: session.projectPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "",
            startTime: session.startTime
        )

        // 渲染为图片
        let cardWidth: CGFloat = 520
        let hostingView = NSHostingView(rootView: cardView.frame(width: cardWidth))
        hostingView.frame = NSRect(x: 0, y: 0, width: cardWidth, height: 10000)

        // 计算实际内容高度
        let fittingSize = hostingView.fittingSize
        hostingView.frame = NSRect(x: 0, y: 0, width: cardWidth, height: fittingSize.height)

        guard let bitmapRep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else { return }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmapRep)

        guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else { return }

        // 保存到桌面
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        let fileName = "chat-share-\(selected.count)msgs.png"
        let filePath = desktop.appendingPathComponent(fileName)
        try? pngData.write(to: filePath)

        // 复制图片到剪贴板
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(pngData, forType: .png)

        isSelectMode = false
        selectedMessageIDs.removeAll()

        // 打开图片
        NSWorkspace.shared.open(filePath)

        withAnimation {
            toastMessage = L10n.isChinese ? "已保存到桌面并打开" : "Saved to Desktop"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation {
                toastMessage = nil
            }
        }
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

            MarkdownContentView(text: String(message.content.prefix(2000)))
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
            ForEach(Array(parseSegments().enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .code(let lang, let code):
                    codeBlockView(language: lang, code: code)
                case .text(let md):
                    if !md.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        markdownTextView(md)
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func markdownTextView(_ md: String) -> some View {
        Group {
            if let attr = try? AttributedString(markdown: md, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                Text(attr)
                    .font(.system(size: 12))
                    .foregroundColor(Color.white.opacity(0.88))
                    .lineSpacing(3)
            } else {
                Text(md)
                    .font(.system(size: 12))
                    .foregroundColor(Color.white.opacity(0.88))
                    .lineSpacing(3)
            }
        }
    }

    private func codeBlockView(language: String, code: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !language.isEmpty {
                Text(language)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color.white.opacity(0.4))
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                    .padding(.bottom, 2)
            }
            Text(code)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundColor(Color(hex: "E0E0E0"))
                .lineSpacing(2)
                .padding(.horizontal, 10)
                .padding(.vertical, language.isEmpty ? 8 : 4)
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
    }

    enum Segment {
        case text(String)
        case code(lang: String, code: String)
    }

    private func parseSegments() -> [Segment] {
        var segments: [Segment] = []
        let lines = text.components(separatedBy: "\n")
        var currentText = ""
        var inCodeBlock = false
        var codeLang = ""
        var codeLines: [String] = []

        for line in lines {
            if line.hasPrefix("```") && !inCodeBlock {
                // 进入代码块
                if !currentText.isEmpty {
                    segments.append(.text(currentText))
                    currentText = ""
                }
                inCodeBlock = true
                codeLang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                codeLines = []
            } else if line.hasPrefix("```") && inCodeBlock {
                // 结束代码块
                segments.append(.code(lang: codeLang, code: codeLines.joined(separator: "\n")))
                inCodeBlock = false
                codeLang = ""
                codeLines = []
            } else if inCodeBlock {
                codeLines.append(line)
            } else {
                if !currentText.isEmpty { currentText += "\n" }
                currentText += line
            }
        }

        // 处理未闭合
        if inCodeBlock {
            segments.append(.code(lang: codeLang, code: codeLines.joined(separator: "\n")))
        }
        if !currentText.isEmpty {
            segments.append(.text(currentText))
        }

        return segments
    }
}

// MARK: - Conversation Markdown View (面板用，跟随 Theme 颜色)

struct ConversationMarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(parseSegments().enumerated()), id: \.offset) { _, segment in
                switch segment {
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

    enum Segment {
        case text(String)
        case code(lang: String, code: String)
    }

    private func parseSegments() -> [Segment] {
        var segments: [Segment] = []
        let lines = text.components(separatedBy: "\n")
        var currentText = ""
        var inCodeBlock = false
        var codeLang = ""
        var codeLines: [String] = []

        for line in lines {
            if line.hasPrefix("```") && !inCodeBlock {
                if !currentText.isEmpty {
                    segments.append(.text(currentText))
                    currentText = ""
                }
                inCodeBlock = true
                codeLang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                codeLines = []
            } else if line.hasPrefix("```") && inCodeBlock {
                segments.append(.code(lang: codeLang, code: codeLines.joined(separator: "\n")))
                inCodeBlock = false
                codeLang = ""
                codeLines = []
            } else if inCodeBlock {
                codeLines.append(line)
            } else {
                if !currentText.isEmpty { currentText += "\n" }
                currentText += line
            }
        }

        if inCodeBlock {
            segments.append(.code(lang: codeLang, code: codeLines.joined(separator: "\n")))
        }
        if !currentText.isEmpty {
            segments.append(.text(currentText))
        }
        return segments
    }
}
