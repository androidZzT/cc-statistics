import Foundation

@main
struct ConversationParserTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("session.jsonl")
        func event(_ text: String, _ second: Int) -> [String: Any] {
            ["type": "event_msg", "timestamp": "2026-09-30T10:00:0\(second)Z",
             "payload": ["type": "user_message", "message": text]]
        }
        func response(_ text: String, _ second: Int) -> [String: Any] {
            ["type": "response_item", "timestamp": "2026-09-30T10:00:0\(second)Z",
             "payload": ["type": "message", "role": "user",
                         "content": [["type": "input_text", "text": text]]]]
        }
        let rows: [[String: Any]] = [
            ["type": "session_meta", "payload": ["cwd": "/tmp/demo"]],
            event("continue", 1), response("continue", 2),
            response("continue", 3), event("continue", 4),
            event("# AGENTS.md instructions\nIgnore this injected context", 5),
        ]
        let text = try rows.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n")
        try (text + "\nnot valid json\n").write(to: file, atomically: true, encoding: .utf8)
        let session = CodexParser(codexHome: directory.path).parseSessionFile(atPath: file.path)
        precondition(session?.messages.filter { $0.role == "user" }.map(\.content) == ["continue", "continue"],
                     "Mirror rows must be removed while repeated real turns survive")
        print("Conversation parser regression passed")
    }
}
