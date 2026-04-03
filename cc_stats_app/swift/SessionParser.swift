import Foundation

final class SessionParser {

    // MARK: - Properties

    private let fileManager = FileManager.default
    private let claudeProjectsPath: String

    private lazy var iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private lazy var iso8601FallbackFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    // MARK: - Init

    init(claudeProjectsPath: String? = nil) {
        if let custom = claudeProjectsPath {
            self.claudeProjectsPath = custom
        } else {
            let home = fileManager.homeDirectoryForCurrentUser.path
            self.claudeProjectsPath = (home as NSString).appendingPathComponent(".claude/projects")
        }
    }

    // MARK: - Public API

    /// Discover all projects under ~/.claude/projects/ and return basic info for each.
    func findAllProjects() -> [ProjectInfo] {
        guard let projectDirs = try? listDirectories(at: claudeProjectsPath) else {
            return []
        }

        var projects: [ProjectInfo] = []

        for projectDir in projectDirs {
            let projectPath = (claudeProjectsPath as NSString).appendingPathComponent(projectDir)
            let jsonlFiles = findJSONLFiles(in: projectPath)

            guard !jsonlFiles.isEmpty else { continue }

            let lastModified = jsonlFiles.compactMap { filePath -> Date? in
                let attrs = try? fileManager.attributesOfItem(atPath: filePath)
                return attrs?[.modificationDate] as? Date
            }.max()

            let name = decodeProjectDirName(projectDir)

            projects.append(ProjectInfo(
                name: name,
                path: projectPath,
                sessionCount: jsonlFiles.count,
                lastActive: lastModified
            ))
        }

        return projects.sorted { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }
    }

    /// Parse all sessions for a specific project directory path.
    func parseSessions(forProject projectPath: String) -> [Session] {
        let jsonlFiles = findJSONLFiles(in: projectPath)
        return jsonlFiles.compactMap { parseSessionFile($0, projectPath: projectPath) }
    }

    /// Parse all sessions across all projects.
    func parseAllSessions() -> [Session] {
        let projects = findAllProjects()
        return projects.flatMap { parseSessions(forProject: $0.path) }
    }

    /// Returns all JSONL file paths across all projects.
    func allSessionFilePaths() -> [String] {
        guard let projectDirs = try? listDirectories(at: claudeProjectsPath) else { return [] }
        return projectDirs.flatMap { dir -> [String] in
            let projectPath = (claudeProjectsPath as NSString).appendingPathComponent(dir)
            return findJSONLFiles(in: projectPath)
        }
    }

    /// Returns all JSONL file paths for a specific project.
    func allSessionFilePaths(forProject projectPath: String) -> [String] {
        return findJSONLFiles(in: projectPath)
    }

    /// Parse a single session file at the given absolute path (public entry point for incremental parsing).
    func parseSessionFile(atPath filePath: String) -> Session? {
        // Derive projectPath from file's parent directory structure
        // filePath is like: ~/.claude/projects/<encoded-project>/<uuid>.jsonl
        let dir = (filePath as NSString).deletingLastPathComponent
        return parseSessionFile(filePath, projectPath: dir)
    }

    // MARK: - File Discovery

    /// Find top-level .jsonl files in a directory (non-recursive).
    /// Subagent .jsonl files in subdirectories are merged during parent session parsing.
    private func findJSONLFiles(in directory: String) -> [String] {
        guard let contents = try? fileManager.contentsOfDirectory(atPath: directory) else {
            return []
        }
        return contents
            .filter { $0.hasSuffix(".jsonl") }
            .map { (directory as NSString).appendingPathComponent($0) }
    }

    /// List immediate subdirectories of a path.
    private func listDirectories(at path: String) throws -> [String] {
        let contents = try fileManager.contentsOfDirectory(atPath: path)
        return contents.filter { item in
            var isDir: ObjCBool = false
            let fullPath = (path as NSString).appendingPathComponent(item)
            return fileManager.fileExists(atPath: fullPath, isDirectory: &isDir) && isDir.boolValue
        }
    }

    // MARK: - JSONL Parsing

