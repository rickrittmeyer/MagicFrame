import Foundation
import SQLite3

final class StadiumRepository {

    private let database: DatabaseManager

    init(database: DatabaseManager) {
        self.database = database
    }

    private var db: OpaquePointer? { database.connection }

    private func sync<T>(_ work: () throws -> T) rethrows -> T {
        if database.isOnQueue {
            return try work()
        }
        return try database.sync(work)
    }

    func fetchAllStadiums() -> [Stadium] {
        sync { fetchAllStadiumsUnsafe() }
    }

    func fetchStadium(stadiumId: Int) -> Stadium? {
        sync { fetchStadiumUnsafe(stadiumId: stadiumId) }
    }

    func matchStadiums(
        placeName: String?,
        city: String?,
        state: String?,
        latitude: Double?,
        longitude: Double?
    ) -> [Stadium] {
        sync {
            matchStadiumsUnsafe(
                placeName: placeName,
                city: city,
                state: state,
                latitude: latitude,
                longitude: longitude
            )
        }
    }

    func fetchGameResult(eventId: Int) -> EventGameResult? {
        sync { fetchGameResultUnsafe(eventId: eventId) }
    }

    func fetchGameResults(eventIds: [Int]) -> [Int: EventGameResult] {
        sync { fetchGameResultsUnsafe(eventIds: eventIds) }
    }

    func saveGameResult(_ result: EventGameResult) {
        sync { saveGameResultUnsafe(result) }
    }

    func clearGameResult(eventId: Int) {
        sync { clearGameResultUnsafe(eventId: eventId) }
    }

    @discardableResult
    func upsertStadium(
        stadiumId: Int?,
        name: String,
        city: String?,
        state: String?,
        latitude: Double?,
        longitude: Double?
    ) -> Int? {
        sync {
            upsertStadiumUnsafe(
                stadiumId: stadiumId,
                name: name,
                city: city,
                state: state,
                latitude: latitude,
                longitude: longitude
            )
        }
    }

    func deleteStadium(stadiumId: Int) {
        sync { deleteStadiumUnsafe(stadiumId: stadiumId) }
    }

    func addStadiumAlias(stadiumId: Int, alias: String) {
        sync { addStadiumAliasUnsafe(stadiumId: stadiumId, alias: alias) }
    }

    func deleteStadiumAlias(stadiumId: Int, alias: String) {
        sync { deleteStadiumAliasUnsafe(stadiumId: stadiumId, alias: alias) }
    }

    @discardableResult
    func upsertStadiumTeam(
        stadiumTeamId: Int?,
        stadiumId: Int,
        league: SportsLeague,
        teamName: String,
        displayName: String?,
        teamAbbreviation: String?,
        isPrimaryHome: Bool
    ) -> Int? {
        sync {
            upsertStadiumTeamUnsafe(
                stadiumTeamId: stadiumTeamId,
                stadiumId: stadiumId,
                league: league,
                teamName: teamName,
                displayName: displayName,
                teamAbbreviation: teamAbbreviation,
                isPrimaryHome: isPrimaryHome
            )
        }
    }

    func deleteStadiumTeam(stadiumTeamId: Int) {
        sync { deleteStadiumTeamUnsafe(stadiumTeamId: stadiumTeamId) }
    }

    // MARK: - Unsafe

