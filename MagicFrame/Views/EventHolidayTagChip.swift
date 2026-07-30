import SwiftUI

struct EventHolidayTagChip: View {

    let tag: EventHolidayTag
    var onConfirmAI: (() -> Void)?
    var onRemoveAI: (() -> Void)?

    var body: some View {
        EventAttributeTagChip(
            tag: EventAttributeTag(holidayTag: tag),
            onConfirmAI: onConfirmAI,
            onRemoveAI: onRemoveAI
        )
    }
}
