import Foundation

class SessionAnalyzer {

    // MARK: - Constants

    private static let idleThreshold: TimeInterval = 300 // 5 minutes

    private static let extensionToLanguage: [String: String] = [
        "py": "Python",
        "js": "JavaScript",
        "ts": "TypeScript",
        "swift": "Swift",
        "rs": "Rust",
        "go": "Go",
        "java": "Java",
        "kt": "Kotlin",
        "rb": "Ruby",
        "cpp": "C++",
        "cc": "C++",
        "cxx": "C++",
        "c": "C",
        "h": "C",
        "cs": "C#",
        "php": "PHP",
        "html": "HTML",
        "css": "CSS",
        "scss": "SCSS",
        "json": "JSON",
        "yaml": "YAML",
        "yml": "YAML",
        "md": "Markdown",
        "sh": "Shell",
        "sql": "SQL",
        "dart": "Dart",
        "vue": "Vue",
        "jsx": "JSX",
        "tsx": "TSX",
        "xml": "XML",
        "toml": "TOML",
    ]

    // MARK: - Public API

    static func analyze(sessions: [Session]) -> SessionStats {
        let perSession = sessions.map { analyzeSession($0) }
        return merge(stats: perSession)
    }

    static func merge(stats: [SessionStats]) -> SessionStats {
        guard !stats.isEmpty else {
            return SessionStats(
                userInstructions: 0,
                toolCalls: [:],
                totalDuration: 0,
                aiProcessingTime: 0,
                userActiveTime: 0,
                codeChanges: [],
                tokenUsage: [:],
                sessionCount: 0,
                gitCommits: 0,
                gitAdditions: 0,
                gitDeletions: 0
            )
        }

        var mergedToolCalls: [String: Int] = [:]
        var mergedTokenUsage: [String: TokenDetail] = [:]
        var mergedCodeChanges: [CodeChange] = []
        var totalUserInstructions = 0
        var totalDuration: TimeInterval = 0
        var totalAIProcessingTime: TimeInterval = 0
        var totalUserActiveTime: TimeInterval = 0
        var totalSessionCount = 0
        var totalGitCommits = 0
        var totalGitAdditions = 0
        var totalGitDeletions = 0

        for s in stats {
            totalUserInstructions += s.userInstructions
            totalDuration += s.totalDuration
            totalAIProcessingTime += s.aiProcessingTime
            totalUserActiveTime += s.userActiveTime
            totalSessionCount += s.sessionCount
            totalGitCommits += s.gitCommits
            totalGitAdditions += s.gitAdditions
            totalGitDeletions += s.gitDeletions

            for (tool, count) in s.toolCalls {
                mergedToolCalls[tool, default: 0] += count
            }

            for (model, detail) in s.tokenUsage {
                if let existing = mergedTokenUsage[model] {
                    mergedTokenUsage[model] = TokenDetail(
                        inputTokens: existing.inputTokens + detail.inputTokens,
                        outputTokens: existing.outputTokens + detail.outputTokens,
                        cacheCreationInputTokens: existing.cacheCreationInputTokens + detail.cacheCreationInputTokens,
                        cacheReadInputTokens: existing.cacheReadInputTokens + detail.cacheReadInputTokens
                    )
                } else {
                    mergedTokenUsage[model] = detail
                }
            }

            mergedCodeChanges.append(contentsOf: s.codeChanges)
        }

        return SessionStats(
            userInstructions: totalUserInstructions,
            toolCalls: mergedToolCalls,
            totalDuration: totalDuration,
            aiProcessingTime: totalAIProcessingTime,
            userActiveTime: totalUserActiveTime,
            codeChanges: mergedCodeChanges,
            tokenUsage: mergedTokenUsage,
            sessionCount: totalSessionCount,
            gitCommits: totalGitCommits,
            gitAdditions: totalGitAdditions,
            gitDeletions: totalGitDeletions
        )
    }

    // MARK: - Single Session Analysis

