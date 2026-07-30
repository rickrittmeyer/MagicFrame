import Foundation

/// Drives incremental Vision scans when a holiday collection year section expands.
struct HolidayVisionLandingConfig: Equatable, Sendable {
    let occasionKey: String
    let tagValue: String
    let displayName: String

    var logLabel: String { displayName }
}
