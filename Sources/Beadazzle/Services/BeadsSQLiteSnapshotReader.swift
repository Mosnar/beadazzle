import CSQLite
import Foundation

struct BeadsSQLiteSnapshotReader {
    func loadSnapshot(from source: BeadsDataSource) throws -> BeadsSnapshot {
        let database = try SQLiteDatabase.open(url: source.url)
        defer { sqlite3_close(database) }

        SQLiteDatabase.applyReadPragmas(database)
        let dependencies = try loadAllDependencies(database: database)
        let labelsByIssueID = try loadAllLabels(database: database)
        return BeadsSnapshot(
            issues: try loadIssues(
                database: database,
                dependencies: dependencies,
                labelsByIssueID: labelsByIssueID
            ),
            dependencies: dependencies,
            commentsByIssueID: [:]
        )
    }

    private func loadIssues(
        database: OpaquePointer?,
        dependencies: [BeadDependency],
        labelsByIssueID: [String: [String]]
    ) throws -> [BeadIssue] {
        guard SQLiteDatabase.tableExists("issues", in: database) else { return [] }

        let issueColumns = SQLiteDatabase.columns(in: "issues", database: database)
        func column(_ name: String, fallback: String) -> String {
            issueColumns.contains(name) ? "i.\(name)" : fallback
        }
        let awaitTypeExpression = issueColumns.contains("await_type")
            ? "i.await_type"
            : (issueColumns.contains("gate_type") ? "i.gate_type" : "NULL")
        let whereClause = issueColumns.contains("deleted_at") ? "WHERE i.deleted_at IS NULL" : ""
        let updatedOrder = issueColumns.contains("updated_at") ? "i.updated_at DESC" : "i.id ASC"
        let commentCountExpression: String
        if issueColumns.contains("comment_count") {
            commentCountExpression = "i.comment_count"
        } else if SQLiteDatabase.tableExists("comments", in: database),
                  SQLiteDatabase.columns(in: "comments", database: database).contains("issue_id") {
            commentCountExpression = "(SELECT COUNT(*) FROM comments c WHERE c.issue_id = i.id)"
        } else {
            commentCountExpression = "0"
        }
        let dependencyCounts = dependencies.reduce(into: [String: Int]()) { counts, dependency in
            counts[dependency.issueID, default: 0] += 1
        }
        let dependentCounts = dependencies.reduce(into: [String: Int]()) { counts, dependency in
            counts[dependency.dependsOnID, default: 0] += 1
        }
        let sql = """
        SELECT
          i.id,
          \(column("title", fallback: "''")),
          \(column("description", fallback: "''")),
          \(column("design", fallback: "''")),
          \(column("acceptance_criteria", fallback: "''")),
          \(column("notes", fallback: "''")),
          \(column("status", fallback: "'open'")),
          \(column("priority", fallback: "2")),
          \(column("issue_type", fallback: "'task'")),
          \(awaitTypeExpression),
          \(column("await_id", fallback: "NULL")),
          \(column("timeout", fallback: "NULL")),
          \(column("assignee", fallback: "NULL")),
          \(column("owner", fallback: "NULL")),
          \(column("created_at", fallback: "NULL")),
          \(column("updated_at", fallback: "NULL")),
          \(column("closed_at", fallback: "NULL")),
          \(column("due_at", fallback: "NULL")),
          \(column("defer_until", fallback: "NULL")),
          \(column("external_ref", fallback: "NULL")),
          \(column("parent_id", fallback: "NULL")) AS parent_id,
          \(column("pinned", fallback: "0")),
          \(column("ephemeral", fallback: "0")),
          \(column("is_template", fallback: "0")),
          \(commentCountExpression)
        FROM issues i
        \(whereClause)
        ORDER BY \(column("priority", fallback: "2")) ASC, \(updatedOrder)
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw BeadError.sqlitePrepare(SQLiteDatabase.lastError(database))
        }
        defer { sqlite3_finalize(statement) }

        var issues: [BeadIssue] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE {
                break
            }
            guard result == SQLITE_ROW else {
                throw BeadError.sqliteStep(SQLiteDatabase.lastError(database))
            }

            let id = SQLiteDatabase.text(statement, 0)
            issues.append(
                BeadIssue(
                    id: id,
                    title: SQLiteDatabase.text(statement, 1),
                    description: SQLiteDatabase.text(statement, 2),
                    design: SQLiteDatabase.text(statement, 3),
                    acceptanceCriteria: SQLiteDatabase.text(statement, 4),
                    notes: SQLiteDatabase.text(statement, 5),
                    status: SQLiteDatabase.text(statement, 6),
                    priority: SQLiteDatabase.int(statement, 7),
                    issueType: SQLiteDatabase.text(statement, 8),
                    gateAwaitType: SQLiteDatabase.optionalText(statement, 9).map(GateAwaitType.init(rawValue:)),
                    gateAwaitID: SQLiteDatabase.optionalText(statement, 10),
                    gateTimeoutNanoseconds: SQLiteDatabase.optionalInt64(statement, 11),
                    assignee: SQLiteDatabase.optionalText(statement, 12),
                    owner: SQLiteDatabase.optionalText(statement, 13),
                    createdAt: parseDate(SQLiteDatabase.optionalText(statement, 14)),
                    updatedAt: parseDate(SQLiteDatabase.optionalText(statement, 15)),
                    closedAt: parseDate(SQLiteDatabase.optionalText(statement, 16)),
                    dueAt: parseDate(SQLiteDatabase.optionalText(statement, 17)),
                    deferUntil: parseDate(SQLiteDatabase.optionalText(statement, 18)),
                    externalRef: SQLiteDatabase.optionalText(statement, 19),
                    parentID: SQLiteDatabase.optionalText(statement, 20),
                    labels: labelsByIssueID[id, default: []],
                    dependencyCount: dependencyCounts[id, default: 0],
                    dependentCount: dependentCounts[id, default: 0],
                    commentCount: SQLiteDatabase.int(statement, 24),
                    pinned: SQLiteDatabase.int(statement, 21) == 1,
                    ephemeral: SQLiteDatabase.int(statement, 22) == 1,
                    isTemplate: SQLiteDatabase.int(statement, 23) == 1
                )
            )
        }

        return issues
    }

    private func loadAllDependencies(database: OpaquePointer?) throws -> [BeadDependency] {
        guard SQLiteDatabase.tableExists("dependencies", in: database) else { return [] }
        let columns = SQLiteDatabase.columns(in: "dependencies", database: database)
        guard columns.contains("issue_id"), columns.contains("depends_on_id") else { return [] }
        let typeExpression = columns.contains("type")
            ? "type"
            : (columns.contains("dependency_type") ? "dependency_type" : "''")
        let createdAtExpression = columns.contains("created_at") ? "created_at" : "NULL"
        let sql = """
        SELECT issue_id, depends_on_id, \(typeExpression), \(createdAtExpression)
        FROM dependencies
        ORDER BY \(typeExpression), \(createdAtExpression) DESC
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw BeadError.sqlitePrepare(SQLiteDatabase.lastError(database))
        }
        defer { sqlite3_finalize(statement) }

