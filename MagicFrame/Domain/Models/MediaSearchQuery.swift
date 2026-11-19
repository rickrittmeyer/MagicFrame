import Foundation

/// How criteria rows combine in a media library search.
enum MediaSearchMatchMode: String, CaseIterable, Identifiable, Sendable, Codable {
    case all
    case any

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All (AND)"
        case .any: return "Any (OR)"
        }
    }

    var shortTitle: String {
        switch self {
        case .all: return "AND"
        case .any: return "OR"
        }
    }
}

enum MediaSearchField: String, CaseIterable, Identifiable, Sendable, Codable {
    case filename
    case albumName
    case ocrText
    case visionTag
    case locationNickname
    case locationPlaceName
    case locationCity
    case locationState
    case person
    case eventName
    case eventTag
    case eventTagCategory
    case dateTaken
    case mediaKind
    case favorite
    case onFrame
    case camera
    case hasFaces
    case faceCount

    var id: String { rawValue }

    var title: String {
        switch self {
        case .filename: return "Filename"
        case .albumName: return "Album"
        case .ocrText: return "OCR text"
        case .visionTag: return "Vision tag"
        case .locationNickname: return "Location nickname"
        case .locationPlaceName: return "Place name"
        case .locationCity: return "City"
        case .locationState: return "State"
        case .person: return "Person"
        case .eventName: return "Event name"
        case .eventTag: return "Event tag"
        case .eventTagCategory: return "Event tag category"
        case .dateTaken: return "Date taken"
        case .mediaKind: return "Photo / Video"
        case .favorite: return "Favorite"
        case .onFrame: return "On Frame"
        case .camera: return "Camera"
        case .hasFaces: return "Has faces"
        case .faceCount: return "Face count"
        }
    }

    var allowedOperators: [MediaSearchOperator] {
        switch self {
        case .dateTaken:
            return [.on, .after, .before, .between, .inMonth, .anyYear]
        case .faceCount:
            return [.is, .atLeast]
        case .visionTag, .mediaKind, .favorite, .onFrame, .hasFaces, .eventTagCategory:
            return [.is]
        case .person:
            return [.contains, .is]
        default:
            return [.contains, .is]
        }
    }

    var defaultOperator: MediaSearchOperator {
        allowedOperators.first ?? .is
    }

    var valueEditor: MediaSearchValueEditor {
        switch self {
        case .person:
            return .person
        case .dateTaken:
            return .date
        case .mediaKind:
            return .choice(["photo", "video"])
        case .favorite, .onFrame, .hasFaces:
            return .choice(["yes"])
        case .faceCount:
            return .number
        default:
            return .text
        }
    }

    var placeholder: String {
        switch self {
        case .filename: return "IMG_1234"
        case .albumName: return "Album name"
        case .ocrText: return "Text in photo"
        case .visionTag: return "wedding_cake"
        case .locationNickname: return "Home"
        case .locationPlaceName: return "Fenway Park"
        case .locationCity: return "Boston"
        case .locationState: return "MA"
        case .person: return "Person name"
        case .eventName: return "Event title"
        case .eventTag: return "Christmas"
        case .eventTagCategory: return "holiday"
        case .dateTaken: return "YYYY-MM-DD"
        case .mediaKind: return "photo"
        case .favorite, .onFrame, .hasFaces: return "yes"
        case .camera: return "iPhone / Canon"
        case .faceCount: return "2"
        }
    }

    var choiceLabel: ((String) -> String)? {
        switch self {
        case .mediaKind:
            return { $0 == "video" ? "Video" : "Photo" }
        case .favorite, .onFrame, .hasFaces:
            return { _ in "Yes" }
        default:
            return nil
        }
    }
}

enum MediaSearchValueEditor: Equatable, Sendable {
    case text
    case person
    case date
    case number
    case choice([String])
}

enum MediaSearchOperator: String, CaseIterable, Identifiable, Sendable, Codable {
    case contains
    case `is`
    case on
    case after
    case before
    case between
    case atLeast
    /// Calendar month only, any year (`01`…`12`).
    case inMonth
    /// Month-day without year (`MM-DD`), optional day window.
    case anyYear

