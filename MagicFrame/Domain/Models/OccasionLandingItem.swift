import Foundation

struct OccasionLandingItem: Identifiable, Equatable, Sendable {
    let occasionId: Int
    let occasionKey: String
    let name: String
    let occasionType: String
    let tagValue: String
    let nextOccurrence: Date
    let collectionCount: Int?
    let onFramePhotoCount: Int?

    var id: String { occasionKey }

    var isBirthday: Bool { occasionType == "birthday" }

    var usesOccasionFrameLanding: Bool {
        isBirthday || occasionKey == "mothers_day" || occasionKey == "fathers_day"
    }

    var eventListFilter: EventListFilter {
        if isBirthday {
            return .birthdayOccasion(occasionKey: occasionKey, displayName: name)
        }
        return .holidayTag(value: tagValue)
    }

    var parentSubjectRole: OccasionSubjectRole {
        if isBirthday {
            return .person
        }
        return occasionKey == "fathers_day" ? .father : .mother
    }

    var nextOccurrenceLabel: String {
        Self.nextOccurrenceFormatter.string(from: nextOccurrence)
    }

    var collectionCountLabel: String {
        guard let collectionCount else { return "… collections" }
        return collectionCount == 1 ? "1 collection" : "\(collectionCount.formatted()) collections"
    }

    var onFramePhotoCountLabel: String {
        guard let onFramePhotoCount else { return "… of pics on frame" }
        if onFramePhotoCount == 1 {
            return "1 of pic on frame"
        }
        return "\(onFramePhotoCount.formatted()) of pics on frame"
    }

    private static let nextOccurrenceFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale.current
        formatter.dateFormat = "MMMM d"
        return formatter
    }()

    func withCounts(collection: Int, onFrame: Int) -> OccasionLandingItem {
        OccasionLandingItem(
            occasionId: occasionId,
            occasionKey: occasionKey,
            name: name,
            occasionType: occasionType,
            tagValue: tagValue,
            nextOccurrence: nextOccurrence,
            collectionCount: collection,
            onFramePhotoCount: onFrame
        )
    }
}

struct OccasionLandingMetricsRequest: Sendable {
    let occasionKey: String
    let tagValue: String
    let occasionType: String
    let displayName: String
}

struct OccasionLandingCatalogRow: Sendable {
    let occasionId: Int
    let occasionKey: String
    let name: String
    let occasionType: String
    let nextOccurrenceISO: String
}
