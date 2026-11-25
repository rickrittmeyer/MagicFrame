import SwiftUI

/// Shared translucent selection footer. Icons and captions stay white, including while pressed.
struct SelectionFooterBar<MoreMenu: View>: View {
    let isEnabled: Bool
    let isFrameOn: Bool
    let favoriteIcon: String
    let favoriteCaption: String
    let hideIcon: String
    let hideCaption: String
    var showsMore: Bool = true
    let onFrame: () -> Void
    let onFavorite: () -> Void
    let onHide: () -> Void
    let onDelete: () -> Void
    @ViewBuilder var moreMenu: () -> MoreMenu

    var body: some View {
        HStack(spacing: 8) {
            control(
                systemName: isFrameOn
                    ? "rectangle.inset.filled.and.play.fill"
                    : "rectangle.on.rectangle",
                caption: isFrameOn ? "On Frame" : "Add to Frame",
                accessibilityLabel: "Frame",
                action: onFrame
            )
            control(
                systemName: favoriteIcon,
                caption: favoriteCaption,
                accessibilityLabel: "Favorite",
                action: onFavorite
            )
            control(
                systemName: hideIcon,
                caption: hideCaption,
                accessibilityLabel: "Hide",
                action: onHide
            )
            control(
                systemName: "trash",
                caption: "Delete",
                accessibilityLabel: "Delete",
                action: onDelete
            )
            if showsMore {
                Menu {
                    moreMenu()
                } label: {
                    controlLabel(systemName: "ellipsis", caption: "More")
                }
                .buttonStyle(.plain)
                .allowsHitTesting(isEnabled)
                .accessibilityLabel("More")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .tint(.white)
        .background {
            Rectangle()
                .fill(.bar)
                .ignoresSafeArea(edges: .bottom)
        }
    }

    private func control(
        systemName: String,
        caption: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            controlLabel(systemName: systemName, caption: caption)
        }
        .buttonStyle(.plain)
        .allowsHitTesting(isEnabled)
        .accessibilityLabel(accessibilityLabel)
    }

    private func controlLabel(systemName: String, caption: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: systemName)
                .font(.title2)
                .frame(width: 44, height: 28)
            Text(caption)
                .font(.caption2)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

enum SelectionDeleteCopy {
    static func eventListConfirmation(eventCount: Int, pictureCount: Int) -> String {
        let eventWord = eventCount == 1 ? "event" : "events"
        let pictureWord = pictureCount == 1 ? "picture" : "pictures"
        return "Are you sure you want to delete \(eventCount) \(eventWord) and all \(pictureCount) \(pictureWord) in it?"
    }
}
