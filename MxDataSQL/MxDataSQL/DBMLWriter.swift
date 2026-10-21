//
//  DBMLWriter.swift
//  MxDataSQL
//
//  Diagram ▸ Write DBML: reads the connected database's catalog (tables, columns, comments,
//  constraints, indexes) for the chosen schemas and writes it as DBML. Tables in public are written
//  unqualified, others as schema.table; foreign keys become Refs; each schema is a TableGroup when
//  there are several. Check and exclusion constraints are kept as comments.
//

import Foundation

nonisolated enum DBMLWriter {
    /// Schemas with at least one table, user schemas only.
    static let schemasSQL = """
        SELECT n.nspname::text FROM pg_namespace n
        WHERE n.nspname NOT LIKE 'pg\\_%' AND n.nspname <> 'information_schema'
          AND EXISTS (SELECT 1 FROM pg_class c WHERE c.relnamespace = n.oid AND c.relkind IN ('r', 'p'))
        ORDER BY n.nspname <> 'public', 1
        """

    /// One JSON document describing the tables of the schemas in $1 (comma-separated).
    static let catalogSQL = """
        SELECT json_build_object(
         'tables', (SELECT json_agg(json_build_object('schema', n.nspname, 'name', c.relname,
           'note', obj_description(c.oid, 'pg_class'),
           'columns', (SELECT json_agg(json_build_object(
                'name', a.attname, 'type', format_type(a.atttypid, a.atttypmod), 'notnull', a.attnotnull,
                'default', pg_get_expr(d.adbin, d.adrelid), 'identity', a.attidentity, 'note', col_description(c.oid, a.attnum)) ORDER BY a.attnum)
              FROM pg_attribute a LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
              WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped),
           'constraints', (SELECT json_agg(json_build_object('name', k.conname, 'type', k.contype,
                'cols', (SELECT json_agg(att.attname ORDER BY u.ord) FROM unnest(k.conkey) WITH ORDINALITY u(n, ord)
                           JOIN pg_attribute att ON att.attrelid = k.conrelid AND att.attnum = u.n),
                'fschema', fn.nspname, 'ftable', fc.relname,
                'fcols', (SELECT json_agg(att.attname ORDER BY u.ord) FROM unnest(k.confkey) WITH ORDINALITY u(n, ord)
                            JOIN pg_attribute att ON att.attrelid = k.confrelid AND att.attnum = u.n),
                'ondelete', k.confdeltype, 'def', pg_get_constraintdef(k.oid)) ORDER BY k.conname)
              FROM pg_constraint k
              LEFT JOIN pg_class fc ON fc.oid = k.confrelid
              LEFT JOIN pg_namespace fn ON fn.oid = fc.relnamespace
              WHERE k.conrelid = c.oid),
           'indexes', (SELECT json_agg(json_build_object('name', i.relname, 'unique', x.indisunique, 'primary', x.indisprimary,
                'method', am.amname,
                'keys', (SELECT json_agg(pg_get_indexdef(x.indexrelid, k, true) ORDER BY k)
                           FROM generate_series(1, x.indnkeyatts) AS k),
                'predicate', pg_get_expr(x.indpred, x.indrelid, true)) ORDER BY i.relname)
              FROM pg_index x JOIN pg_class i ON i.oid = x.indexrelid JOIN pg_am am ON am.oid = i.relam
              WHERE x.indrelid = c.oid)
          ) ORDER BY array_position(string_to_array($1, ','), n.nspname::text), c.relname)
          FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
          WHERE n.nspname = ANY (string_to_array($1, ',')) AND c.relkind IN ('r', 'p') AND NOT c.relispartition)
        )::text
        """

    struct Catalog: Decodable {
        var tables: [Table]?
    }
    struct Table: Decodable {
        var schema: String
        var name: String
        var note: String?
        var columns: [Column]
        var constraints: [Constraint]?
        var indexes: [Index]?
    }
    struct Column: Decodable {
        var name: String
        var type: String
        var notnull: Bool
        var `default`: String?
        var identity: String?
        var note: String?
    }
    struct Constraint: Decodable {
        var name: String
        var type: String
        var cols: [String]?
        var fschema: String?
        var ftable: String?
        var fcols: [String]?
        var ondelete: String?
        var def: String
    }
    struct Index: Decodable {
        var name: String
        var unique: Bool
        var primary: Bool
        var method: String?
        var keys: [String]?
        var predicate: String?
    }

    struct Result {
        var text: String
        var tables: Int
        var columns: Int
        var refs: Int
    }

    static func read(_ service: PostgresService, schemas: [String]) async throws -> Catalog {
        guard let json = try await service.rows(catalogSQL, [schemas.joined(separator: ",")]).first?.first ?? nil,
              let data = json.data(using: .utf8) else { return Catalog(tables: []) }
        return try JSONDecoder().decode(Catalog.self, from: data)
    }

    // MARK: Text

    private static let keywords: Set<String> = ["note", "indexes", "ref", "table", "enum", "project", "tablegroup"]

    static func ident(_ name: String) -> String {
        name.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil && !keywords.contains(name.lowercased())
            ? name : "\"" + name.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func tableName(_ schema: String, _ name: String) -> String {
        schema == "public" ? ident(name) : "\(ident(schema)).\(ident(name))"
    }

    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n") + "'"
    }

    static func dbmlType(_ t: String) -> String {
        if let m = t.firstMatch(of: /^character varying\((\d+)\)$/) { return "varchar(\(m.1))" }
        if let m = t.firstMatch(of: /^character\((\d+)\)$/) { return "char(\(m.1))" }
        switch t {
        case "character varying": return "varchar"
        case "timestamp with time zone": return "timestamptz"
        case "timestamp without time zone": return "timestamp"
        case "double precision": return "float8"
        default: return t.contains(" ") ? "\"\(t)\"" : t
        }
    }

    static func dbmlDefault(_ expr: String) -> String {
        let v = expr.replacingOccurrences(of: #"::[\w\s]+(\[\])?$"#, with: "", options: .regularExpression)
        if v.range(of: #"^(-?\d+(\.\d+)?|true|false)$"#, options: .regularExpression) != nil
            || v.range(of: #"^'[^']*'$"#, options: .regularExpression) != nil {
            return "default: \(v)"
        }
        return "default: `\(v)`"
    }

    static func generate(_ catalog: Catalog, source: String, schemas: [String]) -> Result {
        let tables = catalog.tables ?? []
        let onDelete = ["c": "cascade", "n": "set null", "d": "set default", "r": "restrict"]
        let today = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        var lines = ["// \(source) (schema\(schemas.count == 1 ? "" : "s") \(schemas.joined(separator: ", "))), "
                     + "written by MxDataSQL ▸ Diagram ▸ Write DBML on \(today)",
                     "", "Project \(ident(source.components(separatedBy: "/").last ?? "database")) {",
                     "  database_type: 'PostgreSQL'", "}", ""]
        var refs: [String] = []
        var groups: [(String, [String])] = []
        var columnCount = 0
        for t in tables {
            let me = tableName(t.schema, t.name)
            if let i = groups.firstIndex(where: { $0.0 == t.schema }) { groups[i].1.append(me) } else { groups.append((t.schema, [me])) }
            let cons = t.constraints ?? []
            let pk = cons.first { $0.type == "p" }?.cols ?? []
            let unique1 = Set(cons.filter { $0.type == "u" && ($0.cols?.count ?? 0) == 1 }.compactMap { $0.cols?.first })
            lines.append("Table \(me) {")
            if let note = t.note { lines.append("  Note: \(quote(note))") }
            for c in t.columns {
                columnCount += 1
                var s: [String] = []
                if pk.count == 1 && c.name == pk[0] { s.append("pk") }
                let def = c.default ?? ""
                if def.hasPrefix("nextval(") || c.identity == "a" || c.identity == "d" { s.append("increment") }
                else if !def.isEmpty { s.append(dbmlDefault(def)) }
                if c.notnull && !s.contains("pk") { s.append("not null") }
                if unique1.contains(c.name) && !s.contains("pk") { s.append("unique") }
                if let note = c.note { s.append("note: \(quote(note))") }
                lines.append("  \(ident(c.name)) \(dbmlType(c.type))" + (s.isEmpty ? "" : " [\(s.joined(separator: ", "))]"))
            }
            var idx: [String] = []
            if pk.count > 1 { idx.append("    (\(pk.map(ident).joined(separator: ", "))) [pk]") }
            for c in cons where c.type == "u" && (c.cols?.count ?? 0) > 1 {
                idx.append("    (\((c.cols ?? []).map(ident).joined(separator: ", "))) [unique]")
            }
            let constraintNames = Set(cons.map(\.name))
            for i in t.indexes ?? [] where !i.primary && !constraintNames.contains(i.name) {
                let keys = i.keys ?? []
                guard !keys.isEmpty else { continue }
                let spec = keys.map { k in
                    k.range(of: "^[a-z_][a-z0-9_]*$", options: .regularExpression) != nil || k.hasPrefix("\"") ? k : "`\(k)`"
                }
                var settings = ["name: '\(i.name)'"]
                if i.unique { settings.append("unique") }
                if i.method == "hash" { settings.append("type: hash") }
                var extra: [String] = []
                if let m = i.method, m != "btree", m != "hash" { extra.append("\(m) index") }
                if let p = i.predicate { extra.append("partial: WHERE \(p)") }
                if !extra.isEmpty { settings.append("note: \(quote(extra.joined(separator: "; ")))") }
                idx.append("    \(spec.count > 1 ? "(\(spec.joined(separator: ", ")))" : spec[0]) [\(settings.joined(separator: ", "))]")
            }
            if !idx.isEmpty { lines += ["", "  indexes {"] + idx + ["  }"] }
            for c in cons where c.type == "c" { lines.append("  // check: \(c.def)") }
            for c in cons where c.type == "x" { lines.append("  // exclude: \(c.def)") }
            lines += ["}", ""]
            for c in cons where c.type == "f" {
                guard let cols = c.cols, let fcols = c.fcols, let ft = c.ftable else { continue }
                let target = tableName(c.fschema ?? "public", ft)
                let lhs = cols.count == 1 ? "\(me).\(ident(cols[0]))" : "\(me).(\(cols.map(ident).joined(separator: ", ")))"
                let rhs = fcols.count == 1 ? "\(target).\(ident(fcols[0]))" : "\(target).(\(fcols.map(ident).joined(separator: ", ")))"
                let od = c.ondelete.flatMap { onDelete[$0] }
                refs.append("Ref: \(lhs) > \(rhs)" + (od.map { " [delete: \($0)]" } ?? ""))
            }
        }
        if !refs.isEmpty { lines += ["// Relationships (foreign keys)"] + refs.sorted() + [""] }
        if groups.count > 1 {
            for (schema, members) in groups {
                lines.append("TableGroup \(schema.replacingOccurrences(of: #"[^A-Za-z0-9_]"#, with: "_", options: .regularExpression))_schema {")
                lines += members.map { "  \($0)" }
                lines += ["}", ""]
            }
        }
        return Result(text: lines.joined(separator: "\n"), tables: tables.count, columns: columnCount, refs: refs.count)
    }
}
