import Foundation

/// Parses Codex CLI sessions from ~/.codex/ rollout JSONL files.
/// Codex stores sessions as JSONL with tagged types: session_meta, event_msg, response_item, turn_context.
/// Respects $CODEX_HOME environment variable for custom session storage paths.
final class CodexParser {

    private let fileManager = FileManager.default
    private let codexHome: String
    private static let maxMessageChars = 8_000
    private static let maxSmallInputChars = 200
    private static let toolNameMap: [String: String] = [
        "exec_command": "Bash",
        "write_stdin": "Bash",
        "read_mcp_resource": "Read",
        "list_mcp_resources": "ToolSearch",
        "list_mcp_resource_templates": "ToolSearch",
        "search_query": "WebSearch",
        "image_query": "WebSearch",
        "web.run": "WebSearch",
        "apply_patch": "Edit",
    ]

    init(codexHome: String? = nil) {
        if let custom = codexHome {
            self.codexHome = custom
        } else if let envHome = ProcessInfo.processInfo.environment["CODEX_HOME"] {
            self.codexHome = envHome
        } else {
            let home = fileManager.homeDirectoryForCurrentUser.path
            self.codexHome = (home as NSString).appendingPathComponent(".codex")
        }
    }

    // MARK: - Public API

    func findAllProjects() -> [ProjectInfo] {
        var projectMap: [String: (count: Int, lastActive: Date?)] = [:]

        for filePath in allSessionFilePaths() {
            autoreleasepool {
                let projectName = readProjectPath(fromFile: filePath) ?? "Unknown"
                let existing = projectMap[projectName] ?? (count: 0, lastActive: nil)

                let mtime = (try? fileManager.attributesOfItem(atPath: filePath)[.modificationDate]) as? Date
                let latest: Date?
                if let a = existing.lastActive, let b = mtime {
                    latest = max(a, b)
                } else {
                    latest = existing.lastActive ?? mtime
                }
                projectMap[projectName] = (count: existing.count + 1, lastActive: latest)
            }
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
        let files = allSessionFilePaths()
        var sessions: [Session] = []
        sessions.reserveCapacity(files.count)

        for filePath in files {
            if let session = autoreleasepool(invoking: { parseSessionFile(filePath) }) {
                sessions.append(session)
            }
        }
        return sessions
    }

    func parseSessions(forProject projectPath: String) -> [Session] {
        let files = allSessionFilePaths().filter { readProjectPath(fromFile: $0) == projectPath }
        var sessions: [Session] = []
        sessions.reserveCapacity(files.count)

        for filePath in files {
            if let session = autoreleasepool(invoking: { parseSessionFile(filePath) }) {
                sessions.append(session)
            }
        }
        return sessions
    }

    /// Returns all JSONL file paths under Codex session directories.
    func allSessionFilePaths() -> [String] {
        // Prefer canonical layout: ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl
        let sessionsDir = (codexHome as NSString).appendingPathComponent("sessions")
        var files = collectRolloutFiles(in: sessionsDir)

        // Fallback for older layouts.
        if files.isEmpty {
            files = collectRolloutFiles(in: codexHome)
        }

        return files
    }

    /// Parse a single session file at the given path (public entry point for incremental parsing).
    func parseSessionFile(atPath filePath: String) -> Session? {
        return parseSessionFile(filePath)
    }

    // MARK: - JSONL Parsing

    private func parseSessionFile(_ filePath: String) -> Session? {
        guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else {
            return nil
        }

        var messages: [Message] = []
        var projectPath: String?
        var latestModel: String?
        var seenUserKeys = Set<String>()
        var seenAssistantKeys = Set<String>()
        var lastTotalTokens: Int?
        // 跟踪整个文件里最新一次 OpenAI rate_limits snapshot
        var latestRateLimits: CodexRateLimitsSnapshot?
        var latestRateLimitsTs: Date?

        content.enumerateLines { line, _ in
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                return
            }

            autoreleasepool {
                let tsString = json["timestamp"] as? String
                let ts = self.parseTimestamp(tsString)
                let type = json["type"] as? String ?? ""
                let payload = json["payload"] as? [String: Any]

                switch type {
                case "session_meta":
                    // Extract cwd as project path
                    if let meta = payload ?? json["meta"] as? [String: Any],
                       let cwd = meta["cwd"] as? String {
                        projectPath = cwd
                    } else if let cwd = json["cwd"] as? String {
                        projectPath = cwd
                    }
                    if let model = self.extractModel(from: payload) {
                        latestModel = model
                    }

                case "event_msg":
                    guard let eventPayload = payload else { return }
                    let eventType = eventPayload["type"] as? String ?? ""

                    if eventType == "token_count" {
                        // 优先记录最新 OpenAI rate_limits snapshot（即便 token_usage 是重复的也要更新）
                        if let snapshot = self.parseRateLimitsSnapshot(eventPayload["rate_limits"]) {
                            latestRateLimits = snapshot
                            latestRateLimitsTs = ts
                        }

                        // Codex writes cumulative totals; if total is unchanged, skip duplicate events.
                        if let info = eventPayload["info"] as? [String: Any],
                           let totalUsage = info["total_token_usage"] as? [String: Any] {
                            let total = self.intValue(totalUsage["total_tokens"])
                            if let last = lastTotalTokens, total > 0, total == last {
                                return
                            }
                            if total > 0 {
                                lastTotalTokens = total
                            }
                        }

                        if let usage = self.extractTokenUsage(fromTokenCountPayload: eventPayload) {
                            if let idx = messages.lastIndex(where: { $0.role == "assistant" }) {
                                let mergedUsage = (messages[idx].tokenUsage ?? TokenDetail()) + usage
                                let original = messages[idx]
                                messages[idx] = Message(
                                    role: original.role,
                                    content: original.content,
                                    model: original.model ?? latestModel ?? "unknown",
                                    timestamp: original.timestamp,
                                    toolCalls: original.toolCalls,
                                    toolResultInfos: original.toolResultInfos,
                                    tokenUsage: mergedUsage,
                                    isToolResult: original.isToolResult,
                                    isMeta: original.isMeta,
                                    messageId: original.messageId
                                )
                            } else {
                                messages.append(Message(
                                    role: "assistant",
                                    content: "",
                                    model: latestModel ?? "unknown",
                                    timestamp: ts,
                                    tokenUsage: usage,
                                    isMeta: true
                                ))
                            }
                        }
                    } else if eventType == "user_message" {
                        let content = eventPayload["message"] as? String ?? ""
                        guard !content.isEmpty else { return }
                        let key = "\(tsString ?? "")|u|\(content)"
                        if seenUserKeys.contains(key) { return }
                        seenUserKeys.insert(key)
                        messages.append(Message(
                            role: "user",
                            content: self.truncate(content, maxChars: CodexParser.maxMessageChars),
                            timestamp: ts
                        ))
                    } else if eventType == "agent_message" {
                        let content = eventPayload["message"] as? String ?? ""
                        guard !content.isEmpty else { return }
                        let key = "\(tsString ?? "")|a|\(content)"
                        if seenAssistantKeys.contains(key) { return }
                        seenAssistantKeys.insert(key)
                        messages.append(Message(
                            role: "assistant",
                            content: self.truncate(content, maxChars: CodexParser.maxMessageChars),
                            model: latestModel,
                            timestamp: ts
                        ))
                    }

                case "response_item":
                    guard let item = payload else { return }
                    let itemType = item["type"] as? String ?? ""

                    if itemType == "function_call" {
                        let rawName = item["name"] as? String ?? ""
                        guard !rawName.isEmpty else { return }

                        // apply_patch arguments may contain very large patch text.
                        // Parse only patch metadata and skip full JSON decode of huge blobs.
                        let rawInput: [String: Any]
                        if rawName == "apply_patch" {
                            rawInput = self.parseApplyPatchInput(item["arguments"])
                        } else {
                            rawInput = self.parseJSONDictionary(item["arguments"])
                        }
                        let mapped = CodexParser.toolNameMap[rawName] ?? rawName
                        let input = self.compactToolInput(name: mapped, input: rawInput)

                        let inputLength: Int
                        if let inputData = try? JSONSerialization.data(withJSONObject: input) {
                            inputLength = inputData.count
                        } else {
                            inputLength = 0
                        }

                        let toolCall = ToolCall(
                            name: mapped,
                            timestamp: ts,
                            inputLength: inputLength,
                            input: input,
                            toolUseId: item["call_id"] as? String
                        )
                        messages.append(Message(
                            role: "assistant",
                            content: "",
                            model: latestModel,
                            timestamp: ts,
                            toolCalls: [toolCall]
                        ))
                        return
                    }

                    if itemType == "web_search_call" {
                        let action = item["action"] as? [String: Any] ?? [:]
                        let toolCall = ToolCall(
                            name: "WebSearch",
                            timestamp: ts,
                            input: action
                        )
                        messages.append(Message(
                            role: "assistant",
                            content: "",
                            model: latestModel,
                            timestamp: ts,
                            toolCalls: [toolCall]
                        ))
                        return
                    }

                    if itemType == "message" {
                        let role = item["role"] as? String ?? "assistant"
                        let itemModel = item["model"] as? String
                        if let m = itemModel { latestModel = m }

                        let textContent = self.extractTextContent(item["content"])
                        if role == "user" {
                            if textContent.isEmpty || self.isMetaUserText(textContent) {
                                return
                            }
                            let key = "\(tsString ?? "")|u|\(textContent)"
                            if seenUserKeys.contains(key) { return }
                            seenUserKeys.insert(key)
                            messages.append(Message(
                                role: "user",
                                content: self.truncate(textContent, maxChars: CodexParser.maxMessageChars),
                                timestamp: ts
                            ))
                        } else if role == "assistant" {
                            guard !textContent.isEmpty else { return }
                            let key = "\(tsString ?? "")|a|\(textContent)"
                            if seenAssistantKeys.contains(key) { return }
                            seenAssistantKeys.insert(key)
                            messages.append(Message(
                                role: "assistant",
                                content: self.truncate(textContent, maxChars: CodexParser.maxMessageChars),
                                model: itemModel ?? latestModel,
                                timestamp: ts
                            ))
                        }
                    }

                case "turn_context":
                    // turn_context has the active model for this turn.
                    if let model = self.extractModel(from: payload) {
                        latestModel = model
                    }

                default:
                    break
                }
            }
        }

        guard !messages.isEmpty else { return nil }

        return Session(
            filePath: filePath,
            messages: messages,
            projectPath: projectPath,
            codexRateLimits: latestRateLimits,
            codexRateLimitsTs: latestRateLimitsTs
        )
    }

