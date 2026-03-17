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
                counts[call.name, default: 0] += 1
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
        let timestamped = messages.filter { $0.timestamp != nil }
        guard timestamped.count >= 2,
              let firstTime = timestamped.first?.timestamp,
              let lastTime = timestamped.last?.timestamp else {
            return DurationResult(total: 0, aiProcessing: 0, userActive: 0)
        }

        let totalDuration = lastTime.timeIntervalSince(firstTime)

        // AI processing time: sum of intervals from user message to next assistant message
        var aiProcessingTime: TimeInterval = 0
        for i in 0..<(timestamped.count - 1) {
            let current = timestamped[i]
            let next = timestamped[i + 1]
            if current.role == "user" && next.role == "assistant",
               let currentTime = current.timestamp,
               let nextTime = next.timestamp {
                aiProcessingTime += nextTime.timeIntervalSince(currentTime)
            }
        }

        // User active time: gaps from assistant's last reply to next user message (review/coding time)
        // Only count gaps < idle threshold (5 min)
        var userActiveTime: TimeInterval = 0
        for i in 0..<(timestamped.count - 1) {
            let current = timestamped[i]
            let next = timestamped[i + 1]
            // Only count assistant → user transitions (user thinking/reviewing time)
            if current.role == "assistant" && next.role == "user",
               let currentTime = current.timestamp,
               let nextTime = next.timestamp {
                let gap = nextTime.timeIntervalSince(currentTime)
                if gap < idleThreshold && gap > 0 {
                    userActiveTime += gap
                }
            }
        }

        return DurationResult(
            total: totalDuration,
            aiProcessing: aiProcessingTime,
            userActive: userActiveTime
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
