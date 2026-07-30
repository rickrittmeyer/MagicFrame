import Foundation

/// Pure date overlap scoring for occasion windows vs event photo ranges.
enum OccasionDateScoring {

    struct Window {
        let anchor: Date
        let start: Date
        let end: Date
    }

    struct Breakdown: Sendable, Equatable {
        let anchorDateISO: String
        let windowStartISO: String
        let windowEndISO: String
        let eventRangeStartISO: String
        let eventRangeEndISO: String
        let eventMidpointISO: String
        let dayOffset: Int
        let windowSpanDays: Int
        let decaySpan: Int
        let overlapsWindow: Bool
        let computedDateScore: Double
    }

    struct WindowResolutionInput: Sendable {
        let year: Int
        let occasionKey: String
        let anchorISO: String
        let explicitStartISO: String?
        let explicitEndISO: String?
        let daysBefore: Int
        let daysAfter: Int
        let usesThanksgivingRelativeStart: Bool
        let daysAfterThanksgiving: Int
    }

    static func resolveScoringWindow(
        _ input: WindowResolutionInput,
        calendar: Calendar = .current
    ) -> Window? {
        guard let anchor = EventDateParser.parseDate(input.anchorISO) else { return nil }

        let anchorDay = calendar.startOfDay(for: anchor)

        if let explicitStartISO = input.explicitStartISO,
           let explicitEndISO = input.explicitEndISO,
           let start = EventDateParser.parseDate(explicitStartISO),
           let end = EventDateParser.parseDate(explicitEndISO) {
            return Window(
                anchor: anchorDay,
                start: calendar.startOfDay(for: start),
                end: endOfDay(end, calendar: calendar)
            )
        }

        if input.occasionKey == "christmas", input.usesThanksgivingRelativeStart,
           let thanksgiving = USThanksgivingDate.date(forYear: input.year, calendar: calendar) {
            let thanksgivingDay = calendar.startOfDay(for: thanksgiving)
            guard let start = calendar.date(
                byAdding: .day,
                value: input.daysAfterThanksgiving,
                to: thanksgivingDay
            ),
            let end = calendar.date(byAdding: .day, value: input.daysAfter, to: anchorDay) else {
                return nil
            }

            return Window(
                anchor: anchorDay,
                start: start,
                end: endOfDay(end, calendar: calendar)
            )
        }

        return resolveAnchorRelativeWindow(
            anchorDay: anchorDay,
            daysBefore: input.daysBefore,
            daysAfter: input.daysAfter,
            calendar: calendar
        )
    }

    static func resolveWindow(
        anchorISO: String,
        explicitStartISO: String?,
        explicitEndISO: String?,
        daysBefore: Int,
        daysAfter: Int,
        calendar: Calendar = .current
    ) -> Window? {
        guard let anchor = EventDateParser.parseDate(anchorISO) else { return nil }
        let anchorDay = calendar.startOfDay(for: anchor)

        if let explicitStartISO,
           let explicitEndISO,
           let start = EventDateParser.parseDate(explicitStartISO),
           let end = EventDateParser.parseDate(explicitEndISO) {
            return Window(
                anchor: anchorDay,
                start: calendar.startOfDay(for: start),
                end: endOfDay(end, calendar: calendar)
            )
        }

        return resolveAnchorRelativeWindow(
            anchorDay: anchorDay,
            daysBefore: daysBefore,
            daysAfter: daysAfter,
            calendar: calendar
        )
    }

    private static func resolveAnchorRelativeWindow(
        anchorDay: Date,
        daysBefore: Int,
        daysAfter: Int,
        calendar: Calendar
    ) -> Window? {
        guard let start = calendar.date(byAdding: .day, value: -daysBefore, to: anchorDay),
              let end = calendar.date(byAdding: .day, value: daysAfter, to: anchorDay) else {
            return nil
        }

        return Window(
            anchor: anchorDay,
            start: start,
            end: endOfDay(end, calendar: calendar)
        )
    }