    var id: String { rawValue }

    var title: String {
        switch self {
        case .contains: return "contains"
        case .is: return "is"
        case .on: return "on"
        case .after: return "after"
        case .before: return "before"
        case .between: return "between"
        case .atLeast: return "at least"
        case .inMonth: return "in month"
        case .anyYear: return "any year"
        }
    }
}

struct MediaSearchCriterion: Identifiable, Equatable, Sendable, Codable {
    static let maxDayWindow = 60
    static let defaultVisionMinConfidence = 0.12

    let id: UUID
    var field: MediaSearchField
    var op: MediaSearchOperator
    var value: String
    /// End date when `op == .between` (YYYY-MM-DD).
    var secondaryValue: String
    /// Days before the month-day when `op == .anyYear`.
    var daysBefore: Int
    /// Days after the month-day when `op == .anyYear`.
    var daysAfter: Int
    /// Include Fri/Sat before the any-year anchor (year-aware).
    var includeWeekendsBefore: Bool
    /// Include Fri/Sat after the any-year anchor (year-aware).
    var includeWeekendsAfter: Bool
    /// Minimum Vision tag confidence when `field == .visionTag` (0…1).
    var minConfidence: Double
    var isNegated: Bool
    /// When field is `.person`, or birthday person for `.dateTaken` + `.anyYear`.
    var personId: Int?
    /// Catalog holiday for `.dateTaken` + `.anyYear` (fixed or moving).
    var holidayId: Int?
    /// Join before this row (ignored for the first valid term).
    var leadingJoin: MediaSearchMatchMode
    /// Number of `(` inserted before this term.
    var openGroups: Int
    /// Number of `)` inserted after this term.
    var closeGroups: Int

    init(
        id: UUID = UUID(),
        field: MediaSearchField = .filename,
        op: MediaSearchOperator? = nil,
        value: String = "",
        secondaryValue: String = "",
        daysBefore: Int = 0,
        daysAfter: Int = 0,
        includeWeekendsBefore: Bool = false,
        includeWeekendsAfter: Bool = false,
        minConfidence: Double = MediaSearchCriterion.defaultVisionMinConfidence,
        isNegated: Bool = false,
        personId: Int? = nil,
        holidayId: Int? = nil,
        leadingJoin: MediaSearchMatchMode = .all,
        openGroups: Int = 0,
        closeGroups: Int = 0
    ) {
        self.id = id
        self.field = field
        let resolvedOp = op ?? field.defaultOperator
        self.op = field.allowedOperators.contains(resolvedOp) ? resolvedOp : field.defaultOperator
        switch field.valueEditor {
        case .choice(let values):
            self.value = value.isEmpty ? (values.first ?? "") : value
        default:
            self.value = value
        }
        self.secondaryValue = secondaryValue
        self.daysBefore = min(Self.maxDayWindow, max(0, daysBefore))
        self.daysAfter = min(Self.maxDayWindow, max(0, daysAfter))
        self.includeWeekendsBefore = includeWeekendsBefore
        self.includeWeekendsAfter = includeWeekendsAfter
        self.minConfidence = min(1, max(0, minConfidence))
        self.isNegated = isNegated
        self.personId = personId
        self.holidayId = holidayId
        self.leadingJoin = leadingJoin
        self.openGroups = max(0, openGroups)
        self.closeGroups = max(0, closeGroups)
    }

