import Foundation

/// A compact, append-aware index over a project's interaction log.
///
/// The index retains only one 16-byte location per log entry plus one dictionary key
/// per issue. Event strings are decoded only for the selected issue, off the main actor.
actor BeadActivityHistoryRepository {
    private struct FileFingerprint: Equatable {
        var size: UInt64
        var modifiedAt: Date
        var fileNumber: UInt64?
    }

    private struct LineLocation: Sendable {
        var offset: UInt64
        var length: UInt32
        var lineNumber: UInt32
    }

    private struct InteractionIndex {
        var url: URL
        var fingerprint: FileFingerprint
        var locationsByIssueID: [String: [LineLocation]]
        var lineCount: Int
        var endedWithNewline: Bool
        var issueSetRevision: Int
    }

    private var cachedIndex: InteractionIndex?
    private let reader = BeadsInteractionsReader()

    func events(
        projectURL: URL,
        beadsDirectoryURL: URL? = nil,
        issueID: String,
        validIssueIDs: Set<String>? = nil,
        issueSetRevision: Int = 0
    ) throws -> [BeadIssueEvent] {
        try Task.checkCancellation()
        let url = (beadsDirectoryURL
            ?? projectURL.appendingPathComponent(".beads", isDirectory: true))
            .appendingPathComponent(BeadsInteractionsReader.fileName)
        guard let fingerprint = fingerprint(for: url) else {
            if cachedIndex?.url.standardizedFileURL == url.standardizedFileURL {
                cachedIndex = nil
            }
            return []
        }

        let index = try index(
            for: url,
            fingerprint: fingerprint,
            validIssueIDs: validIssueIDs,
            issueSetRevision: issueSetRevision
        )
        guard let locations = index.locationsByIssueID[issueID], !locations.isEmpty else {
            return []
        }
        return try readEvents(at: locations, from: url)
    }

    func discard(projectURL: URL, beadsDirectoryURL: URL? = nil) {
        let url = (beadsDirectoryURL
            ?? projectURL.appendingPathComponent(".beads", isDirectory: true))
            .appendingPathComponent(BeadsInteractionsReader.fileName)
            .standardizedFileURL
        if cachedIndex?.url.standardizedFileURL == url {
            cachedIndex = nil
        }
    }

    private func index(
        for url: URL,
        fingerprint: FileFingerprint,
        validIssueIDs: Set<String>?,
        issueSetRevision: Int
    ) throws -> InteractionIndex {
        if let cachedIndex,
           cachedIndex.url.standardizedFileURL == url.standardizedFileURL {
            if cachedIndex.fingerprint == fingerprint,
               cachedIndex.issueSetRevision == issueSetRevision {
                return cachedIndex
            }

            let isAppend = cachedIndex.issueSetRevision == issueSetRevision
                && fingerprint.fileNumber == cachedIndex.fingerprint.fileNumber
                && fingerprint.size > cachedIndex.fingerprint.size
                && fingerprint.modifiedAt >= cachedIndex.fingerprint.modifiedAt
                && cachedIndex.endedWithNewline
            if isAppend {
                if let updated = try appending(
                    to: cachedIndex,
                    fingerprint: fingerprint,
                    validIssueIDs: validIssueIDs
                ) {
                    self.cachedIndex = updated
                    return updated
                }
            }
        }

        let currentFingerprint = self.fingerprint(for: url) ?? fingerprint
        let rebuilt = try buildIndex(
            url: url,
            fingerprint: currentFingerprint,
            validIssueIDs: validIssueIDs,
            issueSetRevision: issueSetRevision
        )
        cachedIndex = rebuilt
        return rebuilt
    }

    private func buildIndex(
        url: URL,
        fingerprint: FileFingerprint,
        validIssueIDs: Set<String>?,
        issueSetRevision: Int,
        remainingConsistencyAttempts: Int = 2
    ) throws -> InteractionIndex {
        var locationsByIssueID: [String: [LineLocation]] = [:]
        let scan = try JSONLLineReader.scan(url: url) { [reader] line in
            guard let issueID = reader.issueID(fromJSONLLine: line.data),
                  validIssueIDs?.contains(issueID) != false,
                  let location = Self.location(for: line) else {
                return
            }
            locationsByIssueID[issueID, default: []].append(location)
        }
        guard let finalFingerprint = self.fingerprint(for: url),
              finalFingerprint == fingerprint,
              finalFingerprint.size == scan.nextOffset else {
            guard remainingConsistencyAttempts > 0,
                  let nextFingerprint = self.fingerprint(for: url) else {
                throw ActivityHistoryReadError.changedDuringRead
            }
            return try buildIndex(
                url: url,
                fingerprint: nextFingerprint,
                validIssueIDs: validIssueIDs,
                issueSetRevision: issueSetRevision,
                remainingConsistencyAttempts: remainingConsistencyAttempts - 1
            )
        }
        return InteractionIndex(
            url: url,
            fingerprint: finalFingerprint,
            locationsByIssueID: locationsByIssueID,
            lineCount: scan.lineCount,
            endedWithNewline: scan.endedWithNewline,
            issueSetRevision: issueSetRevision
        )
    }

    private func appending(
        to existing: InteractionIndex,
        fingerprint: FileFingerprint,
        validIssueIDs: Set<String>?
    ) throws -> InteractionIndex? {
        var updated = existing
        let scan = try JSONLLineReader.scan(
            url: existing.url,
            startingAt: existing.fingerprint.size,
            startingLineNumber: existing.lineCount
        ) { [reader] line in
            guard let issueID = reader.issueID(fromJSONLLine: line.data),
                  validIssueIDs?.contains(issueID) != false,
                  let location = Self.location(for: line) else {
                return
            }
            updated.locationsByIssueID[issueID, default: []].append(location)
        }
        guard let finalFingerprint = self.fingerprint(for: existing.url),
              finalFingerprint == fingerprint,
              finalFingerprint.size == scan.nextOffset else {
            return nil
        }
        updated.fingerprint = finalFingerprint
        updated.lineCount = scan.lineCount
        updated.endedWithNewline = scan.endedWithNewline
        return updated
    }

    private func readEvents(
        at locations: [LineLocation],
        from url: URL
    ) throws -> [BeadIssueEvent] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var events: [BeadIssueEvent] = []
        events.reserveCapacity(locations.count)
        var locationIndex = 0

        while locationIndex < locations.count {
            try Task.checkCancellation()
            let batchStart = locations[locationIndex].offset
            var batchEnd = batchStart + UInt64(locations[locationIndex].length)
            var batchEndIndex = locationIndex + 1

            while batchEndIndex < locations.count {
                let next = locations[batchEndIndex]
                let nextEnd = next.offset + UInt64(next.length)
                let span = nextEnd - batchStart
                let gap = next.offset > batchEnd ? next.offset - batchEnd : 0
                guard span <= Self.maximumReadBatchSize,
                      gap <= Self.maximumReadBatchGap else {
                    break
                }
                batchEnd = max(batchEnd, nextEnd)
                batchEndIndex += 1
            }

            try handle.seek(toOffset: batchStart)
            let requestedLength = Int(batchEnd - batchStart)
            var batch = Data()
            batch.reserveCapacity(requestedLength)
            while batch.count < requestedLength {
                try Task.checkCancellation()
                guard let chunk = try handle.read(upToCount: requestedLength - batch.count),
                      !chunk.isEmpty else {
                    throw ActivityHistoryReadError.changedDuringRead
                }
                batch.append(chunk)
            }

            for index in locationIndex..<batchEndIndex {
                try Task.checkCancellation()
                let location = locations[index]
                let lowerBound = Int(location.offset - batchStart)
                let upperBound = lowerBound + Int(location.length)
                guard lowerBound >= 0, upperBound <= batch.count else { continue }
                let line = Data(batch[lowerBound..<upperBound])
                if let event = reader.event(
                    fromJSONLLine: line,
                    lineNumber: Int(location.lineNumber)
                ) {
                    events.append(event)
                }
            }
            locationIndex = batchEndIndex
        }

        return BeadsInteractionsReader.sorted(events)
    }

    private func fingerprint(for url: URL) -> FileFingerprint? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular,
              let modifiedAt = attributes[.modificationDate] as? Date else {
            return nil
        }
        let size = (attributes[.size] as? NSNumber)?.uint64Value
            ?? UInt64(attributes[.size] as? Int64 ?? 0)
        let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        return FileFingerprint(size: size, modifiedAt: modifiedAt, fileNumber: fileNumber)
    }

    private static func location(for line: JSONLLine) -> LineLocation? {
        guard line.data.count <= UInt32.max, line.number <= Int(UInt32.max) else {
            return nil
        }
        return LineLocation(
            offset: line.offset,
            length: UInt32(line.data.count),
            lineNumber: UInt32(line.number)
        )
    }

    private static let maximumReadBatchSize: UInt64 = 256 * 1024
    private static let maximumReadBatchGap: UInt64 = 16 * 1024
}

private enum ActivityHistoryReadError: LocalizedError {
    case changedDuringRead

    var errorDescription: String? {
        "Activity history changed while it was being read. Refresh to try again."
    }
}
