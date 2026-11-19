import Foundation

enum PhotoPreviewLocationFormatting {
    static let noGPSData = "NO GPS data"

    /// True when nickname, place, or city/state can be shown (not GPS-only).
    static func hasPlaceText(
        nickname: String?,
        placeName: String?,
        city: String?,
        state: String?
    ) -> Bool {
        trimmed(nickname) != nil
            || trimmed(placeName) != nil
            || cityStateLine(city: city, state: state) != nil
    }

    /// Nickname → place name → city/state → GPS → "NO GPS data".
    static func line(
        nickname: String?,
        placeName: String?,
        city: String?,
        state: String?,
        latitude: Double?,
        longitude: Double?
    ) -> String {
        if let nickname = trimmed(nickname) {
            return nickname
        }
        if let placeName = trimmed(placeName) {
            return placeName
        }
        if let cityState = cityStateLine(city: city, state: state) {
            return cityState
        }
        if let latitude, let longitude {
            return String(format: "%.4f, %.4f", latitude, longitude)
        }
        return noGPSData
    }

    static func dateTimeLine(from creationDate: String) -> String {
        guard let date = EventDateParser.parseDate(creationDate) else {
            return "Unknown date"
        }
        return dateTimeFormatter.string(from: date)
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func cityStateLine(city: String?, state: String?) -> String? {
        switch (trimmed(city), trimmed(state)) {
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

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMMM d, yyyy h:mm a"
        return formatter
    }()
}
