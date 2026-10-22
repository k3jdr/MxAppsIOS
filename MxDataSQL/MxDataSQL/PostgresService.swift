//
//  PostgresService.swift
//  MxDataSQL
//
//  One PostgreSQL connection per open workspace window (PostgresNIO).
//  All catalog queries select text columns so rows decode uniformly as [String?].
//

import Foundation
import PostgresNIO

nonisolated struct DatabaseError: LocalizedError {
    var message: String
    var sqlState: String?
    /// 1-based character position of the error in the statement that was sent.
    var position: Int?
    var errorDescription: String? { message }

    /// PSQLError hides server details from `localizedDescription`; surface them here.
    static func from(_ error: any Error) -> DatabaseError {
        if let error = error as? DatabaseError { return error }
        if let psql = error as? PSQLError {
            if let info = psql.serverInfo, let message = info[.message] {
                var text = message
                if let detail = info[.detail] { text += "\n\(detail)" }
                if let hint = info[.hint] { text += "\nHint: \(hint)" }
                if let state = info[.sqlState] { text += "\n(SQLSTATE \(state))" }
                return DatabaseError(message: text, sqlState: info[.sqlState],
                                     position: info[.position].flatMap { Int($0) })
            }
            if let underlying = psql.underlying {
                return DatabaseError(message: "Could not connect (\(psql.code)): \(String(describing: underlying))")
            }
            return DatabaseError(message: "\(psql.code)")
        }
        return DatabaseError(message: error.localizedDescription)
    }
}

extension DatabaseError {
    /// Makes `position` relative to the user's SQL when it was sent after `count` characters of wrapper text.
    func shifted(by count: Int) -> DatabaseError {
        var copy = self
        copy.position = position.map { $0 - count }
        return copy
    }
}

nonisolated struct SQLPreflight: Sendable {
    /// Types of the result columns; empty when the statement returns no rows.
    var resultTypes: [String]
    var returnsRows: Bool { !resultTypes.isEmpty }
}

nonisolated struct QueryColumn: Sendable {
    var name: String
    /// Table the column comes from (0 if computed), and its attnum there.
    var tableOID: UInt32
    var attnum: Int
    var type: String
}

nonisolated struct QueryResult: Sendable {
    var columns: [QueryColumn]
    var rows: [[String?]]
    var hasMore: Bool
}

/// The statement tried to change data inside a READ ONLY transaction (SQLSTATE 25006).
nonisolated struct WriteNotAllowed: Error {}

/// Splits PostgreSQL composite (record) text output, e.g. `(1,"a, b",,"")`, into fields.
/// An empty unquoted field is NULL; `""` is the empty string.
nonisolated func parseRecord(_ text: String, fieldCount: Int) -> [String?] {
    guard fieldCount > 0 else { return [] }
    var fields: [String?] = []
    var chars = Array(text.dropFirst().dropLast())[...]   // strip ( and )
    while true {
        var value = ""
        var quoted = false
        while let c = chars.first, c != "," {
            chars.removeFirst()
            if c == "\"" {
                quoted = true
                while let q = chars.first {
                    chars.removeFirst()
                    if q == "\\", let next = chars.first {
                        chars.removeFirst()
                        value.append(next)
                    } else if q == "\"" {
                        if chars.first == "\"" {
                            chars.removeFirst()
                            value.append("\"")
                        } else {
                            break
                        }
                    } else {
                        value.append(q)
                    }
                }
            } else {
                value.append(c)
            }
        }
        fields.append(value.isEmpty && !quoted ? nil : value)
        if chars.isEmpty { break }
        chars.removeFirst()   // the comma
    }
    while fields.count < fieldCount { fields.append(nil) }
    return fields
}

nonisolated struct UpdateOutcome: Sendable {
    var applied = 0
    var failures: [String] = []
}

