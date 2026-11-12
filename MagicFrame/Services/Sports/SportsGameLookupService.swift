import Foundation

enum SportsGameLookupError: LocalizedError {
    case missingEventDate
    case noStadiumMatch
    case noGamesFound
    case network(String)

    var errorDescription: String? {
        switch self {
        case .missingEventDate:
            return "This event needs a date before looking up a score."
        case .noStadiumMatch:
            return "No known stadium matched this event’s location."
        case .noGamesFound:
            return "No matching games found for that date and stadium."
        case .network(let message):
            return message
        }
    }
}

/// Looks up ESPN scoreboards for leagues hosted at matched stadiums.
final class SportsGameLookupService: @unchecked Sendable {

    private let stadiums: StadiumRepository
    private let session: URLSession

    init(stadiums: StadiumRepository, session: URLSession = .shared) {
        self.stadiums = stadiums
        self.session = session
    }

    func lookupCandidates(
        eventDateISO: String,
        placeName: String?,
        city: String?,
        state: String?,
        latitude: Double?,
        longitude: Double?
    ) async throws -> (stadiums: [Stadium], candidates: [SportsGameCandidate]) {
        guard let dayKey = Self.dayKey(fromISO: eventDateISO) else {
            throw SportsGameLookupError.missingEventDate
        }

        let matched = stadiums.matchStadiums(
            placeName: placeName,
            city: city,
            state: state,
            latitude: latitude,
            longitude: longitude
        )
        guard !matched.isEmpty else {
            throw SportsGameLookupError.noStadiumMatch
        }

        let leagues = Array(Set(matched.flatMap(\.leagues)))

        // Prefer the event's calendar day. Only widen to ±1 day when that day has no match
        // (timezone / late-game edge cases) so a known park doesn't surface three home games.
        let exactDay = try await collectCandidates(
            leagues: leagues,
            dayKeys: [dayKey],
            stadiums: matched
        )
        let sorted: [SportsGameCandidate]
        if !exactDay.isEmpty {
            sorted = exactDay
        } else {
            let neighbors = Self.neighborDayKeys(around: dayKey).filter { $0 != dayKey }
            sorted = try await collectCandidates(
                leagues: leagues,
                dayKeys: neighbors,
                stadiums: matched
            )
        }

        guard !sorted.isEmpty else {
            throw SportsGameLookupError.noGamesFound
        }
        return (matched, sorted)
    }

    private func collectCandidates(
        leagues: [SportsLeague],
        dayKeys: [String],
        stadiums: [Stadium]
    ) async throws -> [SportsGameCandidate] {
        var candidates: [SportsGameCandidate] = []
        for league in leagues {
            for key in dayKeys {
                let games = try await fetchScoreboard(league: league, dayKey: key)
                for game in games {
                    if let ranked = rank(game: game, against: stadiums, league: league) {
                        candidates.append(ranked)
                    }
                }
            }
        }

        var bestById: [String: SportsGameCandidate] = [:]
        for candidate in candidates {
            if let existing = bestById[candidate.id] {
                if candidate.matchScore > existing.matchScore {
                    bestById[candidate.id] = candidate
                }
            } else {
                bestById[candidate.id] = candidate
            }
        }

        return bestById.values.sorted {
            if $0.matchScore != $1.matchScore { return $0.matchScore > $1.matchScore }
            return $0.summaryLine < $1.summaryLine
        }
    }

    // MARK: - ESPN

    private struct ESPNScoreboard: Decodable {
        let events: [ESPNEvent]?
    }

    private struct ESPNEvent: Decodable {
        let id: String
        let date: String?
        let competitions: [ESPNCompetition]?
    }

    private struct ESPNCompetition: Decodable {
        let venue: ESPNVenue?
        let competitors: [ESPNCompetitor]?
        let status: ESPNStatus?
    }

    private struct ESPNVenue: Decodable {
        let fullName: String?
        let address: ESPNAddress?
    }

    private struct ESPNAddress: Decodable {
        let city: String?
        let state: String?
    }

    private struct ESPNCompetitor: Decodable {
        let homeAway: String?
        let score: String?
        let team: ESPNTeam?
        let winner: Bool?
    }

    private struct ESPNTeam: Decodable {
        let id: String?
        let displayName: String?
        let shortDisplayName: String?
        let name: String?
        let location: String?
        let abbreviation: String?
    }

    private struct ESPNStatus: Decodable {
        let type: ESPNStatusType?
    }

    private struct ESPNStatusType: Decodable {
        let description: String?
        let detail: String?
        let completed: Bool?
    }

