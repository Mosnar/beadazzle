import Foundation

struct JSONLLine {
    var number: Int
    var offset: UInt64
    var data: Data
}

struct JSONLScanResult {
    var nextOffset: UInt64
    var lineCount: Int
    var endedWithNewline: Bool
}

/// Bounded-memory JSONL scanning shared by snapshot and activity readers.
/// Cancellation is checked between chunks and lines so a superseded project load
/// does not continue parsing a large file in the background.
enum JSONLLineReader {
    static let chunkSize = 64 * 1024

    static func scan(
        url: URL,
        startingAt startingOffset: UInt64 = 0,
        startingLineNumber: Int = 0,
        visit: (JSONLLine) throws -> Void
    ) throws -> JSONLScanResult {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: startingOffset)

        var nextOffset = startingOffset
        var lineStartOffset = startingOffset
        var lineNumber = startingLineNumber
        var lineBuffer = Data()
        var endedWithNewline = true
        lineBuffer.reserveCapacity(Self.chunkSize)

        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: Self.chunkSize), !chunk.isEmpty else {
                break
            }

            let chunkOffset = nextOffset
            nextOffset += UInt64(chunk.count)
            endedWithNewline = chunk.last == 10

            var start = chunk.startIndex
            while start < chunk.endIndex,
                  let newlineIndex = chunk[start...].firstIndex(of: 10) {
                try Task.checkCancellation()
                lineBuffer.append(contentsOf: chunk[start..<newlineIndex])
                lineNumber += 1
                try visit(JSONLLine(number: lineNumber, offset: lineStartOffset, data: lineBuffer))
                lineBuffer.removeAll(keepingCapacity: true)

                let nextIndex = chunk.index(after: newlineIndex)
                lineStartOffset = chunkOffset + UInt64(chunk.distance(from: chunk.startIndex, to: nextIndex))
                start = nextIndex
            }

            if start < chunk.endIndex {
                lineBuffer.append(contentsOf: chunk[start..<chunk.endIndex])
            }
        }

        if !lineBuffer.isEmpty {
            try Task.checkCancellation()
            lineNumber += 1
            try visit(JSONLLine(number: lineNumber, offset: lineStartOffset, data: lineBuffer))
            endedWithNewline = false
        }

        return JSONLScanResult(
            nextOffset: nextOffset,
            lineCount: lineNumber,
            endedWithNewline: endedWithNewline
        )
    }
}
