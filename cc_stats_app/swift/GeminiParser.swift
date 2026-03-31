import Foundation

/// Parses Gemini CLI sessions from ~/.gemini/tmp/*/chats/*.json files.
/// Gemini stores sessions as single JSON files with sessionId, messages[], etc.
final class GeminiParser {

    private let fileManager = FileManager.default
    private let geminiHome: String

    /// Gemini tool name → cc-stats unified name
    private static let toolNameMap: [String: String] = [
        "read_file": "Read",
        "read_many_files": "Read",
        "edit_file": "Edit",
        "write_file": "Write",
        "shell": "Bash",
        "glob": "Glob",
        "grep": "Grep",
        "list_directory": "Glob",
        "web_search": "WebSearch",
        "web_fetch": "WebFetch",
    ]

    init(geminiHome: String? = nil) {
        if let custom = geminiHome {
            self.geminiHome = custom
        } else {
            let home = fileManager.homeDirectoryForCurrentUser.path
            self.geminiHome = (home as NSString).appendingPathComponent(".gemini")
        }
    }

    // MARK: - Public API

    func findAllProjects() -> [ProjectInfo] {
        let sessions = parseAllSessions()
        var projectMap: [String: (count: Int, lastActive: Date?)] = [:]

        for session in sessions {
            let projectName = session.projectPath ?? "Unknown"
            let existing = projectMap[projectName] ?? (count: 0, lastActive: nil)
            let sessionEnd = session.endTime
            let latest: Date?
            if let a = existing.lastActive, let b = sessionEnd {
                latest = max(a, b)
            } else {
                latest = existing.lastActive ?? sessionEnd
            }
            projectMap[projectName] = (count: existing.count + 1, lastActive: latest)
        }

        return projectMap.map { key, value in
            ProjectInfo(
                name: (key as NSString).lastPathComponent,
                path: key,
                sessionCount: value.count,
                lastActive: value.lastActive
            )
        }.sorted { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }
    }

    func parseAllSessions() -> [Session] {
        let tmpDir = (geminiHome as NSString).appendingPathComponent("tmp")
        guard fileManager.fileExists(atPath: tmpDir) else { return [] }

        var allFiles: [String] = []
        // Scan ~/.gemini/tmp/*/chats/*.json
        if let projectDirs = try? fileManager.contentsOfDirectory(atPath: tmpDir) {
            for projDir in projectDirs {
                let chatsDir = (tmpDir as NSString)
                    .appendingPathComponent(projDir)
                    .appending("/chats")
                if let files = try? fileManager.contentsOfDirectory(atPath: chatsDir) {
                    for file in files where file.hasSuffix(".json") {
                        allFiles.append((chatsDir as NSString).appendingPathComponent(file))
                    }
                }
            }
        }

        return allFiles.compactMap { parseSessionFile($0) }
    }

    func parseSessions(forProject projectPath: String) -> [Session] {
        return parseAllSessions().filter { $0.projectPath == projectPath }
    }

    /// Returns all JSON session file paths under Gemini directories.
    func allSessionFilePaths() -> [String] {
        let tmpDir = (geminiHome as NSString).appendingPathComponent("tmp")
        guard fileManager.fileExists(atPath: tmpDir) else { return [] }

        var allFiles: [String] = []
        if let projectDirs = try? fileManager.contentsOfDirectory(atPath: tmpDir) {
            for projDir in projectDirs {
                let chatsDir = (tmpDir as NSString)
                    .appendingPathComponent(projDir)
                    .appending("/chats")
                if let files = try? fileManager.contentsOfDirectory(atPath: chatsDir) {
                    for file in files where file.hasSuffix(".json") {
                        allFiles.append((chatsDir as NSString).appendingPathComponent(file))
                    }
                }
            }
        }
        return allFiles
    }

    /// Parse a single session file at the given path (public entry point for incremental parsing).
    func parseSessionFile(atPath filePath: String) -> Session? {
        return parseSessionFile(filePath)
    }

    // MARK: - JSON Parsing

    private func parseSessionFile(_ filePath: String) -> Session? {
        guard let data = fileManager.contents(atPath: filePath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        guard let messageRecords = json["messages"] as? [[String: Any]] else {
            return nil
        }

        let dirs = json["directories"] as? [String]
        let projectPath = dirs?.first

        var messages: [Message] = []

        for record in messageRecords {
            let type = record["type"] as? String ?? ""
            let timestamp = parseTimestamp(record["timestamp"] as? String)

            switch type {
            case "user":
                let content = extractContent(record["content"])
                messages.append(Message(
                    role: "user",
                    content: content,
                    timestamp: timestamp
                ))

            case "gemini":
                let content = extractContent(record["content"])
                let model = record["model"] as? String

                // Extract tool calls
                var toolCalls: [ToolCall] = []
                if let tcs = record["toolCalls"] as? [[String: Any]] {
                    for tc in tcs {
                        let rawName = tc["name"] as? String ?? ""
                        let mappedName = GeminiParser.toolNameMap[rawName] ?? rawName
                        let args = tc["args"] as? [String: Any] ?? [:]
                        let tcTimestamp = parseTimestamp(tc["timestamp"] as? String) ?? timestamp
                        toolCalls.append(ToolCall(
                            name: mappedName,
                            timestamp: tcTimestamp,
                            input: args
                        ))
                    }
                }

                // Extract token usage
                var tokenUsage: TokenDetail?
                if let tokens = record["tokens"] as? [String: Any] {
                    let input = tokens["input"] as? Int ?? 0
                    let output = tokens["output"] as? Int ?? 0
                    let cached = tokens["cached"] as? Int ?? 0
                    if input > 0 || output > 0 {
                        tokenUsage = TokenDetail(
                            inputTokens: input,
                            outputTokens: output,
                            cacheCreationInputTokens: 0,
                            cacheReadInputTokens: cached
                        )
                    }
                }

                messages.append(Message(
                    role: "assistant",
                    content: content,
                    model: model,
                    timestamp: timestamp,
                    toolCalls: toolCalls,
                    tokenUsage: tokenUsage
                ))

            default:
                // info / error / warning — skip
                break
            }
        }

        guard !messages.isEmpty else { return nil }

        return Session(
            filePath: filePath,
            messages: messages,
            projectPath: projectPath
        )
    }

    // MARK: - Helpers

    private func extractContent(_ raw: Any?) -> String {
        if let str = raw as? String { return str }
        if let parts = raw as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return ""
    }

    private lazy var iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private lazy var iso8601Fallback: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private func parseTimestamp(_ ts: String?) -> Date? {
        guard let ts = ts else { return nil }
        return iso8601Formatter.date(from: ts) ?? iso8601Fallback.date(from: ts)
    }
}