actor PostgresService {
    private let connection: PostgresConnection
    private let logger = Logger(label: "com.k3jdr.MxDataSQL.postgres")
    private var preflightCounter = 0

    private init(connection: PostgresConnection) {
        self.connection = connection
    }

    static func connect(_ settings: ConnectionSettings, password: String) async throws -> PostgresService {
        let tls: PostgresConnection.Configuration.TLS
        switch settings.sslMode {
        case .disable:
            tls = .disable
        case .prefer, .require:
            // Like libpq's sslmode=prefer/require: encrypt, but do not verify the certificate.
            var config = TLSConfiguration.makeClientConfiguration()
            config.certificateVerification = .none
            let context = try NIOSSLContext(configuration: config)
            tls = settings.sslMode == .prefer ? .prefer(context) : .require(context)
        }
        let configuration = PostgresConnection.Configuration(
            host: settings.host, port: settings.port, username: settings.user,
            password: password.isEmpty ? nil : password, database: settings.database, tls: tls)
        do {
            let connection = try await PostgresConnection.connect(
                configuration: configuration, id: 1, logger: Logger(label: "com.k3jdr.MxDataSQL.postgres"))
            return PostgresService(connection: connection)
        } catch {
            throw DatabaseError.from(error)
        }
    }

    func close() async {
        try? await connection.close()
    }

    /// Runs `sql` with text parameters and returns every row as text values.
    func rows(_ sql: String, _ binds: [String?] = []) async throws -> [[String?]] {
        var bindings = PostgresBindings()
        for value in binds {
            if let value { bindings.append(value) } else { bindings.appendNull() }
        }
        do {
            var result: [[String?]] = []
            for try await row in try await connection.query(PostgresQuery(unsafeSQL: sql, binds: bindings), logger: logger) {
                var values: [String?] = []
                for cell in row { values.append(try cell.decode(String?.self)) }
                result.append(values)
            }
            return result
        } catch {
            throw DatabaseError.from(error)
        }
    }

    /// Databases on the server this user may connect to, by name.
    func databases() async throws -> [String] {
        try await rows("""
            SELECT datname::text FROM pg_database
            WHERE datallowconn AND NOT datistemplate AND has_database_privilege(datname, 'CONNECT')
            ORDER BY 1
            """).compactMap { $0[0] }
    }

    func serverVersion() async throws -> String {
        try await rows("SELECT current_setting('server_version')").first?.first.flatMap { $0 } ?? "?"
    }

    // MARK: DB Table Selection

    /// Tables, partitioned tables, views and materialized views. A plain view has no row estimate
    /// (0 until counted) and no size.
    func listTables() async throws -> [TableSummary] {
        let sql = """
            SELECT c.oid::text, n.nspname::text, c.relname::text,
                   CASE c.relkind WHEN 'p' THEN 'partitioned table' WHEN 'v' THEN 'view'
                                  WHEN 'm' THEN 'materialized view' ELSE 'table' END,
                   (CASE WHEN c.relkind = 'v' THEN 0
                         WHEN c.reltuples >= 0 THEN c.reltuples::bigint
                         ELSE coalesce(s.n_live_tup, 0) END)::text,
                   CASE WHEN c.relkind = 'v' THEN '' ELSE pg_size_pretty(pg_total_relation_size(c.oid)) END
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            LEFT JOIN pg_stat_all_tables s ON s.relid = c.oid
            WHERE c.relkind IN ('r', 'p', 'v', 'm')
              AND n.nspname NOT IN ('pg_catalog', 'information_schema')
              AND n.nspname NOT LIKE 'pg_toast%'
            ORDER BY 2, 3
            """
        return try await rows(sql).map { r in
            TableSummary(oid: r[0]!, ref: TableRef(schema: r[1]!, name: r[2]!), kind: r[3]!,
                         estimatedRows: Int(r[4] ?? "") ?? 0, totalSize: r[5] ?? "")
        }
    }

    /// Functions and procedures, like psql's `\df`: not aggregates or window functions, and not the
    /// functions of extensions (btree_gist alone adds hundreds to public). Needs PostgreSQL 11 (prokind).
    func listRoutines() async throws -> [RoutineSummary] {
        let sql = """
            SELECT p.oid::text, n.nspname::text, p.proname::text,
                   CASE p.prokind WHEN 'p' THEN 'procedure' ELSE 'function' END,
                   pg_get_function_identity_arguments(p.oid),
                   CASE WHEN p.prokind = 'f' THEN pg_get_function_result(p.oid) ELSE '' END,
                   l.lanname::text
            FROM pg_proc p
            JOIN pg_namespace n ON n.oid = p.pronamespace
            JOIN pg_language l ON l.oid = p.prolang
            WHERE p.prokind IN ('f', 'p')
              AND n.nspname NOT IN ('pg_catalog', 'information_schema')
              AND n.nspname NOT LIKE 'pg_toast%'
              AND NOT EXISTS (SELECT 1 FROM pg_depend d
                              WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid AND d.deptype = 'e')
            ORDER BY 4, 2, 3, 5
            """
        return try await rows(sql).map { r in
            RoutineSummary(oid: r[0]!, schema: r[1]!, name: r[2]!, kind: r[3]!, arguments: r[4] ?? "",
                           returns: r[5] ?? "", language: r[6] ?? "")
        }
    }

    /// The function's or procedure's CREATE OR REPLACE statement, as psql's `\sf` shows it;
    /// nil when it no longer exists.
    func routineCode(_ routine: RoutineSummary) async throws -> String? {
        try await rows("SELECT pg_get_functiondef($1::text::oid)", [routine.oid]).first?.first ?? nil
    }

    func exactRowCount(_ ref: TableRef) async throws -> Int {
        let value = try await rows("SELECT count(*)::text FROM \(ref.qualifiedSQL)").first?.first ?? nil
        return Int(value ?? "") ?? 0
    }

    /// Catalog queries equivalent to psql's `\d table`; for a view also its definition (`\d+ view`).
    func describe(_ summary: TableSummary) async throws -> TableDescription {
        let oid = [summary.oid] as [String?]
        let columns = try await rows("""
            SELECT a.attname::text, format_type(a.atttypid, a.atttypmod),
                   coalesce(co.collname::text, ''), a.attnotnull::text,
                   CASE WHEN a.attidentity = 'a' THEN 'generated always as identity'
                        WHEN a.attidentity = 'd' THEN 'generated by default as identity'
                        WHEN a.attgenerated = 's' THEN 'generated always as (' || pg_get_expr(d.adbin, d.adrelid, true) || ') stored'
                        ELSE coalesce(pg_get_expr(d.adbin, d.adrelid, true), '') END,
                   a.attnum::text
            FROM pg_attribute a
            LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
            LEFT JOIN pg_type t ON t.oid = a.atttypid
            LEFT JOIN pg_collation co ON co.oid = a.attcollation AND a.attcollation <> t.typcollation
            WHERE a.attrelid = $1::text::oid AND a.attnum > 0 AND NOT a.attisdropped
            ORDER BY a.attnum
            """, oid).map { r in
            ColumnInfo(name: r[0]!, type: r[1]!, collation: r[2] ?? "", notNull: r[3] == "true", defaultExpr: r[4] ?? "",
                       attnum: Int(r[5] ?? "") ?? 0)
        }
        let primaryKey = try await rows("""
            SELECT a.attname::text
            FROM pg_index i
            CROSS JOIN LATERAL unnest(i.indkey) WITH ORDINALITY AS k(attnum, ord)
            JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum
            WHERE i.indrelid = $1::text::oid AND i.indisprimary
            ORDER BY k.ord
            """, oid).compactMap { $0[0] }
        let indexes = try await rows("""
            SELECT '"' || c2.relname || '"'
                   || CASE WHEN i.indisprimary THEN ' PRIMARY KEY,'
                           WHEN con.contype = 'u' THEN ' UNIQUE CONSTRAINT,'
                           WHEN i.indisunique THEN ' UNIQUE,' ELSE '' END
                   || ' ' || substring(pg_get_indexdef(i.indexrelid, 0, true) FROM ' USING (.*)$')
            FROM pg_index i
            JOIN pg_class c2 ON c2.oid = i.indexrelid
            LEFT JOIN pg_constraint con ON con.conindid = i.indexrelid AND con.conrelid = i.indrelid AND con.contype IN ('p', 'u', 'x')
            WHERE i.indrelid = $1::text::oid
            ORDER BY i.indisprimary DESC, c2.relname
            """, oid).compactMap { $0[0] }
        let checks = try await rows("""
            SELECT '"' || conname || '" ' || pg_get_constraintdef(oid, true)
            FROM pg_constraint WHERE conrelid = $1::text::oid AND contype = 'c' ORDER BY conname
            """, oid).compactMap { $0[0] }
        let foreignKeys = try await rows("""
            SELECT '"' || conname || '" ' || pg_get_constraintdef(oid, true)
            FROM pg_constraint WHERE conrelid = $1::text::oid AND contype = 'f' ORDER BY conname
            """, oid).compactMap { $0[0] }
        let referencedBy = try await rows("""
            SELECT 'TABLE "' || conrelid::regclass::text || '" CONSTRAINT "' || conname || '" ' || pg_get_constraintdef(oid, true)
            FROM pg_constraint WHERE confrelid = $1::text::oid AND contype = 'f' ORDER BY 1
            """, oid).compactMap { $0[0] }
        // quote_ident on the server knows which names are reserved words.
        let names = [summary.ref.schema, summary.ref.name] + primaryKey
        let quoted = try await rows("SELECT " + names.indices.map { "quote_ident($\($0 + 1))" }.joined(separator: ", "),
                                    names)[0].map { $0 ?? "" }
        var defaultSQL = "SELECT * FROM \(quoted[0]).\(quoted[1])"
        if quoted.count > 2 { defaultSQL += " ORDER BY " + quoted[2...].joined(separator: ", ") }
        let viewDefinition = summary.isView
            ? try await rows("SELECT pg_get_viewdef($1::text::oid, true)", oid).first?.first ?? nil
            : nil
        return TableDescription(summary: summary, columns: columns, primaryKey: primaryKey, indexes: indexes,
                                checks: checks, foreignKeys: foreignKeys, referencedBy: referencedBy,
                                defaultSQL: defaultSQL, viewDefinition: viewDefinition)
    }

    // MARK: DB Table

    /// One page of the table: `limit` rows after skipping `offset`, in primary-key (or ctid) order.
    /// With `options`, the page is taken from the sorted and filtered rows; totalRows is then
    /// the filtered count and unfilteredTotal the table's. A view's rows come without row IDs, so the
    /// grid is read-only; a plain view has no ctid either, so its rows keep the view's own order.
    func fetchGrid(_ description: TableDescription, limit: Int, offset: Int = 0,
                   options: GridQueryOptions = GridQueryOptions()) async throws -> GridData {
        let ref = description.summary.ref
        let withRowIDs = !description.summary.isView
        let selectList = ((withRowIDs ? ["t.ctid::text"] : []) + description.columns.map { "t." + quoteIdent($0.name) + "::text" })
            .joined(separator: ", ")
        // Qualified with "t." so filters and ORDER BY use the typed column, not its ::text output column.
        let expr = { (name: String) in "t." + quoteIdent(name) }
        var binds = SQLBinds()
        let whereSQL = GridSQL.whereClause(options, columns: description.columns, expr: expr, binds: &binds)
        // The key comes last so pages stay stable under a sort with repeated values.
        let key = !description.primaryKey.isEmpty ? description.primaryKey.map(expr)
            : description.summary.isPlainView ? [] : ["t.ctid"]
        let orderBy = ([GridSQL.orderTerm(options, expr: expr)].compactMap { $0 } + key).joined(separator: ", ")
        let from = "\(ref.qualifiedSQL) AS t\(whereSQL)"
        let orderSQL = orderBy.isEmpty ? "" : " ORDER BY \(orderBy)"
        let result = try await rows("SELECT \(selectList) FROM \(from)\(orderSQL) LIMIT \(max(1, limit)) OFFSET \(max(0, offset))",
                                    binds.values)
        let unfiltered = try await exactRowCount(ref)
        let total = whereSQL.isEmpty
            ? unfiltered
            : Int((try await rows("SELECT count(*)::text FROM \(from)", binds.values)).first?.first.flatMap { $0 } ?? "") ?? 0
        return GridData(description: description,
                        title: ref.displayName,
                        columns: description.columns,
                        rows: withRowIDs ? result.map { Array($0.dropFirst()) } : result,
                        rowIDs: withRowIDs ? result.map { $0[0] ?? "" } : [],
                        totalRows: total,
                        offset: max(0, offset),
                        options: options,
                        unfilteredTotal: whereSQL.isEmpty ? nil : unfiltered)
    }

    /// Distinct values of `column` (with row counts) for the filter checklist, honouring the
    /// other columns' filters. At most `limit` values; `truncated` when there are more.
    func distinctValues(source: GridSource, column: String, columns: [ColumnInfo], options: GridQueryOptions,
                        limit: Int = 1000) async throws -> (values: [DistinctValue], truncated: Bool) {
        let alias = { (name: String) -> String in
            switch source {
            case .table: "t." + quoteIdent(name)
            case .query: "mx_q." + quoteIdent(name)
            }
        }
        var binds = SQLBinds()
        let whereSQL = GridSQL.whereClause(options, columns: columns, except: column, expr: alias, binds: &binds)
        let c = alias(column)
        let prefix: String
        let from: String
        switch source {
        case .table(let ref):
            prefix = ""
            from = "\(ref.qualifiedSQL) AS t"
        case .query(let sql):
            prefix = Self.queryPrefix + sql + "\n) "
            from = "mx_q"
        }
        // Group and order by the typed value (numbers sort as numbers); types without ordering
        // (e.g. json) fall back to their text.
        let typed = prefix + "SELECT \(c)::text, count(*)::text FROM \(from)\(whereSQL) GROUP BY \(c) ORDER BY \(c) NULLS FIRST LIMIT \(limit + 1)"
        let asText = prefix + "SELECT \(c)::text, count(*)::text FROM \(from)\(whereSQL) GROUP BY 1 ORDER BY 1 NULLS FIRST LIMIT \(limit + 1)"
        var result: [[String?]] = []
        for sql in [typed, asText] {
            _ = try await rows("BEGIN READ ONLY")
            do {
                result = try await rows(sql, binds.values)
                _ = try await rows("COMMIT")
                break
            } catch {
                _ = try? await rows("ROLLBACK")
                if sql == asText { throw DatabaseError.from(error) }
            }
        }
        let values = result.prefix(limit).map { DistinctValue(value: $0[0], count: Int($0[1] ?? "") ?? 0) }
        return (values, result.count > limit)
    }

    /// Runs the planned UPDATEs. Each statement must touch exactly one row;
    /// otherwise its transaction is rolled back (the whole batch when `singleTransaction`).
    func apply(_ updates: [PlannedUpdate], singleTransaction: Bool) async throws -> UpdateOutcome {
        var outcome = UpdateOutcome()
        if singleTransaction {
            _ = try await rows("BEGIN")
            do {
                for update in updates {
                    let count = try await rows(update.sql, update.binds).count
                    guard count == 1 else {
                        throw DatabaseError(message: Self.mismatch(update, count) + "\nNo changes were applied (rolled back).")
                    }
                }
                _ = try await rows("COMMIT")
                outcome.applied = updates.count
            } catch {
                _ = try? await rows("ROLLBACK")
                throw DatabaseError.from(error)
            }
        } else {
            for update in updates {
                do {
                    _ = try await rows("BEGIN")
                    let count = try await rows(update.sql, update.binds).count
                    if count == 1 {
                        _ = try await rows("COMMIT")
                        outcome.applied += 1
                    } else {
                        _ = try await rows("ROLLBACK")
                        outcome.failures.append(Self.mismatch(update, count))
                    }
                } catch {
                    _ = try? await rows("ROLLBACK")
                    outcome.failures.append("Row \(update.rowLabel): \(DatabaseError.from(error).message)")
                }
            }
        }
        return outcome
    }

    // MARK: Run SQL

    /// Parses and analyses `sql` on the server without running it (PREPARE / DEALLOCATE).
    /// Errors carry positions relative to `sql`.
    func preflight(_ sql: String) async throws -> SQLPreflight {
        preflightCounter += 1
        let name = "mx_preflight_\(preflightCounter)"
        let prefix = "PREPARE \(name) AS "
        do {
            _ = try await rows(prefix + sql)
        } catch let error as DatabaseError {
            throw error.shifted(by: prefix.count)
        }
        let info: [[String?]]
        do {
            info = try await rows("""
                SELECT coalesce(array_length(parameter_types, 1), 0)::text, u.t::text
                FROM pg_prepared_statements
                LEFT JOIN LATERAL unnest(result_types) WITH ORDINALITY AS u(t, o) ON true
                WHERE name = $1
                ORDER BY u.o
                """, [name])
        } catch {
            _ = try? await rows("DEALLOCATE \(name)")
            throw error
        }
        _ = try await rows("DEALLOCATE \(name)")
        if let parameters = info.first?[0], parameters != "0" {
            throw DatabaseError(message: "The statement uses parameters ($1 …). Replace them with values.")
        }
        return SQLPreflight(resultTypes: info.compactMap { $0[1] })
    }

    static let queryPrefix = "WITH mx_q AS (\n"

    /// Runs a statement that returns rows and fetches at most `limit` of them.
    /// Without `allowWrites` it runs in a READ ONLY transaction and throws
    /// `WriteNotAllowed` if the statement tries to change data.
    func runQuery(_ sql: String, limit: Int, offset: Int = 0, allowWrites: Bool,
                  options: GridQueryOptions = GridQueryOptions(), columns filterColumns: [ColumnInfo] = []) async throws -> QueryResult {
        let limit = max(1, limit)
        var columns: [QueryColumn] = []
        var result: [[String?]] = []
        // One row past the limit tells whether more rows were available.
        try await streamQuery(sql, limit: limit + 1, offset: offset, allowWrites: allowWrites,
                              options: options, filterColumns: filterColumns) {
            columns = $0
        } row: {
            result.append($0)
        }
        return QueryResult(columns: columns, rows: Array(result.prefix(limit)), hasMore: result.count > limit)
    }

    /// Streams every row of the read-only query `sql` into a CSV file (header row first)
    /// without holding the rows in memory. Returns the number of data rows written.
    func exportCSV(_ sql: String, to url: URL, options: GridQueryOptions = GridQueryOptions(),
                   columns filterColumns: [ColumnInfo] = []) async throws -> Int {
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let file = try? FileHandle(forWritingTo: url) else {
            throw DatabaseError(message: "Could not create \(url.lastPathComponent).")
        }
        var buffer = Data()
        var count = 0
        do {
            try await streamQuery(sql, limit: nil, offset: 0, allowWrites: false,
                                  options: options, filterColumns: filterColumns) { columns in
                buffer.append(csvLine(columns.map(\.name)))
            } row: { values in
                buffer.append(csvLine(values))
                count += 1
                if buffer.count >= 1 << 20 {
                    try file.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            try file.write(contentsOf: buffer)
            try file.close()
            return count
        } catch {
            try? file.close()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// Runs `sql` wrapped in a CTE and hands over the column metadata, then each row
    /// as text values. Without `allowWrites` it runs in a READ ONLY transaction and
    /// throws `WriteNotAllowed` if the statement tries to change data.
    private func streamQuery(_ sql: String, limit: Int?, offset: Int, allowWrites: Bool,
                             options: GridQueryOptions = GridQueryOptions(), filterColumns: [ColumnInfo] = [],
                             columns onColumns: ([QueryColumn]) throws -> Void,
                             row onRow: ([String?]) throws -> Void) async throws {
        // Each row comes back as its composite text form, mx_q::text, so every column is
        // decoded as text whatever its type. mx_q.* only supplies the column metadata.
        // Sorting and filters apply to the CTE's columns by name.
        let expr = { (name: String) in "mx_q." + quoteIdent(name) }
        var binds = SQLBinds()
        let whereSQL = GridSQL.whereClause(options, columns: filterColumns, expr: expr, binds: &binds)
        let orderSQL = GridSQL.orderTerm(options, expr: expr).map { " ORDER BY " + $0 } ?? ""
        let wrapped = Self.queryPrefix + sql + "\n) SELECT mx_q::text, mx_q.* FROM mx_q" + whereSQL + orderSQL
            + (limit.map { " LIMIT \($0)" } ?? "")
            + (offset > 0 ? " OFFSET \(offset)" : "")
        var bindings = PostgresBindings()
        for value in binds.values {
            if let value { bindings.append(value) } else { bindings.appendNull() }
        }
        _ = try await rows(allowWrites ? "BEGIN" : "BEGIN READ ONLY")
        do {
            let sequence = try await connection.query(PostgresQuery(unsafeSQL: wrapped, binds: bindings), logger: logger)
            let metadata = sequence.columns.dropFirst()
            try onColumns(metadata.map {
                QueryColumn(name: $0.name, tableOID: UInt32(bitPattern: $0.tableOID),
                            attnum: Int($0.columnAttributeNumber), type: $0.dataType.knownSQLName ?? "oid \($0.dataType.rawValue)")
            })
            // Record output writes booleans as t/f; bool::text (used everywhere else) gives true/false.
            let boolColumns = metadata.enumerated().filter { $0.element.dataType == .bool }.map(\.offset)
            for try await row in sequence {
                var values = parseRecord(try row.first!.decode(String.self), fieldCount: metadata.count)
                for index in boolColumns {
                    values[index] = values[index].map { $0 == "t" ? "true" : $0 == "f" ? "false" : $0 }
                }
                try onRow(values)
            }
            _ = try await rows("COMMIT")
        } catch {
            _ = try? await rows("ROLLBACK")
            let error = DatabaseError.from(error)
            if error.sqlState == "25006" { throw WriteNotAllowed() }
            throw error.shifted(by: Self.queryPrefix.count)
        }
    }

    /// Runs a statement that returns no rows (INSERT/UPDATE/DELETE/MERGE) in its own transaction.
    func execute(_ sql: String) async throws {
        _ = try await rows("BEGIN")
        do {
            _ = try await rows(sql)
            _ = try await rows("COMMIT")
        } catch {
            _ = try? await rows("ROLLBACK")
            throw DatabaseError.from(error)
        }
    }

    /// Runs a CREATE, ALTER or DROP statement as sent, as its own transaction (autocommit), so a failing
    /// statement leaves nothing behind, and statements PostgreSQL refuses inside BEGIN ... COMMIT
    /// (CREATE / DROP DATABASE, CREATE INDEX CONCURRENTLY, ALTER SYSTEM, ...) work too. One statement only: the
    /// extended query protocol rejects several.
    func runDDL(_ sql: String) async throws {
        try await call(sql)
    }

    /// Runs a CALL statement as sent, outside an explicit transaction block: a procedure may then
    /// COMMIT or ROLLBACK itself, which PostgreSQL refuses inside BEGIN ... COMMIT. Without its own
    /// transaction control the procedure's work is committed when the CALL succeeds. Any OUT/INOUT
    /// values it sends back are not shown.
    func call(_ sql: String) async throws {
        do {
            for try await _ in try await connection.query(PostgresQuery(unsafeSQL: sql), logger: logger) {}
        } catch {
            throw DatabaseError.from(error)
        }
    }

    private static func mismatch(_ update: PlannedUpdate, _ count: Int) -> String {
        count == 0
            ? "Row \(update.rowLabel): not found, or changed since it was loaded."
            : "Row \(update.rowLabel): matches \(count) rows; the row key is not unique."
    }
}
