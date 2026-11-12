import Foundation

enum SportsLeague: String, Codable, CaseIterable, Sendable, Identifiable {
    case collegeFootball = "college-football"
    case nfl = "nfl"
    case mlb = "mlb"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .collegeFootball: return "College Football"
        case .nfl: return "NFL"
        case .mlb: return "MLB"
        }
    }

    var level: SportsCompetitionLevel {
        switch self {
        case .collegeFootball: return .college
        case .nfl, .mlb: return .pro
        }
    }

    /// ESPN site API path segment after `/sports/`.
    var espnSportPath: String {
        switch self {
        case .collegeFootball, .nfl: return "football"
        case .mlb: return "baseball"
        }
    }

    var espnLeaguePath: String { rawValue }
}

enum SportsCompetitionLevel: String, Codable, Sendable {
    case college
    case pro
}

struct StadiumTeam: Identifiable, Equatable, Sendable {
    let stadiumTeamId: Int?
    let stadiumId: Int
    let league: SportsLeague
    /// Short / ESPN-friendly name used for matching (`Georgia Tech`, `Georgia`).
    let teamName: String
    /// Optional richer label for UI (`Georgia Tech Yellow Jackets`).
    let displayName: String?
    let teamAbbreviation: String?
    let isPrimaryHome: Bool

    var id: Int { stadiumTeamId ?? teamName.hashValue }

    var uiName: String {
        let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? teamName : trimmed
    }
}

struct Stadium: Identifiable, Equatable, Sendable {
    let stadiumId: Int
    let name: String
    let city: String?
    let state: String?
    let latitude: Double?
    let longitude: Double?
    let aliases: [String]
    let teams: [StadiumTeam]

    var id: Int { stadiumId }

    var leagues: [SportsLeague] {
        Array(Set(teams.map(\.league))).sorted { $0.rawValue < $1.rawValue }
    }

    var cityStateLine: String? {
        switch (city, state) {
        case let (city?, state?): return "\(city), \(state)"
        case let (city?, nil): return city
        case let (nil, state?): return state
        default: return nil
        }
    }
}

/// Two-line cover / list scoreboard: away on top, home below, scores right-aligned.
struct GameCoverScoreBoard: Equatable, Sendable {
    let awayTeam: String
    let awayScore: String
    let homeTeam: String
    let homeScore: String

    /// Plain-text fallback (status messages, logs).
    var coverScoreLine: String {
        "\(awayTeam) \(awayScore)\n\(homeTeam) \(homeScore)"
    }

    static func make(
        awayTeam: String,
        homeTeam: String,
        awayScore: Int?,
        homeScore: Int?,
        league: SportsLeague
    ) -> GameCoverScoreBoard {
        GameCoverScoreBoard(
            awayTeam: SportsTeamNaming.displayName(awayTeam, league: league),
            awayScore: awayScore.map(String.init) ?? "—",
            homeTeam: SportsTeamNaming.displayName(homeTeam, league: league),
            homeScore: homeScore.map(String.init) ?? "—"
        )
    }
}

struct SportsGameCandidate: Identifiable, Equatable, Sendable {
    let id: String
    let league: SportsLeague
    let espnEventId: String
    let gameDateISO: String?
    let homeTeam: String
    let awayTeam: String
    let homeScore: Int?
    let awayScore: Int?
    let venueName: String?
    let venueCity: String?
    let venueState: String?
    let stadiumId: Int?
    let matchScore: Double
    let statusDetail: String?

    var summaryLine: String {
        coverScoreLine
    }

    private var displayHomeTeam: String {
        SportsTeamNaming.displayName(homeTeam, league: league)
    }

    private var displayAwayTeam: String {
        SportsTeamNaming.displayName(awayTeam, league: league)
    }

    var coverScoreBoard: GameCoverScoreBoard {
        .make(
            awayTeam: awayTeam,
            homeTeam: homeTeam,
            awayScore: awayScore,
            homeScore: homeScore,
            league: league
        )
    }

    /// Cover / list overlay text: away then home, scores on the right.
    var coverScoreLine: String {
        coverScoreBoard.coverScoreLine
    }

    var suggestedEventName: String {
        "\(displayHomeTeam) vs \(displayAwayTeam)"
    }

    var detailLine: String {
        var parts: [String] = [league.displayName]
        if let venueName, !venueName.isEmpty {
            parts.append(venueName)
        } else if let city = venueCity, let state = venueState {
            parts.append("\(city), \(state)")
        }
        if let statusDetail, !statusDetail.isEmpty {
            parts.append(statusDetail)
        }
        return parts.joined(separator: " · ")
    }
}

