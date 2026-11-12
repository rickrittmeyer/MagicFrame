import Foundation

/// Row from `event_name_templates` — how to build a suggested event name for a tag.
struct EventNameTemplate: Sendable, Equatable, Identifiable {
    let eventNameTemplateId: Int
    let tagCategory: String
    let tagValue: String
    /// Placeholders: `{person1}`, `{person2}`, `{tagValue}`.
    let nameTemplate: String
    let personCount: Int

    var id: Int { eventNameTemplateId }

    var field: EventAttributeField? {
        EventAttributeField.fromTagCategory(tagCategory)
    }
}
