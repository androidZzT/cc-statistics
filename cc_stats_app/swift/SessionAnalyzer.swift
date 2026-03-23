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

    static func analyze(sessions: [Session], since: Date? = nil) -> SessionStats {
        let perSession = sessions.map { analyzeSession($0, since: since) }
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
                mergedTokenUsage[model, default: TokenDetail()] += detail
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

    private static func analyzeSession(_ session: Session, since: Date? = nil) -> SessionStats {
        // 按时间窗口过滤消息：只统计 since 之后的消息
        let messages: [Message]
        if let since = since {
            messages = session.messages.filter { msg in
                guard let ts = msg.timestamp else { return false }
                return ts >= since
            }
        } else {
            messages = session.messages
        }
        let userInstructions = countUserInstructions(messages)
        let toolCalls = countToolCalls(messages)
        let duration = calculateDuration(messages)
        let codeChanges = collectCodeChanges(messages)
        let tokenUsage = aggregateTokenUsage(messages)

        return SessionStats(
            userInstructions: userInstructions,
            toolCalls: toolCalls,
            totalDuration: duration.total,
            aiProcessingTime: duration.aiProcessing,
            userActiveTime: duration.userActive,
            codeChanges: codeChanges,
            tokenUsage: tokenUsage,
            sessionCount: 1,
            gitCommits: 0,
            gitAdditions: 0,
            gitDeletions: 0
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
                    // Claude: file_path/old_string/new_string
                    // Gemini: target_file/code_edit
                    let filePath = (call.input["file_path"] as? String)
                        ?? (call.input["target_file"] as? String) ?? ""
                    guard !filePath.isEmpty else { continue }
                    var oldStr = call.input["old_string"] as? String ?? ""
                    var newStr = call.input["new_string"] as? String ?? ""
                    if oldStr.isEmpty && newStr.isEmpty {
                        // Gemini edit_file: only code_edit available
                        newStr = call.input["code_edit"] as? String ?? ""
                    }
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
            usage[model, default: TokenDetail()] += detail
        }
        return usage
    }

}