    private static func analyzeSession(_ session: Session) -> SessionStats {
        let messages = session.messages
        let userInstructions = countUserInstructions(messages)
        let toolCalls = countToolCalls(messages)
        let duration = calculateDuration(messages)
        let codeChanges = collectCodeChanges(messages)
        let tokenUsage = aggregateTokenUsage(messages)
        let gitStats = collectGitStats(session: session)

        return SessionStats(
            userInstructions: userInstructions,
            toolCalls: toolCalls,
            totalDuration: duration.total,
            aiProcessingTime: duration.aiProcessing,
            userActiveTime: duration.userActive,
            codeChanges: codeChanges,
            tokenUsage: tokenUsage,
            sessionCount: 1,
            gitCommits: gitStats.commits,
            gitAdditions: gitStats.additions,
            gitDeletions: gitStats.deletions
        )
    }

    // MARK: - User Instructions

    private static func countUserInstructions(_ messages: [Message]) -> Int {
        return messages.filter { msg in
            msg.role == "user" && !msg.content.contains("tool_result")
        }.count
    }

    // MARK: - Tool Calls

    private static func countToolCalls(_ messages: [Message]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for msg in messages where msg.role == "assistant" {
            for call in msg.toolCalls {
                // 展开 Skill 和 MCP 工具为具体名称
                var displayName = call.name
                if call.name == "Skill" {
                    let skillName = call.input["skill"] as? String ?? ""
                    if !skillName.isEmpty {
                        displayName = "Skill:\(skillName)"
                    }
                } else if call.name.hasPrefix("mcp__") {
                    let parts = call.name.components(separatedBy: "__")
                    if parts.count >= 3 {
                        displayName = "MCP:\(parts[1])/\(parts[2])"
                    }
                }
                counts[displayName, default: 0] += 1
            }
        }
        return counts
    }

    // MARK: - Duration Calculation

    private struct DurationResult {
        let total: TimeInterval
        let aiProcessing: TimeInterval
        let userActive: TimeInterval
    }

    private static func calculateDuration(_ messages: [Message]) -> DurationResult {
        // 分类带时间戳的消息：user_real / user_tool / assistant
        struct TimedMsg {
            let ts: Date
            let kind: String  // "user_real", "user_tool", "assistant"
        }

        var timedMsgs: [TimedMsg] = []
        for msg in messages {
            guard let ts = msg.timestamp else { continue }
            if msg.role == "user" {
                // tool_result 内容包含 tool_result 关键字
                let isTool = msg.content.contains("tool_result")
                timedMsgs.append(TimedMsg(ts: ts, kind: isTool ? "user_tool" : "user_real"))
            } else if msg.role == "assistant" {
                timedMsgs.append(TimedMsg(ts: ts, kind: "assistant"))
            } else if msg.role == "tool_result" {
                timedMsgs.append(TimedMsg(ts: ts, kind: "user_tool"))
            }
        }

        guard timedMsgs.count >= 2 else {
            return DurationResult(total: 0, aiProcessing: 0, userActive: 0)
        }

        // totalDuration 下面会改为 active time

        // 按轮次切分：每遇到 user_real 开启新轮
        // AI 时长 = 每轮从 user_real 到最后一条 assistant/user_tool 的时间
        // 用户时长 = 上一轮最后响应到本轮 user_real 的间隔（< 5分钟才计入）
        var aiTotal: TimeInterval = 0
        var userTotal: TimeInterval = 0

        var turnStart: Date? = nil
        var turnLastAI: Date? = nil
        var lastAIEnd: Date? = nil

        for msg in timedMsgs {
            if msg.kind == "user_real" {
                // 结算上一轮的 AI 时长
                if let start = turnStart, let lastAI = turnLastAI {
                    aiTotal += lastAI.timeIntervalSince(start)
                }

                // 计算用户时长（上一轮 AI 结束 → 本轮 user_real）
                if let end = lastAIEnd {
                    let gap = msg.ts.timeIntervalSince(end)
                    if gap > 0 && gap <= idleThreshold {
                        userTotal += gap
                    }
                }

                // 更新上一轮终点
                if let lastAI = turnLastAI {
                    lastAIEnd = lastAI
                }

                turnStart = msg.ts
                turnLastAI = nil
            } else {
                // assistant 或 user_tool，都算 AI 处理中
                turnLastAI = msg.ts
            }
        }

        // 结算最后一轮
        if let start = turnStart, let lastAI = turnLastAI {
            aiTotal += lastAI.timeIntervalSince(start)
        }

        // total = 活跃时长（AI + 用户），而非首尾差
        return DurationResult(
            total: aiTotal + userTotal,
            aiProcessing: aiTotal,
            userActive: userTotal
        )
    }

