import Foundation

enum PeopleRelationshipClass: String, Sendable, CaseIterable {
    case romantic
    case family
    case friendship
}

enum PeopleRelationshipType: String, Sendable, CaseIterable {
    case married
    case dating
    case engaged
    case exMarried
    case exDating
    case parent
    case stepParent
    case sibling
    case friend
}

enum PeopleRelationshipRole: String, Sendable, CaseIterable {
    case bride
    case groom
    case husband
    case wife
    case boyfriend
    case girlfriend
    case mother
    case father
    case stepmother
    case stepfather
    case daughter
    case son
    case child
    case sister
    case brother
    case sibling
    case friend
    case exWife
    case exHusband
    case exGirlfriend
    case exBoyfriend
}

enum PeopleRelationshipStatus: String, Sendable, CaseIterable {
    case active
    case ended
}

struct PeopleRelationship: Sendable, Equatable, Identifiable {
    let relationshipId: Int
    let personIdA: Int
    let personIdB: Int
    let relationshipClass: PeopleRelationshipClass
    let relationshipType: PeopleRelationshipType
    let roleA: PeopleRelationshipRole
    let roleB: PeopleRelationshipRole
    let status: PeopleRelationshipStatus
    let startDate: String?
    let endDate: String?
    let sourceEventId: Int?
    let source: String
    let notes: String?
    let createdAt: String
    let updatedAt: String

    var id: Int { relationshipId }
}
