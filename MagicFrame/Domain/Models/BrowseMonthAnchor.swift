import Foundation

/// Year + month scroll position shared across paired Photos and Events surfaces.
struct BrowseMonthAnchor: Equatable, Sendable {
    let year: Int
    let month: Int

    init?(year: Int, month: Int) {
        guard year >= 1000, (1...12).contains(month) else { return nil }
        self.year = year
        self.month = month
    }

    /// Events month section id (`YYYYMM`).
    var yyyymm: Int { year * 100 + month }

    /// Photos month section id (`yyyy-MM`).
    var photoSectionId: String {
        String(format: "%04d-%02d", year, month)
    }

    static func from(yyyymm: Int) -> BrowseMonthAnchor? {
        let year = yyyymm / 100
        let month = yyyymm % 100
        return BrowseMonthAnchor(year: year, month: month)
    }

    static func from(photoSectionId: String) -> BrowseMonthAnchor? {
        let parts = photoSectionId.split(separator: "-")
        guard parts.count >= 2,
              let year = Int(parts[0]),
              let month = Int(parts[1]) else {
            return nil
        }
        return BrowseMonthAnchor(year: year, month: month)
    }
}

/// Identifies which Photos↔Events pair an anchor belongs to.
enum BrowseMonthScope: Hashable, Sendable {
    case allLibrary
    case eventsFilter(EventListFilter)
}
