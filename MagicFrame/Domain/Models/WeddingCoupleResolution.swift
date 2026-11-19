import Foundation

/// One resolved bride or groom candidate from the Wedding couple finder.
struct WeddingCoupleRoleCandidate: Equatable, Sendable {
    let personId: Int?
    let displayName: String?
    let faceInstanceId: Int?
    let clusterId: Int?
    let score: Double

    var hasDisplayName: Bool {
        !(displayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
}

/// Result of finding the couple-only photo + scoring bride/groom.
struct WeddingCoupleResolution: Equatable, Sendable {
    let couplePhotoId: String?
    let bride: WeddingCoupleRoleCandidate?
    let groom: WeddingCoupleRoleCandidate?
    let brideTagWritten: Bool
    let groomTagWritten: Bool

    var statusSummary: String {
        var parts: [String] = []
        if let bride, bride.hasDisplayName {
            parts.append("bride \(bride.displayName!)")
        }
        if let groom, groom.hasDisplayName {
            parts.append("groom \(groom.displayName!)")
        }
        if parts.isEmpty {
            if couplePhotoId != nil {
                return "couple photo ready — name faces after confirming Wedding"
            }
            return "no named couple yet"
        }
        return parts.joined(separator: ", ")
    }
}
