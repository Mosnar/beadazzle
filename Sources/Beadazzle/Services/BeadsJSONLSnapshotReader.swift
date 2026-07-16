import Foundation

struct BeadsJSONLSnapshotReader {
    func loadSnapshot(from source: BeadsDataSource) throws -> BeadsSnapshot {
        let records = try loadRecords(url: source.url)
        return BeadsSnapshot(
            issues: loadIssues(records: records),
            dependencies: loadAllDependencies(records: records),
            commentsByIssueID: [:]
        )
    }

    func loadIssuesForTesting(records: [[String: Any]]) -> [BeadIssue] {
        loadIssues(records: records)
    }

    private func loadIssues(records: [[String: Any]]) -> [BeadIssue] {
        records.compactMap { record in
            let id = record.string("id")
            guard !id.isEmpty else { return nil }

            let dependencies = record.array("dependencies")
            let comments = record.array("comments")
            return BeadIssue(
                id: id,
                title: record.string("title"),
                description: record.string("description"),
                design: record.string("design"),
                acceptanceCriteria: record.string("acceptance_criteria"),
                notes: record.string("notes"),
                status: record.string("status"),
                priority: record.int("priority", default: 2),
                issueType: record.string("issue_type"),
                gateAwaitType: record.gateAwaitType(),
                gateAwaitID: record.optionalString("await_id"),
                gateTimeoutNanoseconds: record.int64("timeout"),
                assignee: record.optionalString("assignee"),
                owner: record.optionalString("owner"),
                createdAt: parseDate(record.optionalString("created_at")),
                createdBy: record.optionalString("created_by"),
                updatedAt: parseDate(record.optionalString("updated_at")),
                closedAt: parseDate(record.optionalString("closed_at")),
                closeReason: record.optionalString("close_reason"),
                dueAt: parseDate(record.optionalString("due_at")),
                deferUntil: parseDate(record.optionalString("defer_until")),
                externalRef: record.optionalString("external_ref"),
                parentID: record.optionalString("parent_id") ?? record.optionalString("parent"),
                labels: record.stringArray("labels").sorted(),
                dependencyCount: record.int("dependency_count", default: dependencies.count),
                dependentCount: record.int("dependent_count", default: 0),
                commentCount: record.int("comment_count", default: comments.count),
                pinned: record.bool("pinned"),
                ephemeral: record.bool("ephemeral"),
                isTemplate: record.bool("is_template")
            )
        }
    }

    private func loadAllDependencies(records: [[String: Any]]) -> [BeadDependency] {
        var dependencies: [BeadDependency] = []

        for record in records {
            for dependency in record.array("dependencies") {
                let sourceID = dependency.string("issue_id", default: record.string("id"))
                let dependsOnID = dependency.string("depends_on_id")
                guard !sourceID.isEmpty, !dependsOnID.isEmpty else { continue }
                dependencies.append(
                    BeadDependency(
                        issueID: sourceID,
                        dependsOnID: dependsOnID,
                        type: dependency.string("type"),
                        createdAt: parseDate(dependency.optionalString("created_at")),
                        createdBy: dependency.optionalString("created_by")
                    )
                )
            }
        }

        return dependencies.sorted { lhs, rhs in
            if lhs.type == rhs.type {
                return (lhs.createdAt ?? .distantPast) > (rhs.createdAt ?? .distantPast)
            }
            return lhs.type < rhs.type
        }
    }

    private func loadRecords(url: URL) throws -> [[String: Any]] {
        var records: [[String: Any]] = []
        _ = try JSONLLineReader.scan(url: url) { line in
            try appendRecord(
                from: line.data,
                lineNumber: line.number,
                path: url.path,
                into: &records
            )
        }
        return records
    }

    private func appendRecord(
        from rawLineData: Data,
        lineNumber: Int,
        path: String,
        into records: inout [[String: Any]]
    ) throws {
        var lineData = rawLineData
        if lineData.last == 13 {
            lineData.removeLast()
        }
        guard !lineData.isEmpty else { return }
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: lineData)
        } catch {
            throw BeadError.invalidSnapshot(path: path, line: lineNumber, message: "Invalid JSON.")
        }
        guard let object = value as? [String: Any] else {
            throw BeadError.invalidSnapshot(path: path, line: lineNumber, message: "Expected a JSON object.")
        }
        let recordType = object.optionalString("_type")
        guard recordType == nil || recordType == "issue" else {
            return
        }
        records.append(object)
    }

    private func parseDate(_ value: String?) -> Date? {
        BeadFormatters.parseDate(value)
    }
}

private extension Dictionary where Key == String, Value == Any {
    func string(_ key: String, default defaultValue: String = "") -> String {
        optionalString(key) ?? defaultValue
    }

    func optionalString(_ key: String) -> String? {
        guard let value = self[key], !(value is NSNull) else { return nil }
        if let string = value as? String {
            return string.isEmpty ? nil : string
        }
        return String(describing: value)
    }

    func int(_ key: String, default defaultValue: Int) -> Int {
        if let int = self[key] as? Int {
            return int
        }
        if let number = self[key] as? NSNumber {
            return number.intValue
        }
        if let string = self[key] as? String, let int = Int(string) {
            return int
        }
        return defaultValue
    }

    func int64(_ key: String) -> Int64? {
        if let int = self[key] as? Int {
            return Int64(int)
        }
        if let number = self[key] as? NSNumber {
            return number.int64Value
        }
        if let string = self[key] as? String {
            return Int64(string)
        }
        return nil
    }

    func gateAwaitType() -> GateAwaitType? {
        guard let rawValue = optionalString("await_type") ?? optionalString("gate_type") else {
            return nil
        }
        return GateAwaitType(rawValue: rawValue)
    }

    func bool(_ key: String) -> Bool {
        if let bool = self[key] as? Bool {
            return bool
        }
        if let number = self[key] as? NSNumber {
            return number.boolValue
        }
        if let string = self[key] as? String {
            return string == "true" || string == "1"
        }
        return false
    }

    func stringArray(_ key: String) -> [String] {
        guard let values = self[key] as? [Any] else { return [] }
        return values.compactMap { value in
            guard !(value is NSNull) else { return nil }
            return String(describing: value)
        }
    }

    func array(_ key: String) -> [[String: Any]] {
        self[key] as? [[String: Any]] ?? []
    }
}