    /// Parse a single JSONL session file into a Session object.
    private func parseSessionFile(_ filePath: String, projectPath: String) -> Session? {
        guard let data = fileManager.contents(atPath: filePath),
              let content = String(data: data, encoding: .utf8) else {
            return nil
        }

        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        var messages: [Message] = []

        for line in lines {
            if let message = parseLine(line) {
                messages.append(message)
            }
        }

        guard !messages.isEmpty else { return nil }

        // Merge subagent messages into the parent session
        let sessionId = ((filePath as NSString).lastPathComponent as NSString).deletingPathExtension
        let sessionDir = (projectPath as NSString).appendingPathComponent(sessionId)
        let subagentsDir = (sessionDir as NSString).appendingPathComponent("subagents")
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: subagentsDir, isDirectory: &isDir), isDir.boolValue {
            if let agentFiles = try? fileManager.contentsOfDirectory(atPath: subagentsDir) {
                for agentFile in agentFiles where agentFile.hasSuffix(".jsonl") {
                    let agentFilePath = (subagentsDir as NSString).appendingPathComponent(agentFile)
                    guard let agentData = fileManager.contents(atPath: agentFilePath),
                          let agentContent = String(data: agentData, encoding: .utf8) else {
                        continue
                    }
                    let agentLines = agentContent.components(separatedBy: CharacterSet.newlines).filter { !$0.isEmpty }
                    for agentLine in agentLines {
                        if let message = parseLine(agentLine) {
                            messages.append(message)
                        }
                    }
                }
            }
        }

        // 流式去重：同一条 API 消息可能写多条 JSONL 记录（含 subagent 消息）
        messages = deduplicateMessages(messages)

        let decodedProjectPath = decodeProjectPath(from: projectPath)

