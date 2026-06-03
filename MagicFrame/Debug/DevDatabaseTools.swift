import Foundation
import Photos
import SQLite3

enum DevDatabaseTools {

    static func debugSchema(database: DatabaseManager) {
        print("events has locationId: \(database.columnExists(table: "events", column: "locationId"))")
        print("locations rows: \(countRows("locations", database: database))")
    }

    static func debugCounts(database: DatabaseManager) {
        print("photos rows: \(countRows("photos", database: database))")
        print("active photos rows: \(countRows("photos WHERE isDeleted = 0", database: database))")
        print("deleted photos rows: \(countRows("photos WHERE isDeleted = 1", database: database))")
        print("events rows: \(countRows("events", database: database))")
        print("people rows: \(countRows("people", database: database))")
        print("photo_people rows: \(countRows("photo_people", database: database))")
        print("event_people rows: \(countRows("event_people", database: database))")
        print("events with city rows: \(countRows("events WHERE city IS NOT NULL AND city != ''", database: database))")
    }

    static func debugEventPipeline(database: DatabaseManager) {
        print("---- EVENT PIPELINE DEBUG ----")
        print("events rows: \(countRows("events", database: database))")
        print("photo_events rows: \(countRows("photo_events", database: database))")
        print("active photos rows: \(countRows("photos WHERE isDeleted = 0", database: database))")
        print(
            "photos with location rows: \(countRows("photos WHERE latitude IS NOT NULL AND longitude IS NOT NULL AND isDeleted = 0", database: database))"
        )
        print(
            "clusterable photos rows: \(countRows("photos WHERE latitude IS NOT NULL AND longitude IS NOT NULL AND isScreenshot = 0 AND isDeleted = 0", database: database))"
        )
        print(
            "events linked to active photos: \(countRows("photo_events pe JOIN photos p ON pe.photoId = p.id WHERE p.isDeleted = 0", database: database))"
        )
        print("------------------------------")
    }

    static func debugPrintFirstEvents(database: DatabaseManager) {
        database.queue.sync {
            guard let db = database.connection else { return }

            let sql = """
            SELECT eventId, name, city, state, placeName
            FROM events
            ORDER BY eventId ASC
            LIMIT 20;
            """

            var statement: OpaquePointer?

            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                while sqlite3_step(statement) == SQLITE_ROW {
                    let eventId = Int(sqlite3_column_int(statement, 0))
                    let name = String(cString: sqlite3_column_text(statement, 1))

                    let city =
                        sqlite3_column_type(statement, 2) == SQLITE_NULL
                        ? "nil"
                        : String(cString: sqlite3_column_text(statement, 2))

                    let state =
                        sqlite3_column_type(statement, 3) == SQLITE_NULL
                        ? "nil"
                        : String(cString: sqlite3_column_text(statement, 3))

                    let place =
                        sqlite3_column_type(statement, 4) == SQLITE_NULL
                        ? "nil"
                        : String(cString: sqlite3_column_text(statement, 4))

                    print("DB EVENT \(eventId): \(name) | \(city), \(state) | \(place)")
                }
            } else {
                print("debugPrintFirstEvents failed: \(String(cString: sqlite3_errmsg(db)))")
            }

            sqlite3_finalize(statement)
        }
    }

    static func debugPrintAlbumNames() {
        print("---- Regular Albums ----")
        debugPrintAlbums(type: .album)

        print("---- Smart Albums ----")
        debugPrintAlbums(type: .smartAlbum)
    }

    private static func debugPrintAlbums(type: PHAssetCollectionType) {
        let collections = PHAssetCollection.fetchAssetCollections(
            with: type,
            subtype: .any,
            options: nil
        )

        collections.enumerateObjects { collection, _, _ in
            print("Album: \(collection.localizedTitle ?? "nil")")
        }
    }

    private static func countRows(_ tableOrQuery: String, database: DatabaseManager) -> Int {
        database.queue.sync {
            guard let db = database.connection else { return 0 }

            let sql = "SELECT COUNT(*) FROM \(tableOrQuery);"
            var statement: OpaquePointer?
            var count = 0

            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                if sqlite3_step(statement) == SQLITE_ROW {
                    count = Int(sqlite3_column_int(statement, 0))
                }
            } else {
                print("Count failed for \(tableOrQuery): \(String(cString: sqlite3_errmsg(db)))")
            }

            sqlite3_finalize(statement)
            return count
        }
    }
}
