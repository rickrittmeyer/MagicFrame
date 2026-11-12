import SwiftUI

struct HolidayLandingCard: View {

    let item: HolidayLandingItem

    var body: some View {
        CategoryTileCard(
            title: item.name,
            systemImage: iconName,
            tint: tint,
            primarySubtitle: item.nextOccurrenceLabel
        )
    }

    private var tint: Color {
        if item.isBirthday {
            return Color(red: 0.9, green: 0.45, blue: 0.55)
        }
        switch item.name {
        case "Christmas":
            return Color(red: 0.35, green: 0.68, blue: 0.45)
        case "Halloween":
            return Color(red: 0.95, green: 0.55, blue: 0.25)
        case "Mother's Day":
            return Color(red: 0.92, green: 0.45, blue: 0.62)
        case "Father's Day":
            return Color(red: 0.3, green: 0.52, blue: 0.82)
        default:
            return Color(red: 0.55, green: 0.45, blue: 0.85)
        }
    }

    private var iconName: String {
        if item.isBirthday {
            return "birthday.cake.fill"
        }
        switch item.name {
        case "Christmas":
            return "tree.fill"
        case "Halloween":
            return "moon.stars.fill"
        case "Mother's Day":
            return "heart.text.square.fill"
        case "Father's Day":
            return "figure.and.child.holdinghands"
        default:
            return "gift.fill"
        }
    }
}