    /// 1.0 when the event midpoint is on the anchor day; decays by days outside the anchor but inside the window.
    static func dateScore(
        eventStart: Date,
        eventEnd: Date,
        window: Window,
        calendar: Calendar = .current
    ) -> Double {
        let rangeStart = min(eventStart, eventEnd)
        let rangeEnd = max(eventStart, eventEnd)

        guard rangeEnd >= window.start, rangeStart <= window.end else {
            return 0
        }

        let midpoint = Date(
            timeIntervalSince1970: (rangeStart.timeIntervalSince1970 + rangeEnd.timeIntervalSince1970) / 2
        )
        let anchorDay = calendar.startOfDay(for: window.anchor)
        let midDay = calendar.startOfDay(for: midpoint)

        let dayOffset = abs(calendar.dateComponents([.day], from: anchorDay, to: midDay).day ?? 0)
        if dayOffset == 0 {
            return 1.0
        }

        let windowStartDay = calendar.startOfDay(for: window.start)
        let windowEndDay = calendar.startOfDay(for: window.end)
        let windowSpanDays = max(
            1,
            (calendar.dateComponents([.day], from: windowStartDay, to: windowEndDay).day ?? 0) + 1
        )
        let decaySpan = max(1, windowSpanDays / 2)

        return max(0, 1.0 - Double(dayOffset) / Double(decaySpan))
    }

    static func breakdown(
        eventStart: Date,
        eventEnd: Date,
        window: Window,
        calendar: Calendar = .current
    ) -> Breakdown {
        let rangeStart = min(eventStart, eventEnd)
        let rangeEnd = max(eventStart, eventEnd)
        let overlapsWindow = rangeEnd >= window.start && rangeStart <= window.end

        let midpoint = Date(
            timeIntervalSince1970: (rangeStart.timeIntervalSince1970 + rangeEnd.timeIntervalSince1970) / 2
        )
        let anchorDay = calendar.startOfDay(for: window.anchor)
        let midDay = calendar.startOfDay(for: midpoint)
        let dayOffset = abs(calendar.dateComponents([.day], from: anchorDay, to: midDay).day ?? 0)

        let windowStartDay = calendar.startOfDay(for: window.start)
        let windowEndDay = calendar.startOfDay(for: window.end)
        let windowSpanDays = max(
            1,
            (calendar.dateComponents([.day], from: windowStartDay, to: windowEndDay).day ?? 0) + 1
        )
        let decaySpan = max(1, windowSpanDays / 2)
        let computedDateScore = dateScore(
            eventStart: eventStart,
            eventEnd: eventEnd,
            window: window,
            calendar: calendar
        )

        return Breakdown(
            anchorDateISO: EventDateParser.dateOnlyISO(from: window.anchor, calendar: calendar),
            windowStartISO: EventDateParser.dateOnlyISO(from: window.start, calendar: calendar),
            windowEndISO: EventDateParser.dateOnlyISO(from: window.end, calendar: calendar),
            eventRangeStartISO: EventDateParser.dateOnlyISO(from: rangeStart, calendar: calendar),
            eventRangeEndISO: EventDateParser.dateOnlyISO(from: rangeEnd, calendar: calendar),
            eventMidpointISO: EventDateParser.dateOnlyISO(from: midpoint, calendar: calendar),
            dayOffset: dayOffset,
            windowSpanDays: windowSpanDays,
            decaySpan: decaySpan,
            overlapsWindow: overlapsWindow,
            computedDateScore: computedDateScore
        )
    }

    static func yearsSpanning(
        eventStart: Date,
        eventEnd: Date,
        calendar: Calendar = .current
    ) -> [Int] {
        let startYear = calendar.component(.year, from: min(eventStart, eventEnd))
        let endYear = calendar.component(.year, from: max(eventStart, eventEnd))
        guard startYear <= endYear else { return [] }
        return Array(startYear...endYear)
    }

    private static func endOfDay(_ date: Date, calendar: Calendar) -> Date {
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: DateComponents(day: 1, second: -1), to: start) ?? date
    }
}