struct EventGameResult: Equatable, Sendable {
    let eventId: Int
    let stadiumId: Int?
    let league: SportsLeague
    let espnEventId: String?
    let homeTeam: String
    let awayTeam: String
    let homeScore: Int?
    let awayScore: Int?
    let gameDateISO: String?
    let venueName: String?
    let summaryLine: String
    let source: String
    let updatedAt: String

    private var displayHomeTeam: String {
        SportsTeamNaming.displayName(homeTeam, league: league)
    }

    private var displayAwayTeam: String {
        SportsTeamNaming.displayName(awayTeam, league: league)
    }

    var coverScoreBoard: GameCoverScoreBoard {
        .make(
            awayTeam: awayTeam,
            homeTeam: homeTeam,
            awayScore: awayScore,
            homeScore: homeScore,
            league: league
        )
    }

    /// Cover / list overlay text: away then home, scores on the right.
    var coverScoreLine: String {
        coverScoreBoard.coverScoreLine
    }

    var suggestedEventName: String {
        "\(displayHomeTeam) vs \(displayAwayTeam)"
    }

    /// Alphabetical home/away labels for Team sort in the events list.
    var teamSortKey: String {
        [displayHomeTeam, displayAwayTeam]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .joined(separator: "\t")
    }
}

/// Shortens college football labels to school names (`Georgia Tech Yellow Jackets` → `Georgia Tech`).
enum SportsTeamNaming {
    static func displayName(_ raw: String, league: SportsLeague) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return raw }
        guard league == .collegeFootball else { return trimmed }
        return collegeSchoolName(from: trimmed)
    }

    /// Prefer ESPN `location` (school) when present.
    static func collegeName(
        location: String?,
        displayName: String?,
        shortDisplayName: String?,
        name: String?
    ) -> String {
        let locationName = location?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !locationName.isEmpty {
            return locationName
        }
        let candidates = [displayName, shortDisplayName, name]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let first = candidates.first else { return "Team" }
        return collegeSchoolName(from: first)
    }

    static func collegeSchoolName(from fullName: String) -> String {
        var result = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        for nickname in collegeNicknamesSorted {
            let suffix = " \(nickname)"
            if result.hasSuffix(suffix) || result.lowercased().hasSuffix(suffix.lowercased()) {
                result = String(result.dropLast(suffix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        return result.isEmpty ? fullName : result
    }

    /// Longest first so “Yellow Jackets” wins over “Jackets”.
    private static let collegeNicknamesSorted: [String] = [
        "Fighting Irish",
        "Crimson Tide",
        "Yellow Jackets",
        "Golden Bears",
        "Golden Eagles",
        "Mountain Hawks",
        "Thundering Herd",
        "Rainbow Warriors",
        "Nittany Lions",
        "Demon Deacons",
        "Blue Devils",
        "Wolf Pack",
        "Red Raiders",
        "Mean Green",
        "Horned Frogs",
        "Sun Devils",
        "Seminoles",
        "Sooners",
        "Longhorns",
        "Cornhuskers",
        "Jayhawks",
        "Wildcats",
        "Bulldogs",
        "Tigers",
        "Gators",
        "Volunteers",
        "Commodores",
        "Razorbacks",
        "Gamecocks",
        "Tar Heels",
        "Cavaliers",
        "Hokies",
        "Terrapins",
        "Spartans",
        "Wolverines",
        "Buckeyes",
        "Boilermakers",
        "Hoosiers",
        "Hawkeyes",
        "Badgers",
        "Gophers",
        "Illini",
        "Huskers",
        "Bearcats",
        "Panthers",
        "Eagles",
        "Falcons",
        "Owls",
        "Cougars",
        "Mustangs",
        "Trojans",
        "Bruins",
        "Ducks",
        "Beavers",
        "Utes",
        "Buffaloes",
        "Cowboys",
        "Aggies",
        "Rebels",
        "Cardinals",
        "Orange",
        "Knights",
        "Pirates",
        "Miners",
        "Rockets",
        "Zips",
        "Flames",
        "Rams",
        "Bears",
        "Lions",
        "Huskies",
        "Cyclones",
        "Mountaineers",
        "Midshipmen",
        "Black Knights",
        "Crimson",
        "Wave",
        "Green Wave",
        "Blue Raiders",
        "Golden Hurricane",
        "Shockers",
        "Billikens",
        "Musketeers",
        "Friars",
        "Hoyas",
        "Terriers",
        "Gaels",
        "Jaspers",
        "Peacocks",
        "Explorers",
        "Bonnies",
        "Dukes",
        "Colonials",
        "Privateers",
        "Ragin' Cajuns",
        "Thundering Herd",
    ].sorted { $0.count > $1.count }
}