    /// 把 event_msg/token_count.rate_limits 这块 JSON 翻译成强类型 snapshot。
    /// 缺字段或字段类型不对时返回 nil（容错，避免因一条脏数据丢掉整次解析）。
    private func parseRateLimitsSnapshot(_ raw: Any?) -> CodexRateLimitsSnapshot? {
        guard let dict = raw as? [String: Any] else { return nil }
        let primary = parseRateLimitWindow(dict["primary"])
        let secondary = parseRateLimitWindow(dict["secondary"])
        if primary == nil && secondary == nil { return nil }
        return CodexRateLimitsSnapshot(primary: primary, secondary: secondary)
    }

    private func parseRateLimitWindow(_ raw: Any?) -> CodexRateLimitWindow? {
        guard let dict = raw as? [String: Any] else { return nil }
        guard let pctRaw = dict["used_percent"] else { return nil }

        let usedPercent: Double
        if let d = pctRaw as? Double { usedPercent = d }
        else if let n = pctRaw as? NSNumber { usedPercent = n.doubleValue }
        else if let s = pctRaw as? String, let d = Double(s) { usedPercent = d }
        else { return nil }
        guard usedPercent >= 0 else { return nil }

        let windowMinutes: Int?
        if let n = dict["window_minutes"] as? NSNumber { windowMinutes = n.intValue }
        else if let i = dict["window_minutes"] as? Int { windowMinutes = i }
        else { windowMinutes = nil }

        let resetsAt: Date?
        if let n = dict["resets_at"] as? NSNumber {
            resetsAt = Date(timeIntervalSince1970: n.doubleValue)
        } else if let i = dict["resets_at"] as? Int {
            resetsAt = Date(timeIntervalSince1970: Double(i))
        } else if let s = dict["resets_at"] as? String, let i = Int(s) {
            resetsAt = Date(timeIntervalSince1970: Double(i))
        } else {
            resetsAt = nil
        }

        return CodexRateLimitWindow(
            usedPercent: usedPercent,
            windowMinutes: windowMinutes,
            resetsAt: resetsAt
        )
    }

