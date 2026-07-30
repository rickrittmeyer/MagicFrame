import Foundation

struct ManagedLocation: Identifiable {
    let locationId: Int
    let nickname: String?
    let placeName: String?
    let city: String?
    let state: String?
    let locationType: String?
    let isFavorite: Bool
    let eventCount: Int
    let latitude: Double?
    let longitude: Double?
    let isCurrentHome: Bool
    let homeStartDate: String?
    let homeEndDate: String?

    var id: Int { locationId }

    var homeRole: LocationHomeRole {
        if isCurrentHome {
            return .current
        }
        if homeStartDate != nil, homeEndDate != nil {
            return .former
        }
        return .none
    }

    var isFormerHome: Bool {
        homeRole == .former
    }

    var homeOccupancySummary: String? {
        guard let start = EventDateParser.parseDate(homeStartDate ?? ""),
              let end = EventDateParser.parseDate(homeEndDate ?? "") else {
            if isCurrentHome,
               let start = EventDateParser.parseDate(homeStartDate ?? "") {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .none
                return "Since \(formatter.string(from: start))"
            }
            return nil
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return "\(formatter.string(from: start)) – \(formatter.string(from: end))"
    }

    var displayTitle: String {
        if isCurrentHome {
            if let nickname, !nickname.isEmpty {
                return nickname
            }
            return "Current Home"
        }

        if isFormerHome {
            if let nickname, !nickname.isEmpty {
                return nickname
            }
            return "Former Home"
        }

        if let nickname, !nickname.isEmpty {
            return nickname
        }
        if let placeName, !placeName.isEmpty {
            return placeName
        }
        if let cityState = cityStateLine {
            return cityState
        }
        if let latitude, let longitude {
            return String(format: "%.4f, %.4f", latitude, longitude)
        }
        return "Location #\(locationId)"
    }

    var cityStateLine: String? {
        switch (city, state) {
        case let (city?, state?):
            return "\(city), \(state)"
        case let (city?, nil):
            return city
        case let (nil, state?):
            return state
        default:
            return nil
        }
    }

    /// Landmark or place name with city and state on one line for compact detail headers.
    var addressDisplayLine: String? {
        let trimmedPlace = placeName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasPlace = trimmedPlace.map { !$0.isEmpty } ?? false

        if hasPlace, let cityState = cityStateLine {
            return "\(trimmedPlace!), \(cityState)"
        }
        if hasPlace {
            return trimmedPlace
        }
        return cityStateLine
    }

    /// Subtitle under the main title in list/detail when a user nickname or geocoded place is shown.
    var detailSubtitle: String? {
        if let nickname, !nickname.isEmpty {
            if let placeName, !placeName.isEmpty {
                return placeName
            }
            return cityStateLine
        }

        if let placeName, !placeName.isEmpty {
            return cityStateLine
        }

        return nil
    }

    var cityStateSubtitle: String? {
        detailSubtitle
    }

    var mapCoordinate: (latitude: Double, longitude: Double)? {
        guard let latitude, let longitude else { return nil }
        return (latitude, longitude)
    }
}