    enum CodingKeys: String, CodingKey {
        case id, field, op, value, secondaryValue, daysBefore, daysAfter
        case includeWeekendsBefore, includeWeekendsAfter, minConfidence, isNegated
        case personId, holidayId, leadingJoin, openGroups, closeGroups
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        let decodedField = try container.decode(MediaSearchField.self, forKey: .field)
        field = decodedField
        let decodedOp = try container.decodeIfPresent(MediaSearchOperator.self, forKey: .op)
        if let decodedOp, decodedField.allowedOperators.contains(decodedOp) {
            op = decodedOp
        } else {
            op = decodedField.defaultOperator
        }
        value = try container.decodeIfPresent(String.self, forKey: .value) ?? ""
        secondaryValue = try container.decodeIfPresent(String.self, forKey: .secondaryValue) ?? ""
        daysBefore = min(
            Self.maxDayWindow,
            max(0, try container.decodeIfPresent(Int.self, forKey: .daysBefore) ?? 0)
        )
        daysAfter = min(
            Self.maxDayWindow,
            max(0, try container.decodeIfPresent(Int.self, forKey: .daysAfter) ?? 0)
        )
        includeWeekendsBefore = try container.decodeIfPresent(Bool.self, forKey: .includeWeekendsBefore) ?? false
        includeWeekendsAfter = try container.decodeIfPresent(Bool.self, forKey: .includeWeekendsAfter) ?? false
        minConfidence = min(
            1,
            max(
                0,
                try container.decodeIfPresent(Double.self, forKey: .minConfidence)
                    ?? Self.defaultVisionMinConfidence
            )
        )
        isNegated = try container.decodeIfPresent(Bool.self, forKey: .isNegated) ?? false
        personId = try container.decodeIfPresent(Int.self, forKey: .personId)
        holidayId = try container.decodeIfPresent(Int.self, forKey: .holidayId)
        leadingJoin = try container.decodeIfPresent(MediaSearchMatchMode.self, forKey: .leadingJoin) ?? .all
        openGroups = max(0, try container.decodeIfPresent(Int.self, forKey: .openGroups) ?? 0)
        closeGroups = max(0, try container.decodeIfPresent(Int.self, forKey: .closeGroups) ?? 0)
    }

    var usesYearAwareDayExpansion: Bool {
        field == .dateTaken
            && op == .anyYear
            && (includeWeekendsBefore || includeWeekendsAfter)
    }

    var isValid: Bool {
        if field == .person, personId != nil { return true }
        if field == .dateTaken, op == .anyYear, holidayId != nil { return true }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if field == .dateTaken {
            switch op {
            case .inMonth:
                return Self.normalizedMonth(trimmed) != nil
            case .anyYear:
                return Self.normalizedMonthDay(trimmed) != nil
            case .between:
                guard Self.isYearMonthDay(trimmed) else { return false }
                let end = secondaryValue.trimmingCharacters(in: .whitespacesAndNewlines)
                return Self.isYearMonthDay(end)
            default:
                return Self.isYearMonthDay(trimmed)
            }
        }
        if field == .faceCount {
            return Int(trimmed).map { $0 >= 0 } ?? false
        }
        return true
    }

    /// `01`…`12` when `value` is a valid month.
    static func normalizedMonth(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let month = Int(trimmed), (1...12).contains(month) else { return nil }
        return String(format: "%02d", month)
    }

    /// `MM-DD` when `value` is a valid month-day (Feb 29 allowed).
    static func normalizedMonthDay(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        let parts = trimmed.split(separator: "-")
        guard parts.count == 2,
              let month = Int(parts[0]), (1...12).contains(month),
              let day = Int(parts[1]), (1...31).contains(day) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? TimeZone.current
        // Leap year so Feb 29 is accepted.
        guard calendar.date(from: DateComponents(year: 2024, month: month, day: day)) != nil else {
            return nil
        }
        return String(format: "%02d-%02d", month, day)
    }

