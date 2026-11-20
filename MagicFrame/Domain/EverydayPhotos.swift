import Foundation

enum EverydayPhotos {
    static let tagValue = "Everyday Photos"
    static let namePrefix = "Everyday Photos "

    static func title(containing date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMMM yyyy"
        return namePrefix + formatter.string(from: date)
    }

    static func monthBounds(containing date: Date) -> (start: Date, end: Date) {
        let calendar = Calendar.current
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
        let nextMonth = calendar.date(byAdding: .month, value: 1, to: start) ?? start
        let end = nextMonth.addingTimeInterval(-1)
        return (start, end)
    }

    static func isEverydayName(_ name: String) -> Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(namePrefix)
    }
}

struct PhotoMoveWindow {
    struct OutsidePhoto: Identifiable {
        let photoId: String
        let date: Date
        var id: String { photoId }
    }

    let windowStart: Date
    let windowEnd: Date
    let outside: [OutsidePhoto]

    var isEmpty: Bool { outside.isEmpty }

    /// True when extending the event would reach more than a year outside the current window.
    var needsYearConfirmation: Bool {
        let year: TimeInterval = 365 * 24 * 60 * 60
        return outside.contains { photo in
            photo.date < windowStart.addingTimeInterval(-year)
                || photo.date > windowEnd.addingTimeInterval(year)
        }
    }

    static func evaluate(
        dates: [String: Date],
        windowStart: Date,
        windowEnd: Date
    ) -> PhotoMoveWindow {
        let start = min(windowStart, windowEnd)
        let end = max(windowStart, windowEnd)
        let outside = dates.compactMap { photoId, date -> OutsidePhoto? in
            guard date < start || date > end else { return nil }
            return OutsidePhoto(photoId: photoId, date: date)
        }
        .sorted { $0.date < $1.date }
        return PhotoMoveWindow(windowStart: start, windowEnd: end, outside: outside)
    }

    func message(eventSummary: String) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        let window = "\(formatter.string(from: windowStart)) – \(formatter.string(from: windowEnd))"
        if outside.count == 1, let photo = outside.first {
            return "This photo is \(formatter.string(from: photo.date)). This event is \(window). \(eventSummary)"
        }
        let listed = outside.prefix(8).map { formatter.string(from: $0.date) }.joined(separator: ", ")
        let extra = outside.count > 8 ? " and \(outside.count - 8) more" : ""
        return "\(outside.count) photos are outside this event (\(listed)\(extra)). This event is \(window). \(eventSummary)"
    }
}