    // MARK: - Helpers

    private func collectRolloutFiles(in rootDir: String) -> [String] {
        guard fileManager.fileExists(atPath: rootDir) else { return [] }
        guard let enumerator = fileManager.enumerator(atPath: rootDir) else { return [] }

        var files: [String] = []
        while let element = enumerator.nextObject() as? String {
            let name = (element as NSString).lastPathComponent
            guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") else { continue }
            files.append((rootDir as NSString).appendingPathComponent(element))
        }

        return Array(Set(files)).sorted()
    }

    /// 从 rollout JSONL 的 session_meta 读取 cwd（项目路径），避免全量解析消息。
    private func readProjectPath(fromFile filePath: String) -> String? {
        // session_meta is near the beginning; read a small prefix to avoid loading huge files.
        guard let prefix = readFilePrefix(filePath, maxBytes: 128 * 1024) else {
            return nil
        }

        var result: String?
        prefix.enumerateLines { line, stop in
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  (json["type"] as? String) == "session_meta" else {
                return
            }
            if let payload = json["payload"] as? [String: Any] {
                result = payload["cwd"] as? String
            } else if let meta = json["meta"] as? [String: Any] {
                result = meta["cwd"] as? String
            } else {
                result = json["cwd"] as? String
            }
            stop = true
        }
        return result
    }