    /// `MM-DD` strings for anchor ± before/after, wrapping across year boundaries.
    static func monthDayWindow(
        monthDay: String,
        daysBefore: Int,
        daysAfter: Int
    ) -> [String] {
        guard let normalized = normalizedMonthDay(monthDay) else { return [] }
        let parts = normalized.split(separator: "-")
        guard parts.count == 2,
              let month = Int(parts[0]),
              let day = Int(parts[1]) else {
            return []
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? TimeZone.current
        guard let anchor = calendar.date(
            from: DateComponents(year: 2024, month: month, day: day)
        ) else {
            return []
        }

        let before = min(maxDayWindow, max(0, daysBefore))
        let after = min(maxDayWindow, max(0, daysAfter))
        var dates: Set<Date> = [calendar.startOfDay(for: anchor)]
        if before > 0 {
            for offset in 1...before {
                if let date = calendar.date(byAdding: .day, value: -offset, to: anchor) {
                    dates.insert(calendar.startOfDay(for: date))
                }
            }
        }
        if after > 0 {
            for offset in 1...after {
                if let date = calendar.date(byAdding: .day, value: offset, to: anchor) {
                    dates.insert(calendar.startOfDay(for: date))
                }
            }
        }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "MM-dd"
        return dates.map { formatter.string(from: $0) }.sorted()
    }

    /// Year-aware `YYYY-MM-DD` days for any-year anchors (needed for weekend expansion).
    static func absoluteISODays(
        monthDay: String,
        daysBefore: Int,
        daysAfter: Int,
        includeWeekendsBefore: Bool,
        includeWeekendsAfter: Bool,
        yearRange: ClosedRange<Int> = HolidayDateResolver.seededYearRange
    ) -> [String] {
        guard let normalized = normalizedMonthDay(monthDay) else { return [] }
        let parts = normalized.split(separator: "-")
        guard parts.count == 2,
              let month = Int(parts[0]),
              let day = Int(parts[1]) else {
            return []
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? TimeZone.current
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"

        var days: Set<String> = []
        for year in yearRange {
            guard let anchor = calendar.date(
                from: DateComponents(year: year, month: month, day: day)
            ) else {
                continue
            }
            for date in expandedDates(
                around: anchor,
                daysBefore: daysBefore,
                daysAfter: daysAfter,
                includeWeekendsBefore: includeWeekendsBefore,
                includeWeekendsAfter: includeWeekendsAfter,
                calendar: calendar
            ) {
                days.insert(formatter.string(from: date))
            }
        }
        return days.sorted()
    }

    static func absoluteISODays(
        aroundAnchors anchors: [String],
        daysBefore: Int,
        daysAfter: Int,
        includeWeekendsBefore: Bool,
        includeWeekendsAfter: Bool
    ) -> [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? TimeZone.current
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"

        var days: Set<String> = []
        for anchorISO in anchors {
            let trimmed = anchorISO.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 10,
                  let anchor = formatter.date(from: String(trimmed.prefix(10))) else {
                continue
            }
            for date in expandedDates(
                around: anchor,
                daysBefore: daysBefore,
                daysAfter: daysAfter,
                includeWeekendsBefore: includeWeekendsBefore,
                includeWeekendsAfter: includeWeekendsAfter,
                calendar: calendar
            ) {
                days.insert(formatter.string(from: date))
            }
        }
        return days.sorted()
    }

    private static func expandedDates(
        around anchor: Date,
        daysBefore: Int,
        daysAfter: Int,
        includeWeekendsBefore: Bool,
        includeWeekendsAfter: Bool,
        calendar: Calendar
    ) -> Set<Date> {
        let before = min(maxDayWindow, max(0, daysBefore))
        let after = min(maxDayWindow, max(0, daysAfter))
        var dates: Set<Date> = [calendar.startOfDay(for: anchor)]
        if before > 0 {
            for offset in 1...before {
                if let date = calendar.date(byAdding: .day, value: -offset, to: anchor) {
                    dates.insert(calendar.startOfDay(for: date))
                }
            }
        }
        if after > 0 {
            for offset in 1...after {
                if let date = calendar.date(byAdding: .day, value: offset, to: anchor) {
                    dates.insert(calendar.startOfDay(for: date))
                }
            }
        }
        if includeWeekendsBefore {
            for weekday in [6, 7] {
                if let date = nearestWeekday(weekday, before: anchor, calendar: calendar) {
                    dates.insert(calendar.startOfDay(for: date))
                }
            }
        }
        if includeWeekendsAfter {
            for weekday in [6, 7] {
                if let date = nearestWeekday(weekday, after: anchor, calendar: calendar) {
                    dates.insert(calendar.startOfDay(for: date))
                }
            }
        }
        return dates
    }

    private static func nearestWeekday(
        _ weekday: Int,
        before date: Date,
        calendar: Calendar
    ) -> Date? {
        var candidate = calendar.date(byAdding: .day, value: -1, to: date)
        for _ in 0..<7 {
            guard let day = candidate else { return nil }
            if calendar.component(.weekday, from: day) == weekday {
                return day
            }
            candidate = calendar.date(byAdding: .day, value: -1, to: day)
        }
        return nil
    }

    private static func nearestWeekday(
        _ weekday: Int,
        after date: Date,
        calendar: Calendar
    ) -> Date? {
        var candidate = calendar.date(byAdding: .day, value: 1, to: date)
        for _ in 0..<7 {
            guard let day = candidate else { return nil }
            if calendar.component(.weekday, from: day) == weekday {
                return day
            }
            candidate = calendar.date(byAdding: .day, value: 1, to: day)
        }
        return nil
    }

    private static func isYearMonthDay(_ value: String) -> Bool {
        let parts = value.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), year >= 1000,
              let month = Int(parts[1]), (1...12).contains(month),
              let day = Int(parts[2]), (1...31).contains(day) else {
            return false
        }
        return value.count == 10
    }
}

struct MediaSearchQuery: Equatable, Sendable, Codable {
    /// Default AND/OR used when adding a new condition.
    var matchMode: MediaSearchMatchMode
    var criteria: [MediaSearchCriterion]

