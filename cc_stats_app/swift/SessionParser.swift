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

    // MARK: - File Discovery

    /// Find all .jsonl files recursively within a directory.
    private func findJSONLFiles(in directory: String) -> [String] {
        guard let enumerator = fileManager.enumerator(atPath: directory) else {
            return []
        }

        var files: [String] = []
        while let element = enumerator.nextObject() as? String {
            if element.hasSuffix(".jsonl") {
                files.append((directory as NSString).appendingPathComponent(element))
            }
        }
        return files
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

        // Extract content and tool calls
        let (content, toolCalls) = extractContent(from: messageObj, timestamp: timestamp)

        // Extract token usage
        let tokenUsage = extractTokenUsage(from: messageObj)

        return Message(
            role: role,
            content: content,
            model: model,
            timestamp: timestamp,
            toolCalls: toolCalls,
            tokenUsage: tokenUsage
        )
    }

    // MARK: - Content Extraction

    /// Extract text content and tool calls from a message object.
    private func extractContent(
        from messageObj: [String: Any]?,
        timestamp: Date?
    ) -> (String, [ToolCall]) {
        guard let messageObj = messageObj else { return ("", []) }

        // Content can be a string or an array of content blocks
        if let textContent = messageObj["content"] as? String {
            return (textContent, [])
        }

        guard let contentBlocks = messageObj["content"] as? [[String: Any]] else {
            return ("", [])
        }

        var textParts: [String] = []
        var toolCalls: [ToolCall] = []

        for block in contentBlocks {
            guard let blockType = block["type"] as? String else { continue }

            switch blockType {
            case "text":
                if let text = block["text"] as? String {
                    textParts.append(text)
                }

            case "tool_use":
                let name = block["name"] as? String ?? "unknown"
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
                    input: input ?? [:]
                ))

            case "tool_result":
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

        return (textParts.joined(separator: "\n"), toolCalls)
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
