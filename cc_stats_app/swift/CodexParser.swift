import Foundation

/// Parses Codex CLI sessions from ~/.codex/ rollout JSONL files.
/// Codex stores sessions as JSONL with tagged types: session_meta, event_msg, response_item, turn_context.
/// Respects $CODEX_HOME environment variable for custom session storage paths.
final class CodexParser {

    private let fileManager = FileManager.default
    private let codexHome: String

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
        // Codex stores rollouts in ~/.codex/sessions/ or directly in ~/.codex/
        let searchDirs = [
            (codexHome as NSString).appendingPathComponent("sessions"),
            codexHome,
        ]

        var allFiles: [String] = []
        for dir in searchDirs {
            if let enumerator = fileManager.enumerator(atPath: dir) {
                while let element = enumerator.nextObject() as? String {
                    if element.hasSuffix(".jsonl") {
                        allFiles.append((dir as NSString).appendingPathComponent(element))
                    }
                }
            }
        }

        // Deduplicate by file path
        let unique = Array(Set(allFiles))
        return unique.compactMap { parseSessionFile($0) }
    }

    func parseSessions(forProject projectPath: String) -> [Session] {
        return parseAllSessions().filter { $0.projectPath == projectPath }
    }

    // MARK: - JSONL Parsing

    private func parseSessionFile(_ filePath: String) -> Session? {
        guard let data = fileManager.contents(atPath: filePath),
              let content = String(data: data, encoding: .utf8) else {
            return nil
        }

        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        var messages: [Message] = []
        var projectPath: String?
        var totalTokens = TokenDetail()
        var model: String?

        for line in lines {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

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

            case "event_msg":
                guard let eventPayload = payload else { continue }
                let eventType = eventPayload["type"] as? String ?? ""

                if eventType == "token_count" {
                    // Extract token usage
                    if let tokenPayload = eventPayload["payload"] as? [String: Any],
                       let info = tokenPayload["info"] as? [String: Any],
                       let lastUsage = info["last_token_usage"] as? [String: Any] {
                        let input = lastUsage["input_tokens"] as? Int ?? 0
                        let cached = lastUsage["cached_input_tokens"] as? Int ?? 0
                        let output = lastUsage["output_tokens"] as? Int ?? 0
                        totalTokens.inputTokens += input
                        totalTokens.outputTokens += output
                        totalTokens.cacheReadInputTokens += cached
                    }
                } else if eventType == "user_message" {
                    // User message
                    let msgPayload = eventPayload["payload"] as? [String: Any]
                    let content = msgPayload?["message"] as? String ?? ""
                    let ts = parseTimestamp(eventPayload["timestamp"] as? String)
                    messages.append(Message(
                        role: "user",
                        content: content,
                        timestamp: ts
                    ))
                } else if eventType == "agent_message" {
                    let msgPayload = eventPayload["payload"] as? [String: Any]
                    let content = msgPayload?["message"] as? String ?? ""
                    let ts = parseTimestamp(eventPayload["timestamp"] as? String)
                    messages.append(Message(
                        role: "assistant",
                        content: content,
                        timestamp: ts
                    ))
                }

            case "response_item":
                // Model responses - extract role and content
                guard let item = payload else { continue }
                let role = item["role"] as? String ?? "assistant"
                let itemModel = item["model"] as? String
                if let m = itemModel { model = m }

                var textContent = ""
                if let contentArray = item["content"] as? [[String: Any]] {
                    for block in contentArray {
                        let blockType = block["type"] as? String ?? ""
                        if blockType == "output_text" || blockType == "text" {
                            textContent += block["text"] as? String ?? ""
                        }
                    }
                }

                let ts = parseTimestamp(item["timestamp"] as? String)
                if !textContent.isEmpty || role == "user" {
                    messages.append(Message(
                        role: role == "user" ? "user" : "assistant",
                        content: textContent,
                        model: itemModel,
                        timestamp: ts
                    ))
                }

            case "turn_context":
                // Contains the user input for each turn
                if let turnPayload = payload,
                   let items = turnPayload["items"] as? [[String: Any]] {
                    for turnItem in items {
                        if let userMsg = turnItem["user_message"] as? [String: Any],
                           let inputItems = userMsg["input_items"] as? [[String: Any]] {
                            for inputItem in inputItems {
                                if let text = inputItem["text"] as? String {
                                    let ts = parseTimestamp(turnPayload["timestamp"] as? String)
                                    messages.append(Message(
                                        role: "user",
                                        content: text,
                                        timestamp: ts
                                    ))
                                }
                            }
                        }
                    }
                }

            default:
                break
            }
        }

        guard !messages.isEmpty else { return nil }

        // Attach token usage as a final assistant message if we have token data
        if totalTokens.totalTokens > 0 {
            let modelName = model ?? "gpt-4o"
            // Create a synthetic message with token info for the analyzer
            messages.append(Message(
                role: "assistant",
                content: "",
                model: modelName,
                timestamp: messages.last?.timestamp,
                tokenUsage: totalTokens
            ))
        }

        return Session(
            filePath: filePath,
            messages: messages,
            projectPath: projectPath
        )
    }

    // MARK: - Helpers

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