    private func fetchAllStadiumsUnsafe() -> [Stadium] {
        let sql = """
        SELECT stadiumId, name, city, state, latitude, longitude
        FROM stadiums
        ORDER BY name COLLATE NOCASE;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        var rows: [(Int, String, String?, String?, Double?, Double?)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(
                (
                    Int(sqlite3_column_int(statement, 0)),
                    String(cString: sqlite3_column_text(statement, 1)),
                    optionalString(statement, 2),
                    optionalString(statement, 3),
                    optionalDouble(statement, 4),
                    optionalDouble(statement, 5)
                )
            )
        }
        sqlite3_finalize(statement)

        return rows.map { row in
            Stadium(
                stadiumId: row.0,
                name: row.1,
                city: row.2,
                state: row.3,
                latitude: row.4,
                longitude: row.5,
                aliases: fetchAliasesUnsafe(stadiumId: row.0),
                teams: fetchTeamsUnsafe(stadiumId: row.0)
            )
        }
    }

    private func fetchStadiumUnsafe(stadiumId: Int) -> Stadium? {
        fetchAllStadiumsUnsafe().first { $0.stadiumId == stadiumId }
    }

    private func fetchAliasesUnsafe(stadiumId: Int) -> [String] {
        let sql = """
        SELECT alias FROM stadium_aliases
        WHERE stadiumId = ?
        ORDER BY alias COLLATE NOCASE;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_int(statement, 1, Int32(stadiumId))
        var aliases: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            aliases.append(String(cString: sqlite3_column_text(statement, 0)))
        }
        sqlite3_finalize(statement)
        return aliases
    }

    private func fetchTeamsUnsafe(stadiumId: Int) -> [StadiumTeam] {
        let sql = """
        SELECT stadiumTeamId, stadiumId, league, teamName, displayName,
               teamAbbreviation, isPrimaryHome
        FROM stadium_teams
        WHERE stadiumId = ?
        ORDER BY league COLLATE NOCASE, teamName COLLATE NOCASE;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_int(statement, 1, Int32(stadiumId))
        var teams: [StadiumTeam] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let leagueRaw = String(cString: sqlite3_column_text(statement, 2))
            guard let league = SportsLeague(rawValue: leagueRaw) else { continue }
            teams.append(
                StadiumTeam(
                    stadiumTeamId: Int(sqlite3_column_int(statement, 0)),
                    stadiumId: Int(sqlite3_column_int(statement, 1)),
                    league: league,
                    teamName: String(cString: sqlite3_column_text(statement, 3)),
                    displayName: optionalString(statement, 4),
                    teamAbbreviation: optionalString(statement, 5),
                    isPrimaryHome: sqlite3_column_int(statement, 6) != 0
                )
            )
        }
        sqlite3_finalize(statement)
        return teams
    }

    private func matchStadiumsUnsafe(
        placeName: String?,
        city: String?,
        state: String?,
        latitude: Double?,
        longitude: Double?
    ) -> [Stadium] {
        let all = fetchAllStadiumsUnsafe()
        guard !all.isEmpty else { return [] }

        let place = normalized(placeName)
        let cityNorm = normalized(city)
        let stateNorm = normalized(state)

        struct Scored { let stadium: Stadium; let score: Double }
        var scored: [Scored] = []

        for stadium in all {
            var score = 0.0
            let names = ([stadium.name] + stadium.aliases).map(normalized).filter { !$0.isEmpty }

            if !place.isEmpty {
                for name in names {
                    if place == name {
                        score += 100
                    } else if place.contains(name) || name.contains(place) {
                        score += 70
                    }
                }
            }

            if !cityNorm.isEmpty,
               let stadiumCity = stadium.city.map(normalized),
               stadiumCity == cityNorm {
                score += 20
            }
            if !stateNorm.isEmpty,
               let stadiumState = stadium.state.map(normalized),
               stadiumState == stateNorm {
                score += 10
            }

            if let latitude, let longitude,
               let sLat = stadium.latitude, let sLon = stadium.longitude {
                let meters = haversineMeters(
                    lat1: latitude,
                    lon1: longitude,
                    lat2: sLat,
                    lon2: sLon
                )
                if meters < 250 {
                    score += 40
                } else if meters < 800 {
                    score += 25
                } else if meters < 2_500 {
                    score += 10
                }
            }

            if score > 0 {
                scored.append(Scored(stadium: stadium, score: score))
            }
        }

        return scored
            .sorted { $0.score > $1.score }
            .map(\.stadium)
    }

    private func fetchGameResultUnsafe(eventId: Int) -> EventGameResult? {
        fetchGameResultsUnsafe(eventIds: [eventId])[eventId]
    }

    private func fetchGameResultsUnsafe(eventIds: [Int]) -> [Int: EventGameResult] {
        let uniqueIds = Array(Set(eventIds.filter { $0 > 0 }))
        guard !uniqueIds.isEmpty else { return [:] }

        var results: [Int: EventGameResult] = [:]
        let chunkSize = 400
        for chunkStart in stride(from: 0, to: uniqueIds.count, by: chunkSize) {
            let chunkEnd = min(chunkStart + chunkSize, uniqueIds.count)
            let chunk = Array(uniqueIds[chunkStart..<chunkEnd])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            let sql = """
            SELECT eventId, stadiumId, league, espnEventId, homeTeam, awayTeam,
                   homeScore, awayScore, gameDateISO, venueName, summaryLine, source, updatedAt
            FROM event_game_results
            WHERE eventId IN (\(placeholders));
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { continue }
            for (index, eventId) in chunk.enumerated() {
                sqlite3_bind_int(statement, Int32(index + 1), Int32(eventId))
            }
            while sqlite3_step(statement) == SQLITE_ROW {
                let leagueRaw = String(cString: sqlite3_column_text(statement, 2))
                guard let league = SportsLeague(rawValue: leagueRaw) else { continue }
                let eventId = Int(sqlite3_column_int(statement, 0))
                results[eventId] = EventGameResult(
                    eventId: eventId,
                    stadiumId: optionalInt(statement, 1),
                    league: league,
                    espnEventId: optionalString(statement, 3),
                    homeTeam: String(cString: sqlite3_column_text(statement, 4)),
                    awayTeam: String(cString: sqlite3_column_text(statement, 5)),
                    homeScore: optionalInt(statement, 6),
                    awayScore: optionalInt(statement, 7),
                    gameDateISO: optionalString(statement, 8),
                    venueName: optionalString(statement, 9),
                    summaryLine: String(cString: sqlite3_column_text(statement, 10)),
                    source: String(cString: sqlite3_column_text(statement, 11)),
                    updatedAt: String(cString: sqlite3_column_text(statement, 12))
                )
            }
            sqlite3_finalize(statement)
        }
        return results
    }

    private func saveGameResultUnsafe(_ result: EventGameResult) {
        let sql = """
        INSERT INTO event_game_results (
            eventId, stadiumId, league, espnEventId, homeTeam, awayTeam,
            homeScore, awayScore, gameDateISO, venueName, summaryLine, source, updatedAt
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(eventId) DO UPDATE SET
            stadiumId = excluded.stadiumId,
            league = excluded.league,
            espnEventId = excluded.espnEventId,
            homeTeam = excluded.homeTeam,
            awayTeam = excluded.awayTeam,
            homeScore = excluded.homeScore,
            awayScore = excluded.awayScore,
            gameDateISO = excluded.gameDateISO,
            venueName = excluded.venueName,
            summaryLine = excluded.summaryLine,
            source = excluded.source,
            updatedAt = excluded.updatedAt;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(result.eventId))
        bindOptionalInt(statement, 2, result.stadiumId)
        sqlite3_bind_text(statement, 3, (result.league.rawValue as NSString).utf8String, -1, nil)
        bindOptionalText(statement, 4, result.espnEventId)
        sqlite3_bind_text(statement, 5, (result.homeTeam as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 6, (result.awayTeam as NSString).utf8String, -1, nil)
        bindOptionalInt(statement, 7, result.homeScore)
        bindOptionalInt(statement, 8, result.awayScore)
        bindOptionalText(statement, 9, result.gameDateISO)
        bindOptionalText(statement, 10, result.venueName)
        sqlite3_bind_text(statement, 11, (result.summaryLine as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 12, (result.source as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 13, (result.updatedAt as NSString).utf8String, -1, nil)
        sqlite3_step(statement)
    }

    private func clearGameResultUnsafe(eventId: Int) {
        let sql = "DELETE FROM event_game_results WHERE eventId = ?;"
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(eventId))
            sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }

    private func upsertStadiumUnsafe(
        stadiumId: Int?,
        name: String,
        city: String?,
        state: String?,
        latitude: Double?,
        longitude: Double?
    ) -> Int? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }

        let trimmedCity = city?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedState = state?.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = ISO8601DateFormatter().string(from: Date())

        if let stadiumId, stadiumId > 0 {
            let sql = """
            UPDATE stadiums
            SET name = ?, city = ?, state = ?, latitude = ?, longitude = ?
            WHERE stadiumId = ?;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, (trimmedName as NSString).utf8String, -1, nil)
            bindOptionalText(statement, 2, trimmedCity)
            bindOptionalText(statement, 3, trimmedState)
            bindOptionalDouble(statement, 4, latitude)
            bindOptionalDouble(statement, 5, longitude)
            sqlite3_bind_int(statement, 6, Int32(stadiumId))
            guard sqlite3_step(statement) == SQLITE_DONE else { return nil }
            return stadiumId
        }

        let sql = """
        INSERT INTO stadiums (name, city, state, latitude, longitude, createdAt)
        VALUES (?, ?, ?, ?, ?, ?);
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (trimmedName as NSString).utf8String, -1, nil)
        bindOptionalText(statement, 2, trimmedCity)
        bindOptionalText(statement, 3, trimmedState)
        bindOptionalDouble(statement, 4, latitude)
        bindOptionalDouble(statement, 5, longitude)
        sqlite3_bind_text(statement, 6, (now as NSString).utf8String, -1, nil)
        guard sqlite3_step(statement) == SQLITE_DONE else { return nil }
        return Int(sqlite3_last_insert_rowid(db))
    }

    private func deleteStadiumUnsafe(stadiumId: Int) {
        guard stadiumId > 0 else { return }

        let clearResults = "UPDATE event_game_results SET stadiumId = NULL WHERE stadiumId = ?;"
        var clearStatement: OpaquePointer?
        if sqlite3_prepare_v2(db, clearResults, -1, &clearStatement, nil) == SQLITE_OK {
            sqlite3_bind_int(clearStatement, 1, Int32(stadiumId))
            sqlite3_step(clearStatement)
        }
        sqlite3_finalize(clearStatement)

        let deleteAliases = "DELETE FROM stadium_aliases WHERE stadiumId = ?;"
        var aliasStatement: OpaquePointer?
        if sqlite3_prepare_v2(db, deleteAliases, -1, &aliasStatement, nil) == SQLITE_OK {
            sqlite3_bind_int(aliasStatement, 1, Int32(stadiumId))
            sqlite3_step(aliasStatement)
        }
        sqlite3_finalize(aliasStatement)

        let deleteTeams = "DELETE FROM stadium_teams WHERE stadiumId = ?;"
        var teamStatement: OpaquePointer?
        if sqlite3_prepare_v2(db, deleteTeams, -1, &teamStatement, nil) == SQLITE_OK {
            sqlite3_bind_int(teamStatement, 1, Int32(stadiumId))
            sqlite3_step(teamStatement)
        }
        sqlite3_finalize(teamStatement)

        let deleteStadium = "DELETE FROM stadiums WHERE stadiumId = ?;"
        var stadiumStatement: OpaquePointer?
        if sqlite3_prepare_v2(db, deleteStadium, -1, &stadiumStatement, nil) == SQLITE_OK {
            sqlite3_bind_int(stadiumStatement, 1, Int32(stadiumId))
            sqlite3_step(stadiumStatement)
        }
        sqlite3_finalize(stadiumStatement)
    }

    private func addStadiumAliasUnsafe(stadiumId: Int, alias: String) {
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard stadiumId > 0, !trimmed.isEmpty else { return }

        let sql = """
        INSERT OR IGNORE INTO stadium_aliases (stadiumId, alias)
        VALUES (?, ?);
        """
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(stadiumId))
            sqlite3_bind_text(statement, 2, (trimmed as NSString).utf8String, -1, nil)
            sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }

    private func deleteStadiumAliasUnsafe(stadiumId: Int, alias: String) {
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard stadiumId > 0, !trimmed.isEmpty else { return }

        let sql = """
        DELETE FROM stadium_aliases
        WHERE stadiumId = ? AND alias = ?;
        """
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(stadiumId))
            sqlite3_bind_text(statement, 2, (trimmed as NSString).utf8String, -1, nil)
            sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }

    private func upsertStadiumTeamUnsafe(
        stadiumTeamId: Int?,
        stadiumId: Int,
        league: SportsLeague,
        teamName: String,
        displayName: String?,
        teamAbbreviation: String?,
        isPrimaryHome: Bool
    ) -> Int? {
        let trimmedName = teamName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard stadiumId > 0, !trimmedName.isEmpty else { return nil }

        let trimmedDisplay = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAbbrev = teamAbbreviation?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let stadiumTeamId, stadiumTeamId > 0 {
            let sql = """
            UPDATE stadium_teams
            SET league = ?, teamName = ?, displayName = ?, teamAbbreviation = ?, isPrimaryHome = ?
            WHERE stadiumTeamId = ? AND stadiumId = ?;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, (league.rawValue as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 2, (trimmedName as NSString).utf8String, -1, nil)
            bindOptionalText(statement, 3, trimmedDisplay)
            bindOptionalText(statement, 4, trimmedAbbrev)
            sqlite3_bind_int(statement, 5, isPrimaryHome ? 1 : 0)
            sqlite3_bind_int(statement, 6, Int32(stadiumTeamId))
            sqlite3_bind_int(statement, 7, Int32(stadiumId))
            guard sqlite3_step(statement) == SQLITE_DONE else { return nil }
            return stadiumTeamId
        }

        let sql = """
        INSERT INTO stadium_teams (
            stadiumId, league, teamName, displayName, teamAbbreviation, isPrimaryHome
        ) VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(stadiumId, league, teamName) DO UPDATE SET
            displayName = excluded.displayName,
            teamAbbreviation = excluded.teamAbbreviation,
            isPrimaryHome = excluded.isPrimaryHome;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(stadiumId))
        sqlite3_bind_text(statement, 2, (league.rawValue as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 3, (trimmedName as NSString).utf8String, -1, nil)
        bindOptionalText(statement, 4, trimmedDisplay)
        bindOptionalText(statement, 5, trimmedAbbrev)
        sqlite3_bind_int(statement, 6, isPrimaryHome ? 1 : 0)
        guard sqlite3_step(statement) == SQLITE_DONE else { return nil }

        let selectSQL = """
        SELECT stadiumTeamId
        FROM stadium_teams
        WHERE stadiumId = ? AND league = ? AND teamName = ?
        LIMIT 1;
        """
        var selectStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db, selectSQL, -1, &selectStatement, nil) == SQLITE_OK else {
            return Int(sqlite3_last_insert_rowid(db))
        }
        defer { sqlite3_finalize(selectStatement) }
        sqlite3_bind_int(selectStatement, 1, Int32(stadiumId))
        sqlite3_bind_text(selectStatement, 2, (league.rawValue as NSString).utf8String, -1, nil)
        sqlite3_bind_text(selectStatement, 3, (trimmedName as NSString).utf8String, -1, nil)
        if sqlite3_step(selectStatement) == SQLITE_ROW {
            return Int(sqlite3_column_int(selectStatement, 0))
        }
        return Int(sqlite3_last_insert_rowid(db))
    }

    private func deleteStadiumTeamUnsafe(stadiumTeamId: Int) {
        guard stadiumTeamId > 0 else { return }
        let sql = "DELETE FROM stadium_teams WHERE stadiumTeamId = ?;"
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(stadiumTeamId))
            sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }

    // MARK: - Helpers

    private func normalized(_ value: String?) -> String {
        (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
    }

    private func haversineMeters(
        lat1: Double,
        lon1: Double,
        lat2: Double,
        lon2: Double
    ) -> Double {
        let r = 6_371_000.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180)
            * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(a)))
    }

    private func optionalString(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let cString = sqlite3_column_text(statement, column) else {
            return nil
        }
        return String(cString: cString)
    }

    private func optionalInt(_ statement: OpaquePointer?, _ column: Int32) -> Int? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int(statement, column))
    }

    private func optionalDouble(_ statement: OpaquePointer?, _ column: Int32) -> Double? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(statement, column)
    }

    private func bindOptionalInt(_ statement: OpaquePointer?, _ index: Int32, _ value: Int?) {
        if let value {
            sqlite3_bind_int(statement, index, Int32(value))
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func bindOptionalText(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value, !value.isEmpty {
            sqlite3_bind_text(statement, index, (value as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func bindOptionalDouble(_ statement: OpaquePointer?, _ index: Int32, _ value: Double?) {
        if let value {
            sqlite3_bind_double(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }
}
