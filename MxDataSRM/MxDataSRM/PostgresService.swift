//
//  PostgresService.swift
//  MxDataSRM
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
    private let logger = Logger(label: "com.k3jdr.MxDataSRM.postgres")
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
                configuration: configuration, id: 1, logger: Logger(label: "com.k3jdr.MxDataSRM.postgres"))
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

    func serverVersion() async throws -> String {
        try await rows("SELECT current_setting('server_version')").first?.first.flatMap { $0 } ?? "?"
    }

    // MARK: DB Table Selection

    func listTables() async throws -> [TableSummary] {
        let sql = """
            SELECT c.oid::text, n.nspname::text, c.relname::text,
                   CASE c.relkind WHEN 'p' THEN 'partitioned table' ELSE 'table' END,
                   (CASE WHEN c.reltuples >= 0 THEN c.reltuples::bigint
                         ELSE coalesce(s.n_live_tup, 0) END)::text,
                   pg_size_pretty(pg_total_relation_size(c.oid))
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            LEFT JOIN pg_stat_all_tables s ON s.relid = c.oid
            WHERE c.relkind IN ('r', 'p')
              AND n.nspname NOT IN ('pg_catalog', 'information_schema')
              AND n.nspname NOT LIKE 'pg_toast%'
            ORDER BY 2, 3
            """
        return try await rows(sql).map { r in
            TableSummary(oid: r[0]!, ref: TableRef(schema: r[1]!, name: r[2]!), kind: r[3]!,
                         estimatedRows: Int(r[4] ?? "") ?? 0, totalSize: r[5] ?? "")
        }
    }

    func exactRowCount(_ ref: TableRef) async throws -> Int {
        let value = try await rows("SELECT count(*)::text FROM \(ref.qualifiedSQL)").first?.first ?? nil
        return Int(value ?? "") ?? 0
    }

    /// Catalog queries equivalent to psql's `\d table`.
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
        return TableDescription(summary: summary, columns: columns, primaryKey: primaryKey, indexes: indexes,
                                checks: checks, foreignKeys: foreignKeys, referencedBy: referencedBy,
                                defaultSQL: defaultSQL)
    }

    // MARK: DB Table

    func fetchGrid(_ description: TableDescription, limit: Int) async throws -> GridData {
        let ref = description.summary.ref
        let selectList = (["t.ctid::text"] + description.columns.map { "t." + quoteIdent($0.name) + "::text" })
            .joined(separator: ", ")
        // Qualified with "t." so ORDER BY sorts the typed column, not its ::text output column.
        let orderBy = description.primaryKey.isEmpty
            ? "t.ctid"
            : description.primaryKey.map { "t." + quoteIdent($0) }.joined(separator: ", ")
        let result = try await rows("SELECT \(selectList) FROM \(ref.qualifiedSQL) AS t ORDER BY \(orderBy) LIMIT \(max(1, limit))")
        let total = try await exactRowCount(ref)
        return GridData(description: description,
                        title: ref.displayName,
                        columns: description.columns,
                        rows: result.map { Array($0.dropFirst()) },
                        rowIDs: result.map { $0[0] ?? "" },
                        totalRows: total)
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
    func runQuery(_ sql: String, limit: Int, allowWrites: Bool) async throws -> QueryResult {
        // Each row comes back as its composite text form, mx_q::text, so every column is
        // decoded as text whatever its type. mx_q.* only supplies the column metadata.
        let wrapped = Self.queryPrefix + sql + "\n) SELECT mx_q::text, mx_q.* FROM mx_q LIMIT \(max(1, limit) + 1)"
        _ = try await rows(allowWrites ? "BEGIN" : "BEGIN READ ONLY")
        do {
            let sequence = try await connection.query(PostgresQuery(unsafeSQL: wrapped), logger: logger)
            let columns = sequence.columns.dropFirst().map {
                QueryColumn(name: $0.name, tableOID: UInt32(bitPattern: $0.tableOID),
                            attnum: Int($0.columnAttributeNumber), type: $0.dataType.knownSQLName ?? "oid \($0.dataType.rawValue)")
            }
            // Record output writes booleans as t/f; bool::text (used everywhere else) gives true/false.
            let boolColumns = sequence.columns.dropFirst().enumerated().filter { $0.element.dataType == .bool }.map(\.offset)
            var result: [[String?]] = []
            for try await row in sequence {
                var values = parseRecord(try row.first!.decode(String.self), fieldCount: columns.count)
                for index in boolColumns {
                    values[index] = values[index].map { $0 == "t" ? "true" : $0 == "f" ? "false" : $0 }
                }
                result.append(values)
            }
            _ = try await rows("COMMIT")
            let hasMore = result.count > max(1, limit)
            return QueryResult(columns: columns, rows: Array(result.prefix(max(1, limit))), hasMore: hasMore)
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

    private static func mismatch(_ update: PlannedUpdate, _ count: Int) -> String {
        count == 0
            ? "Row \(update.rowLabel): not found, or changed since it was loaded."
            : "Row \(update.rowLabel): matches \(count) rows; the row key is not unique."
    }
}