        return Session(
            filePath: filePath,
            messages: messages,
            projectPath: decodedProjectPath
        )
    }

    /// Parse a single JSONL line into a Message, if possible.
    private func parseLine(_ line: String) -> Message? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // Extract the top-level type field
        guard let type = json["type"] as? String else { return nil }

        // Map JSONL types to roles
        let role: String
        switch type {
        case "user", "human":
            role = "user"
        case "assistant":
            role = "assistant"
        case "tool_result":
            role = "tool_result"
        default:
            // Skip system messages, summary, etc.
            return nil
        }

        // Extract timestamp
        let timestamp = parseTimestamp(from: json)

        // Extract the nested message object (if present)
        let messageObj = json["message"] as? [String: Any]

        // Extract model
        let model = messageObj?["model"] as? String

        // Extract content, tool calls, and tool result info
        var (content, toolCalls, toolResultInfos) = extractContent(from: messageObj, timestamp: timestamp)

        // Top-level tool_result messages carry tool_use_id and is_error directly
        if type == "tool_result",
           let tuId = json["tool_use_id"] as? String {
            let isError = json["is_error"] as? Bool ?? false
            toolResultInfos.append(ToolResultInfo(toolUseId: tuId, isError: isError))
        }

        // Extract token usage
        let tokenUsage = extractTokenUsage(from: messageObj)

        // Extract API message ID for deduplication
        let messageId = messageObj?["id"] as? String

        // Detect tool_result and meta messages
        let isToolResult = (type == "tool_result") || checkIsToolResult(messageObj)
        let isMeta = json["isMeta"] as? Bool ?? false

        return Message(
            role: role,
            content: content,
            model: model,
            timestamp: timestamp,
            toolCalls: toolCalls,
            toolResultInfos: toolResultInfos,
            tokenUsage: tokenUsage,
            isToolResult: isToolResult,
            isMeta: isMeta,
            messageId: messageId
        )
    }

    /// 按 messageId 去重 assistant 消息，保留 outputTokens 最大的记录。
    /// Claude Code 流式写入时，同一条消息会产生 prefill（outputTokens=1）+ final（实际值）多条记录。
    private func deduplicateMessages(_ messages: [Message]) -> [Message] {
        var bestByMsgId: [String: (index: Int, outputTokens: Int)] = [:]
        var indicesToRemove = Set<Int>()

        for (i, msg) in messages.enumerated() {
            guard msg.role == "assistant",
                  let msgId = msg.messageId,
                  let usage = msg.tokenUsage else {
                continue
            }

            if let existing = bestByMsgId[msgId] {
                if usage.outputTokens > existing.outputTokens {
                    indicesToRemove.insert(existing.index)
                    bestByMsgId[msgId] = (index: i, outputTokens: usage.outputTokens)
                } else {
                    indicesToRemove.insert(i)
                }
            } else {
                bestByMsgId[msgId] = (index: i, outputTokens: usage.outputTokens)
            }
        }

        guard !indicesToRemove.isEmpty else { return messages }
        return messages.enumerated().compactMap { indicesToRemove.contains($0.offset) ? nil : $0.element }
    }

    /// Check if message content contains tool_result blocks
    private func checkIsToolResult(_ messageObj: [String: Any]?) -> Bool {
        guard let content = messageObj?["content"] else { return false }
        if let arr = content as? [[String: Any]] {
            return arr.contains { ($0["type"] as? String) == "tool_result" }
        }
        return false
    }

    // MARK: - Content Extraction

    /// Extract text content, tool calls, and tool result info from a message object.
    private func extractContent(
        from messageObj: [String: Any]?,
        timestamp: Date?
    ) -> (String, [ToolCall], [ToolResultInfo]) {
        guard let messageObj = messageObj else { return ("", [], []) }

        // Content can be a string or an array of content blocks
        if let textContent = messageObj["content"] as? String {
            return (textContent, [], [])
        }

        guard let contentBlocks = messageObj["content"] as? [[String: Any]] else {
            return ("", [], [])
        }

        var textParts: [String] = []
        var toolCalls: [ToolCall] = []
        var toolResultInfos: [ToolResultInfo] = []

        for block in contentBlocks {
            guard let blockType = block["type"] as? String else { continue }

            switch blockType {
            case "text":
                if let text = block["text"] as? String {
                    textParts.append(text)
                }

            case "tool_use":
                let name = block["name"] as? String ?? "unknown"
                let tuId = block["id"] as? String
                let input = block["input"] as? [String: Any]
                let inputLength: Int
                if let input = input,
                   let inputData = try? JSONSerialization.data(withJSONObject: input) {
                    inputLength = inputData.count
                } else {
                    inputLength = 0
                }

                toolCalls.append(ToolCall(
                    name: name,
                    timestamp: timestamp,
                    inputLength: inputLength,
                    input: input ?? [:],
                    toolUseId: tuId
                ))

            case "tool_result":
                if let tuId = block["tool_use_id"] as? String {
                    let isError = block["is_error"] as? Bool ?? false
                    toolResultInfos.append(ToolResultInfo(toolUseId: tuId, isError: isError))
                }
                if let text = block["content"] as? String {
                    textParts.append(text)
                } else if let resultBlocks = block["content"] as? [[String: Any]] {
                    for resultBlock in resultBlocks {
                        if let text = resultBlock["text"] as? String {
                            textParts.append(text)
                        }
                    }
                }

            default:
                break
            }
        }

        return (textParts.joined(separator: "\n"), toolCalls, toolResultInfos)
    }

    // MARK: - Token Usage Extraction

    /// Extract token usage from the message's usage field.
    private func extractTokenUsage(from messageObj: [String: Any]?) -> TokenDetail? {
        guard let usage = messageObj?["usage"] as? [String: Any] else { return nil }

        let inputTokens = usage["input_tokens"] as? Int ?? 0
        let outputTokens = usage["output_tokens"] as? Int ?? 0
        let cacheCreation = usage["cache_creation_input_tokens"] as? Int ?? 0
        let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0

        // Only return if there's actual usage data
        guard inputTokens > 0 || outputTokens > 0 || cacheCreation > 0 || cacheRead > 0 else {
            return nil
        }

        return TokenDetail(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationInputTokens: cacheCreation,
            cacheReadInputTokens: cacheRead
        )
    }

    // MARK: - Timestamp Parsing

    /// Parse an ISO8601 timestamp from the JSONL entry.
    private func parseTimestamp(from json: [String: Any]) -> Date? {
        guard let timestampStr = json["timestamp"] as? String else { return nil }
        return iso8601Formatter.date(from: timestampStr)
            ?? iso8601FallbackFormatter.date(from: timestampStr)
    }

    // MARK: - Project Path Decoding

    /// 从 JSONL 文件的 cwd 字段提取项目文件夹名称
    private func decodeProjectDirName(_ dirName: String) -> String {
        let projectPath = (claudeProjectsPath as NSString).appendingPathComponent(dirName)
        let jsonlFiles = findJSONLFiles(in: projectPath)

        // 从第一个 JSONL 文件中读取 cwd 字段
        for filePath in jsonlFiles.prefix(1) {
            guard let data = fileManager.contents(atPath: filePath),
                  let content = String(data: data, encoding: .utf8) else { continue }
            for line in content.components(separatedBy: .newlines) where !line.isEmpty {
                guard let lineData = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      let cwd = json["cwd"] as? String, !cwd.isEmpty else { continue }
                // 取路径最后一段作为项目名
                return (cwd as NSString).lastPathComponent
            }
        }

        // fallback: 目录名本身
        return dirName
    }

    /// Try to reconstruct the original project path from the encoded directory name.
    private func decodeProjectPath(from projectDirPath: String) -> String? {
        let dirName = (projectDirPath as NSString).lastPathComponent
        // Convert encoded directory name back to a file path
        let decoded = dirName.replacingOccurrences(of: "-", with: "/")
        // Check if the decoded path is a valid directory
        if decoded.hasPrefix("/") {
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: decoded, isDirectory: &isDir), isDir.boolValue {
                return decoded
            }
        }
        return nil
    }
}
