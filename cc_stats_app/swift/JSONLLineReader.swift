import Foundation

enum JSONLLineReader {
    /// Reads large JSONL files without materializing the whole file as one String.
    static func forEachLine(
        in filePath: String,
        chunkSize: Int = 64 * 1024,
        _ body: (String) -> Bool
    ) {
        guard let handle = FileHandle(forReadingAtPath: filePath) else { return }
        defer { try? handle.close() }

        let newline = Data([0x0A])
        var buffer = Data()
        buffer.reserveCapacity(chunkSize)
        var shouldContinue = true

        func emit(_ data: Data) {
            guard shouldContinue, !data.isEmpty else { return }
            var lineData = data
            if lineData.last == 0x0D {
                lineData.removeLast()
            }
            guard !lineData.isEmpty,
                  let line = String(data: lineData, encoding: .utf8) else {
                return
            }
            shouldContinue = body(line)
        }

        while shouldContinue {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: chunkSize)
            } catch {
                break
            }
            guard let chunk, !chunk.isEmpty else { break }

            buffer.append(chunk)
            while shouldContinue, let range = buffer.firstRange(of: newline) {
                let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                emit(lineData)
            }
        }

        if shouldContinue, !buffer.isEmpty {
            emit(buffer)
        }
    }
}