        var dependencies: [BeadDependency] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE {
                break
            }
            guard result == SQLITE_ROW else {
                throw BeadError.sqliteStep(SQLiteDatabase.lastError(database))
            }

            dependencies.append(
                BeadDependency(
                    issueID: SQLiteDatabase.text(statement, 0),
                    dependsOnID: SQLiteDatabase.text(statement, 1),
                    type: SQLiteDatabase.text(statement, 2),
                    createdAt: parseDate(SQLiteDatabase.optionalText(statement, 3))
                )
            )
        }
        return dependencies
    }

    private func loadAllLabels(database: OpaquePointer?) throws -> [String: [String]] {
        guard SQLiteDatabase.tableExists("labels", in: database) else { return [:] }
        let columns = SQLiteDatabase.columns(in: "labels", database: database)
        guard columns.contains("issue_id") else { return [:] }
        let labelExpression: String
        if columns.contains("label") {
            labelExpression = "label"
        } else if columns.contains("name") {
            labelExpression = "name"
        } else {
            return [:]
        }
        let sql = """
        SELECT issue_id, \(labelExpression)
        FROM labels
        ORDER BY issue_id, \(labelExpression)
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw BeadError.sqlitePrepare(SQLiteDatabase.lastError(database))
        }
        defer { sqlite3_finalize(statement) }

        var labelsByIssueID: [String: [String]] = [:]
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE {
                break
            }
            guard result == SQLITE_ROW else {
                throw BeadError.sqliteStep(SQLiteDatabase.lastError(database))
            }

            let issueID = SQLiteDatabase.text(statement, 0)
            let label = SQLiteDatabase.text(statement, 1)
            guard !issueID.isEmpty, !label.isEmpty else { continue }
            labelsByIssueID[issueID, default: []].append(label)
        }
        return labelsByIssueID
    }

    private func parseDate(_ value: String?) -> Date? {
        BeadFormatters.parseDate(value)
    }
}