    // MARK: - Code Changes

    private static func collectCodeChanges(_ messages: [Message]) -> [CodeChange] {
        var changes: [CodeChange] = []
        for msg in messages where msg.role == "assistant" {
            for call in msg.toolCalls {
                if call.name == "Write" {
                    let filePath = call.input["file_path"] as? String ?? ""
                    guard !filePath.isEmpty else { continue }
                    let content = call.input["content"] as? String ?? ""
                    let added = countLines(content)
                    let language = detectLanguage(from: filePath)
                    changes.append(CodeChange(
                        filePath: filePath, language: language,
                        additions: added, deletions: 0
                    ))
                } else if call.name == "Edit" {
                    let filePath = call.input["file_path"] as? String ?? ""
                    guard !filePath.isEmpty else { continue }
                    let oldStr = call.input["old_string"] as? String ?? ""
                    let newStr = call.input["new_string"] as? String ?? ""
                    let added = countLines(newStr)
                    let removed = countLines(oldStr)
                    let language = detectLanguage(from: filePath)
                    changes.append(CodeChange(
                        filePath: filePath, language: language,
                        additions: added, deletions: removed
                    ))
                }
            }
        }
        return changes
    }

    private static func countLines(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return text.trimmingCharacters(in: .newlines)
            .components(separatedBy: .newlines).count
    }

    private static func detectLanguage(from filePath: String) -> String {
        let ext = (filePath as NSString).pathExtension.lowercased()
        return extensionToLanguage[ext] ?? "Unknown"
    }

    // MARK: - Token Usage

    private static func aggregateTokenUsage(_ messages: [Message]) -> [String: TokenDetail] {
        var usage: [String: TokenDetail] = [:]
        for msg in messages {
            guard let model = msg.model, let detail = msg.tokenUsage else { continue }
            if let existing = usage[model] {
                usage[model] = TokenDetail(
                    inputTokens: existing.inputTokens + detail.inputTokens,
                    outputTokens: existing.outputTokens + detail.outputTokens,
                    cacheCreationInputTokens: existing.cacheCreationInputTokens + detail.cacheCreationInputTokens,
                    cacheReadInputTokens: existing.cacheReadInputTokens + detail.cacheReadInputTokens
                )
            } else {
                usage[model] = detail
            }
        }
        return usage
    }

    // MARK: - Git Stats

    private struct GitStats {
        let commits: Int
        let additions: Int
        let deletions: Int
    }

    private static func collectGitStats(session: Session) -> GitStats {
        guard let projectPath = session.projectPath else {
            return GitStats(commits: 0, additions: 0, deletions: 0)
        }

        let timestamped = session.messages.compactMap { $0.timestamp }
        guard let startDate = timestamped.min(),
              let endDate = timestamped.max() else {
            return GitStats(commits: 0, additions: 0, deletions: 0)
        }

        let formatter = ISO8601DateFormatter()
        let afterStr = formatter.string(from: startDate)
        let beforeStr = formatter.string(from: endDate)

        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = [
            "log",
            "--numstat",
            "--after=\(afterStr)",
            "--before=\(beforeStr)",
        ]
        process.currentDirectoryURL = URL(fileURLWithPath: projectPath)
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return GitStats(commits: 0, additions: 0, deletions: 0)
        }

        guard process.terminationStatus == 0 else {
            return GitStats(commits: 0, additions: 0, deletions: 0)
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            return GitStats(commits: 0, additions: 0, deletions: 0)
        }

        return parseGitLog(output)
    }

    private static func parseGitLog(_ output: String) -> GitStats {
        var commits = 0
        var additions = 0
        var deletions = 0

        let lines = output.components(separatedBy: "\n")
        for line in lines {
            if line.hasPrefix("commit ") {
                commits += 1
                continue
            }

            // numstat lines: <additions>\t<deletions>\t<file>
            let parts = line.components(separatedBy: "\t")
            if parts.count >= 3 {
                if let add = Int(parts[0]) {
                    additions += add
                }
                if let del = Int(parts[1]) {
                    deletions += del
                }
            }
        }

        return GitStats(commits: commits, additions: additions, deletions: deletions)
    }
}
