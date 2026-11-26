import Foundation
import SQLite3

enum CodexDesktopHostStore {
    static let membershipKey = "thread-project-membership-host-ids"
    static let migratedKey = "app-server-migrated-pinned-thread-ids-by-host"
    static let ownerMigratedPrefix = "electron-owner-value:" + migratedKey + ":"
    static let managedHostPrefix = "remote-ssh-codex-managed:"

    static func state(in directory: URL) -> [String: Any] {
        if let state = readDatabase(directory.appendingPathComponent(".codex-global-state.sqlite")) {
            return state
        }
        let file = directory.appendingPathComponent(".codex-global-state.json")
        guard let data = try? Data(contentsOf: file),
              let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return state
    }

    static func hostID(for threadID: String, state: [String: Any]) -> String? {
        if let host = (state[membershipKey] as? [String: String])?[threadID] {
            return host.hasPrefix(managedHostPrefix) ? host : nil
        }
        // Migration records can be account-scoped. Only accept an exact
        // thread match that identifies a single managed host across them.
        var hosts = Set<String>()
        for (key, value) in state where key == migratedKey || key.hasPrefix(ownerMigratedPrefix) {
            guard let migrated = value as? [String: [String]] else { continue }
            for (location, ids) in migrated where ids.contains(threadID) && location.hasPrefix(managedHostPrefix) {
                guard let separator = location.range(of: ":/") else { continue }
                hosts.insert(String(location[..<separator.lowerBound]))
            }
        }
        return hosts.count == 1 ? hosts.first : nil
    }

    private static func readDatabase(_ file: URL) -> [String: Any]? {
        var db: OpaquePointer?
        let result = sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        defer { sqlite3_close(db) }
        guard result == SQLITE_OK else { return nil }

        let sql = """
            SELECT key, value FROM settings
            WHERE scope = 'global'
            AND (key IN ('\(membershipKey)', '\(migratedKey)') OR key GLOB '\(ownerMigratedPrefix)*')
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        var state: [String: Any] = [:]
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            if let key = sqlite3_column_text(statement, 0),
               let value = sqlite3_column_text(statement, 1),
               let decoded = try? JSONSerialization.jsonObject(with: Data(String(cString: value).utf8)) {
                state[String(cString: key)] = decoded
            }
            step = sqlite3_step(statement)
        }
        return step == SQLITE_DONE ? state : nil
    }
}
