import Foundation
import SQLite3

/// Owns the SQLite connection and serial access queue for MagicFrame.
final class DatabaseManager {

    static let shared = DatabaseManager()

    let queue: DispatchQueue
    let queueKey = DispatchSpecificKey<UInt8>()

    private(set) var connection: OpaquePointer?

    var isOnQueue: Bool {
        DispatchQueue.getSpecific(key: queueKey) != nil
    }

    var databaseURL: URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MagicFrame.sqlite")
    }

    private init() {
        queue = DispatchQueue(label: "MagicFrame.DatabaseManager", qos: .utility)
        queue.setSpecific(key: queueKey, value: 1)
        openConnection()
    }

    private func openConnection() {
        var database: OpaquePointer?
        let path = databaseURL.path

        if sqlite3_open(path, &database) == SQLITE_OK {
            connection = database
            sqlite3_exec(connection, "PRAGMA journal_mode=WAL;", nil, nil, nil)
            sqlite3_busy_timeout(connection, 5_000)
            print("Database opened")
            print("Database path: \(path)")
        } else {
            print("Unable to open database")
        }
    }

    func sync<T>(_ work: () throws -> T) rethrows -> T {
        try queue.sync { try work() }
    }

    func bootstrapSchema(legacyHooks: LegacyDataMigrationHooks = LegacyDataMigrationHooks()) {
        guard let connection else { return }
        queue.sync {
            let start = CFAbsoluteTimeGetCurrent()
            SQLiteMigrations.createTablesIfNeeded(on: connection)
            SQLiteMigrations.migrateTablesIfNeeded(on: connection, legacyHooks: legacyHooks)
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            if elapsed > 0.5 {
                print(String(format: "Schema migration completed in %.1fs", elapsed))
            }
        }
    }

    func columnExists(table: String, column: String) -> Bool {
        guard let connection else { return false }
        return SQLiteMigrations.columnExists(table: table, column: column, on: connection)
    }

    /// Deletes the on-disk database (including WAL) and bootstraps a fresh schema.
    /// Destructive developer tool — not required for normal upgrades or phone installs.
    @discardableResult
    func resetDevelopmentDatabase(legacyHooks: LegacyDataMigrationHooks) -> Bool {
        queue.sync {
            if let open = connection {
                sqlite3_exec(open, "PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, nil)
                sqlite3_close(open)
                connection = nil
            }

            let base = databaseURL
            let fm = FileManager.default
            let urls = [
                base,
                URL(fileURLWithPath: base.path + "-wal"),
                URL(fileURLWithPath: base.path + "-shm"),
            ]
            for url in urls where fm.fileExists(atPath: url.path) {
                do {
                    try fm.removeItem(at: url)
                } catch {
                    print("Unable to remove \(url.lastPathComponent): \(error)")
                    openConnection()
                    return false
                }
            }

            openConnection()
            guard let connection else {
                print("Unable to reopen database after DEV reset")
                return false
            }

            SQLiteMigrations.createTablesIfNeeded(on: connection)
            SQLiteMigrations.migrateTablesIfNeeded(on: connection, legacyHooks: legacyHooks)
            print("DEV reset complete (fresh database file)")
            return true
        }
    }

    @available(*, deprecated, renamed: "resetDevelopmentDatabase")
    @discardableResult
    func resetDevelopmentTables(legacyHooks: LegacyDataMigrationHooks) -> Bool {
        resetDevelopmentDatabase(legacyHooks: legacyHooks)
    }

    /// Writes a consistent single-file snapshot (WAL-safe) for Share / AirDrop.
    func exportConsistentSnapshot() throws -> URL {
        try queue.sync {
            guard let source = connection else {
                throw DatabaseExportError.notOpen
            }

            // Fold recent WAL pages into the main DB without blocking readers hard.
            sqlite3_exec(source, "PRAGMA wal_checkpoint(PASSIVE);", nil, nil, nil)

            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd-HHmmss"
            let stamp = formatter.string(from: Date())
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("MagicFrame-\(stamp).sqlite", isDirectory: false)

            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }

            var destDB: OpaquePointer?
            guard sqlite3_open(destination.path, &destDB) == SQLITE_OK, let destDB else {
                throw DatabaseExportError.openFailed(destination.path)
            }
            defer { sqlite3_close(destDB) }

            guard let backup = sqlite3_backup_init(destDB, "main", source, "main") else {
                let message = String(cString: sqlite3_errmsg(destDB))
                throw DatabaseExportError.backupFailed(message)
            }

            let step = sqlite3_backup_step(backup, -1)
            let finish = sqlite3_backup_finish(backup)
            guard step == SQLITE_DONE, finish == SQLITE_OK else {
                let message = String(cString: sqlite3_errmsg(destDB))
                throw DatabaseExportError.backupFailed(message)
            }

            print("Database export ready: \(destination.path)")
            return destination
        }
    }
}

enum DatabaseExportError: LocalizedError {
    case notOpen
    case openFailed(String)
    case backupFailed(String)

    var errorDescription: String? {
        switch self {
        case .notOpen:
            return "Database is not open."
        case .openFailed(let path):
            return "Could not create export file at \(path)."
        case .backupFailed(let message):
            return "Database backup failed: \(message)"
        }
    }
}