    var isValid: Bool {
        let valid = criteria.filter(\.isValid)
        guard !valid.isEmpty else { return false }
        return Self.parenthesesAreBalanced(valid)
    }

    /// Human-readable expression for the sheet footer.
    var expressionPreview: String {
        let valid = criteria.filter(\.isValid)
        guard !valid.isEmpty else { return "" }
        var parts: [String] = []
        for (index, criterion) in valid.enumerated() {
            if index > 0 {
                parts.append(criterion.leadingJoin.shortTitle)
            }
            if criterion.openGroups > 0 {
                parts.append(String(repeating: "(", count: criterion.openGroups))
            }
            let notPrefix = criterion.isNegated ? "NOT " : ""
            parts.append("\(notPrefix)\(criterion.field.title)")
            if criterion.closeGroups > 0 {
                parts.append(String(repeating: ")", count: criterion.closeGroups))
            }
        }
        return parts.joined(separator: " ")
    }

    static func empty() -> MediaSearchQuery {
        MediaSearchQuery(
            matchMode: .all,
            criteria: [MediaSearchCriterion()]
        )
    }

    static func parenthesesAreBalanced(_ criteria: [MediaSearchCriterion]) -> Bool {
        var depth = 0
        for criterion in criteria {
            depth += criterion.openGroups
            if depth < 0 { return false }
            depth -= criterion.closeGroups
            if depth < 0 { return false }
        }
        return depth == 0
    }
}

/// Flat boolean expression tokens produced from criteria + parentheses.
enum MediaSearchExpressionToken: Equatable, Sendable {
    case open
    case close
    case join(MediaSearchMatchMode)
    case term(UUID)
}

enum MediaSearchExpressionBuilder {
    static func tokens(from criteria: [MediaSearchCriterion]) -> [MediaSearchExpressionToken]? {
        let valid = criteria.filter(\.isValid)
        guard !valid.isEmpty, MediaSearchQuery.parenthesesAreBalanced(valid) else {
            return nil
        }

        var tokens: [MediaSearchExpressionToken] = []
        for (index, criterion) in valid.enumerated() {
            if index > 0 {
                tokens.append(.join(criterion.leadingJoin))
            }
            for _ in 0..<criterion.openGroups {
                tokens.append(.open)
            }
            tokens.append(.term(criterion.id))
            for _ in 0..<criterion.closeGroups {
                tokens.append(.close)
            }
        }
        return tokens
    }
}

struct MediaPhotoSearchReport: Sendable {
    let photoIds: [String]
    let matchCount: Int
}