    private func readFilePrefix(_ filePath: String, maxBytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: filePath)) else {
            return nil
        }
        defer { try? handle.close() }

        let data = handle.readData(ofLength: maxBytes)
        guard !data.isEmpty else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func intValue(_ raw: Any?) -> Int {
        if let v = raw as? Int { return v }
        if let v = raw as? Double { return Int(v) }
        if let v = raw as? NSNumber { return v.intValue }
        if let s = raw as? String, let d = Double(s) { return Int(d) }
        return 0
    }

    private func parseJSONDictionary(_ raw: Any?) -> [String: Any] {
        if let dict = raw as? [String: Any] { return dict }
        guard let text = raw as? String, let data = text.data(using: .utf8) else { return [:] }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return json
    }

    private func extractModel(from payload: [String: Any]?) -> String? {
        guard let payload = payload else { return nil }

        if let model = payload["model"] as? String, !model.isEmpty {
            return model
        }

        if let collab = payload["collaboration_mode"] as? [String: Any],
           let settings = collab["settings"] as? [String: Any],
           let model = settings["model"] as? String,
           !model.isEmpty {
            return model
        }

        return nil
    }

    private func extractTokenUsage(fromTokenCountPayload payload: [String: Any]) -> TokenDetail? {
        guard let info = payload["info"] as? [String: Any],
              let lastUsage = info["last_token_usage"] as? [String: Any] else {
            return nil
        }

        let rawInput = intValue(lastUsage["input_tokens"])
        let cached = intValue(lastUsage["cached_input_tokens"])
        let output = intValue(lastUsage["output_tokens"])

        guard rawInput > 0 || cached > 0 || output > 0 else { return nil }

        // Codex last_token_usage.input_tokens includes cached_input_tokens.
        let inputNoCache = max(rawInput - cached, 0)
        return TokenDetail(
            inputTokens: inputNoCache,
            outputTokens: output,
            cacheCreationInputTokens: 0,
            cacheReadInputTokens: cached
        )
    }

    private func extractTextContent(_ raw: Any?) -> String {
        if let text = raw as? String { return text }

        let blocks: [[String: Any]]
        if let arr = raw as? [[String: Any]] {
            blocks = arr
        } else if let arrAny = raw as? [Any] {
            blocks = arrAny.compactMap { $0 as? [String: Any] }
        } else {
            blocks = []
        }

        var parts: [String] = []
        for block in blocks {
            let blockType = block["type"] as? String ?? ""
            if blockType == "text" || blockType == "input_text" || blockType == "output_text" {
                if let t = block["text"] as? String, !t.isEmpty {
                    parts.append(t)
                }
            }
        }
        return parts.joined(separator: "\n")
    }

    private func isMetaUserText(_ text: String) -> Bool {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.hasPrefix("<environment_context>")
            || s.hasPrefix("<permissions instructions>")
            || s.hasPrefix("<app-context>")
    }

    private func parseApplyPatchInput(_ rawArguments: Any?) -> [String: Any] {
        var patchText = ""
        if let s = rawArguments as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.first == "{", !trimmed.isEmpty {
                let parsed = parseJSONDictionary(s)
                patchText = (parsed["patch"] as? String) ?? (parsed["input"] as? String) ?? s
            } else {
                patchText = s
            }
        } else if let dict = rawArguments as? [String: Any] {
            patchText = (dict["patch"] as? String) ?? (dict["input"] as? String) ?? ""
        }

        var filePath = ""
        var added = 0
        var removed = 0

        patchText.enumerateLines { line, _ in
            if filePath.isEmpty {
                if line.hasPrefix("*** Update File: ") {
                    filePath = String(line.dropFirst("*** Update File: ".count))
                } else if line.hasPrefix("*** Add File: ") {
                    filePath = String(line.dropFirst("*** Add File: ".count))
                } else if line.hasPrefix("*** Delete File: ") {
                    filePath = String(line.dropFirst("*** Delete File: ".count))
                }
            }

            if line.hasPrefix("+"), !line.hasPrefix("+++") {
                added += 1
            } else if line.hasPrefix("-"), !line.hasPrefix("---") {
                removed += 1
            }
        }

        return [
            "target_file": filePath,
            "__old_lines": removed,
            "__new_lines": added,
        ]
    }

    private func compactToolInput(name: String, input: [String: Any]) -> [String: Any] {
        var compacted: [String: Any] = [:]

        if let filePath = input["file_path"] as? String { compacted["file_path"] = filePath }
        if let targetFile = input["target_file"] as? String { compacted["target_file"] = targetFile }
        if let skill = input["skill"] as? String { compacted["skill"] = skill }

        if let oldLines = input["__old_lines"] as? Int { compacted["__old_lines"] = oldLines }
        if let newLines = input["__new_lines"] as? Int { compacted["__new_lines"] = newLines }
        if let contentLines = input["__content_lines"] as? Int { compacted["__content_lines"] = contentLines }

        if name == "Write" {
            let content = input["content"] as? String ?? ""
            compacted["__content_lines"] = fastLineCount(content)
        } else if name == "Edit" {
            if compacted["__old_lines"] == nil || compacted["__new_lines"] == nil {
                let oldString = input["old_string"] as? String ?? ""
                var newString = input["new_string"] as? String ?? ""
                if oldString.isEmpty && newString.isEmpty {
                    newString = input["code_edit"] as? String ?? ""
                }
                compacted["__old_lines"] = fastLineCount(oldString)
                compacted["__new_lines"] = fastLineCount(newString)
            }
        }

        if let cmd = input["cmd"] as? String, !cmd.isEmpty {
            compacted["cmd"] = truncate(cmd, maxChars: CodexParser.maxSmallInputChars)
        }
        if let query = input["query"] as? String, !query.isEmpty {
            compacted["query"] = truncate(query, maxChars: CodexParser.maxSmallInputChars)
        }
        if let q = input["q"] as? String, !q.isEmpty {
            compacted["q"] = truncate(q, maxChars: CodexParser.maxSmallInputChars)
        }

        return compacted
    }

    private func fastLineCount(_ text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .newlines)
        guard !trimmed.isEmpty else { return 0 }
        var count = 1
        for b in trimmed.utf8 where b == 10 { // '\n'
            count += 1
        }
        return count
    }

    private func truncate(_ text: String, maxChars: Int) -> String {
        guard text.count > maxChars else { return text }
        return String(text.prefix(maxChars))
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
