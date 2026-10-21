// swiftc cc_stats_app/swift/JSONLLineReader.swift tests/test_jsonl_line_reader.swift -o /tmp/test-jsonl-reader
import Foundation

@main
struct JSONLLineReaderTests {
    static func main() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let longLine = String(repeating: "数据🦀", count: 30_000)
        let content = Data(("first\r\n\n" + longLine + "\n").utf8)
            + Data([0xFF, 0x0A]) + Data("last".utf8)
        try content.write(to: file)
        for chunkSize in [1, 3, 17, 64 * 1024] {
            var lines: [String] = []
            JSONLLineReader.forEachLine(in: file.path, chunkSize: chunkSize) {
                lines.append($0)
                return true
            }
            precondition(lines == ["first", longLine, "last"], "Chunk boundaries, CRLF, UTF-8, invalid rows and final line")
        }
        var calls = 0
        JSONLLineReader.forEachLine(in: file.path) { _ in calls += 1; return false }
        precondition(calls == 1, "Callback must stop reading immediately")
        let canceled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            var emitted = 0
            JSONLLineReader.forEachLine(in: file.path) { _ in emitted += 1; return true }
            return emitted
        }
        let emitted = await canceled.value
        precondition(emitted == 0, "Canceled loads must not continue parsing")
        print("JSONL reader: chunk boundaries, long UTF-8 rows, CRLF, invalid input, early stop and cancellation passed")
    }
}
