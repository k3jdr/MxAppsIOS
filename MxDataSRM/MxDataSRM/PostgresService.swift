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
                return DatabaseError(message: text)
            }
            if let underlying = psql.underlying {
                return DatabaseError(message: "Could not connect (\(psql.code)): \(String(describing: underlying))")
            }
            return DatabaseError(message: "\(psql.code)")
        }
        return DatabaseError(message: error.localizedDescription)
    }
}

nonisolated struct UpdateOutcome: Sendable {
    var applied = 0
    var failures: [String] = []
}

actor PostgresService {
    private let connection: PostgresConnection
    private let logger = Logger(label: "com.k3jdr.MxDataSRM.postgres")

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
                        ELSE coalesce(pg_get_expr(d.adbin, d.adrelid, true), '') END
            FROM pg_attribute a
            LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
            LEFT JOIN pg_type t ON t.oid = a.atttypid
            LEFT JOIN pg_collation co ON co.oid = a.attcollation AND a.attcollation <> t.typcollation
            WHERE a.attrelid = $1::text::oid AND a.attnum > 0 AND NOT a.attisdropped
            ORDER BY a.attnum
            """, oid).map { r in
            ColumnInfo(name: r[0]!, type: r[1]!, collation: r[2] ?? "", notNull: r[3] == "true", defaultExpr: r[4] ?? "")
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
        return TableDescription(summary: summary, columns: columns, primaryKey: primaryKey, indexes: indexes,
                                checks: checks, foreignKeys: foreignKeys, referencedBy: referencedBy)
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

    private static func mismatch(_ update: PlannedUpdate, _ count: Int) -> String {
        count == 0
            ? "Row \(update.rowLabel): not found, or changed since it was loaded."
            : "Row \(update.rowLabel): matches \(count) rows; the row key is not unique."
    }
}
