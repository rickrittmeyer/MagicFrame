import SwiftUI

struct OccasionLandingCard: View {

    let item: OccasionLandingItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 28))
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(item.name)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .minimumScaleFactor(0.85)

            Text(item.nextOccurrenceLabel)
                .font(.subheadline)
                .fontWeight(.regular)
                .foregroundStyle(.primary)
                .lineLimit(1)

            Text(item.collectionCountLabel)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(item.onFramePhotoCountLabel)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Image(systemName: "chevron.right.circle.fill")
                    .font(.title3)
                    .foregroundStyle(tint)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
        .background(tint.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(tint.opacity(0.35), lineWidth: 1)
        }
    }

    private var tint: Color {
        if item.isBirthday {
            return Color(red: 0.9, green: 0.45, blue: 0.55)
        }
        switch item.occasionKey {
        case "christmas":
            return Color(red: 0.35, green: 0.68, blue: 0.45)
        case "halloween":
            return Color(red: 0.95, green: 0.55, blue: 0.25)
        case "mothers_day":
            return Color(red: 0.92, green: 0.45, blue: 0.62)
        case "fathers_day":
            return Color(red: 0.3, green: 0.52, blue: 0.82)
        default:
            return Color(red: 0.55, green: 0.45, blue: 0.85)
        }
    }

    private var iconName: String {
        if item.isBirthday {
            return "birthday.cake.fill"
        }
        switch item.occasionKey {
        case "christmas":
            return "tree.fill"
        case "halloween":
            return "moon.stars.fill"
        case "mothers_day":
            return "heart.text.square.fill"
        case "fathers_day":
            return "figure.and.child.holdinghands"
        default:
            return "gift.fill"
        }
    }
}
