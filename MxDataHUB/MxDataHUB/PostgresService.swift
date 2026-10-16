//
//  PostgresService.swift
//  MxDataHUB
//
//  The PostgreSQL connection (PostgresNIO). All queries select text columns, so rows decode
//  uniformly as [String?]; values are always sent as text parameters.
//

import Foundation
import PostgresNIO

nonisolated enum SSLMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case disable, prefer, require
    var id: String { rawValue }
}

nonisolated struct ConnectionSettings: Codable, Equatable, Sendable {
    var host = "localhost"
    var port = 5432
    var user = "postgres"
    var database = "srm"
    var sslMode: SSLMode = .disable
    var savePasswordInKeychain = true

    /// Keychain account under which the password for these settings is stored.
    var keychainAccount: String { "\(user)@\(host):\(port)/\(database)" }
    var displayName: String { "\(user)@\(host):\(port)/\(database)" }
}

extension ConnectionSettings {
    /// Settings are kept as separate defaults so launch arguments can override any of them
    /// (e.g. `-host 192.168.0.223 -database srm`).
    static func load(from defaults: UserDefaults = .standard) -> ConnectionSettings {
        var s = ConnectionSettings()
        if let v = defaults.string(forKey: "host"), !v.isEmpty { s.host = v }
        if defaults.object(forKey: "port") != nil { s.port = defaults.integer(forKey: "port") }
        if let v = defaults.string(forKey: "user"), !v.isEmpty { s.user = v }
        if let v = defaults.string(forKey: "database"), !v.isEmpty { s.database = v }
        if let v = defaults.string(forKey: "sslMode"), let mode = SSLMode(rawValue: v) { s.sslMode = mode }
        if defaults.object(forKey: "savePasswordInKeychain") != nil {
            s.savePasswordInKeychain = defaults.bool(forKey: "savePasswordInKeychain")
        }
        return s
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(host, forKey: "host")
        defaults.set(port, forKey: "port")
        defaults.set(user, forKey: "user")
        defaults.set(database, forKey: "database")
        defaults.set(sslMode.rawValue, forKey: "sslMode")
        defaults.set(savePasswordInKeychain, forKey: "savePasswordInKeychain")
    }
}

nonisolated struct DatabaseError: LocalizedError {
    var message: String
    var sqlState: String?
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
                return DatabaseError(message: text, sqlState: info[.sqlState])
            }
            if let underlying = psql.underlying {
                return DatabaseError(message: "Could not connect (\(psql.code)): \(String(describing: underlying))")
            }
            return DatabaseError(message: "\(psql.code)")
        }
        return DatabaseError(message: error.localizedDescription)
    }
}

actor PostgresService {
    private let connection: PostgresConnection
    private let logger = Logger(label: "com.k3jdr.MxDataHUB.postgres")

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
                configuration: configuration, id: 1, logger: Logger(label: "com.k3jdr.MxDataHUB.postgres"))
            return PostgresService(connection: connection)
        } catch {
            throw DatabaseError.from(error)
        }
    }

    func close() async {
        try? await connection.close()
    }

    /// Runs `sql` with text parameters and returns every row as text values. Each call is its own
    /// statement (autocommit).
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
}
