import Foundation

enum JSONLLineReader {
    /// Reads each byte once, retaining only the unfinished line between chunks.
    static func forEachLine(
        in filePath: String,
        chunkSize: Int = 64 * 1024,
        _ body: (String) -> Bool
    ) {
        guard chunkSize > 0,
              let handle = FileHandle(forReadingAtPath: filePath) else { return }
        defer { try? handle.close() }

        var buffer = Data()
        buffer.reserveCapacity(chunkSize)
        var shouldContinue = true

        func emit(_ data: Data) {
            guard shouldContinue, !Task.isCancelled, !data.isEmpty else { return }
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

        while shouldContinue && !Task.isCancelled {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: chunkSize)
            } catch {
                break
            }
            guard let chunk, !chunk.isEmpty else { break }

            // Scan only the newly read bytes. Searching the accumulated buffer
            // again for every chunk is quadratic for large JSONL tool results.
            // Consuming prefixes for every short line also repeatedly copies data.
            chunk.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                guard let base = bytes.baseAddress else { return }
                var start = 0
                for index in bytes.indices {
                    guard bytes[index] == 0x0A else { continue }
                    guard shouldContinue, !Task.isCancelled else { return }
                    let linePart = UnsafeRawBufferPointer(
                        start: base.advanced(by: start), count: index - start
                    )
                    if buffer.isEmpty {
                        emit(Data(linePart))
                    } else {
                        buffer.append(contentsOf: linePart)
                        emit(buffer)
                        buffer.removeAll(keepingCapacity: true)
                    }
                    start = index + 1
                    guard shouldContinue else { return }
                }
                if start < bytes.count {
                    buffer.append(contentsOf: UnsafeRawBufferPointer(
                        start: base.advanced(by: start), count: bytes.count - start
                    ))
                }
            }
        }

        if shouldContinue, !Task.isCancelled, !buffer.isEmpty {
            emit(buffer)
        }
    }
}
