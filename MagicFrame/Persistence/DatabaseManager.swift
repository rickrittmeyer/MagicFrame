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
}