    private func fetchScoreboard(
        league: SportsLeague,
        dayKey: String
    ) async throws -> [ESPNEvent] {
        let urlString =
            "https://site.api.espn.com/apis/site/v2/sports/"
            + "\(league.espnSportPath)/\(league.espnLeaguePath)/scoreboard"
            + "?dates=\(dayKey)&limit=500"
        guard let url = URL(string: urlString) else {
            throw SportsGameLookupError.network("Invalid ESPN URL.")
        }

        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw SportsGameLookupError.network("ESPN returned HTTP \(http.statusCode).")
            }
            let decoded = try JSONDecoder().decode(ESPNScoreboard.self, from: data)
            return decoded.events ?? []
        } catch let error as SportsGameLookupError {
            throw error
        } catch {
            throw SportsGameLookupError.network(error.localizedDescription)
        }
    }

    private func rank(
        game: ESPNEvent,
        against stadiums: [Stadium],
        league: SportsLeague
    ) -> SportsGameCandidate? {
        guard let competition = game.competitions?.first else { return nil }
        let competitors = competition.competitors ?? []
        let home = competitors.first { $0.homeAway == "home" }
        let away = competitors.first { $0.homeAway == "away" }
        let homeName = displayTeamName(home?.team, league: league)
        let awayName = displayTeamName(away?.team, league: league)

        let venueName = competition.venue?.fullName
        let venueCity = competition.venue?.address?.city
        let venueState = competition.venue?.address?.state

        var bestStadium: Stadium?
        var bestScore = 0.0

        for stadium in stadiums where stadium.leagues.contains(league) {
            var score = 0.0
            let stadiumNames = ([stadium.name] + stadium.aliases).map(Self.normalize)
            let venueNorm = Self.normalize(venueName)

            if !venueNorm.isEmpty {
                for name in stadiumNames where !name.isEmpty {
                    if venueNorm == name {
                        score += 100
                    } else if venueNorm.contains(name) || name.contains(venueNorm) {
                        score += 70
                    }
                }
            }

            if let city = venueCity.map(Self.normalize),
               let stadiumCity = stadium.city.map(Self.normalize),
               !city.isEmpty, city == stadiumCity {
                score += 15
            }

            let leagueTeams = stadium.teams.filter { $0.league == league }
            for team in leagueTeams {
                if Self.teamMatches(espn: home, catalog: team) {
                    score += team.isPrimaryHome ? 50 : 40
                }
                if Self.teamMatches(espn: away, catalog: team) {
                    score += 15
                }
            }

            if score > bestScore {
                bestScore = score
                bestStadium = stadium
            }
        }

        // Require a meaningful venue or home-team signal.
        guard bestScore >= 40, let stadium = bestStadium else { return nil }

        return SportsGameCandidate(
            id: "\(league.rawValue):\(game.id)",
            league: league,
            espnEventId: game.id,
            gameDateISO: game.date,
            homeTeam: homeName,
            awayTeam: awayName,
            homeScore: Int(home?.score ?? ""),
            awayScore: Int(away?.score ?? ""),
            venueName: venueName,
            venueCity: venueCity,
            venueState: venueState,
            stadiumId: stadium.stadiumId,
            matchScore: bestScore,
            statusDetail: competition.status?.type?.detail
                ?? competition.status?.type?.description
        )
    }

    private func displayTeamName(_ team: ESPNTeam?, league: SportsLeague) -> String {
        if league == .collegeFootball {
            return SportsTeamNaming.collegeName(
                location: team?.location,
                displayName: team?.displayName,
                shortDisplayName: team?.shortDisplayName,
                name: team?.name
            )
        }
        return team?.displayName
            ?? team?.shortDisplayName
            ?? team?.name
            ?? team?.location
            ?? "Team"
    }

    private static func teamMatches(espn: ESPNCompetitor?, catalog: StadiumTeam) -> Bool {
        guard let team = espn?.team else { return false }
        let needles = [
            catalog.teamName,
            catalog.displayName,
            catalog.teamAbbreviation,
        ]
        .compactMap { $0 }
        .map(normalize)
        .filter { !$0.isEmpty }

        let haystacks = [
            team.displayName,
            team.shortDisplayName,
            team.name,
            team.location,
            team.abbreviation,
        ]
        .compactMap { $0 }
        .map(normalize)
        .filter { !$0.isEmpty }

        for needle in needles {
            for hay in haystacks {
                if hay == needle || hay.contains(needle) || needle.contains(hay) {
                    return true
                }
            }
        }
        return false
    }

    private static func normalize(_ value: String?) -> String {
        (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
    }

    /// `YYYYMMDD` from an event ISO start date.
    static func dayKey(fromISO iso: String) -> String? {
        let trimmed = iso.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 10 else { return nil }
        let ymd = String(trimmed.prefix(10))
        let parts = ymd.split(separator: "-")
        guard parts.count == 3,
              parts[0].count == 4,
              parts[1].count == 2,
              parts[2].count == 2 else {
            return nil
        }
        return "\(parts[0])\(parts[1])\(parts[2])"
    }

    static func neighborDayKeys(around dayKey: String) -> [String] {
        guard dayKey.count == 8,
              let date = compactDayFormatter.date(from: dayKey) else {
            return [dayKey]
        }
        let cal = Calendar(identifier: .gregorian)
        let previous = cal.date(byAdding: .day, value: -1, to: date).map {
            compactDayFormatter.string(from: $0)
        }
        let next = cal.date(byAdding: .day, value: 1, to: date).map {
            compactDayFormatter.string(from: $0)
        }
        return [previous, dayKey, next].compactMap { $0 }
    }

    private static let compactDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }()
}
