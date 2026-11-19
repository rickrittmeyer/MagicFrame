import SwiftUI

/// Bottom bar for multi-select: Frame, Favorite, Hide, and Info adjustments.
struct PhotoSelectionToggleBar: View {
    let isEnabled: Bool
    let isFrameOn: Bool
    let isFavoriteOn: Bool
    let isHiddenOn: Bool
    let onToggleFrame: () -> Void
    let onToggleFavorite: () -> Void
    let onToggleHide: () -> Void
    var onAdjustDate: () -> Void = {}
    var onAdjustLocation: () -> Void = {}
    var onAdjustDateAndLocation: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            toggleButton(
                systemName: isFrameOn
                    ? "rectangle.inset.filled.and.play.fill"
                    : "rectangle.on.rectangle",
                label: isFrameOn ? "Off Frame" : "On Frame",
                isOn: isFrameOn,
                accessibilityLabel: "Frame",
                action: onToggleFrame
            )

            toggleButton(
                systemName: isFavoriteOn ? "heart.fill" : "heart",
                label: isFavoriteOn ? "Unfav" : "Fav",
                isOn: isFavoriteOn,
                accessibilityLabel: "Favorite",
                tint: isFavoriteOn ? .pink : nil,
                action: onToggleFavorite
            )

            toggleButton(
                systemName: isHiddenOn ? "eye.slash" : "eye",
                label: isHiddenOn ? "Unhide" : "Hide",
                isOn: isHiddenOn,
                accessibilityLabel: "Hide",
                action: onToggleHide
            )

            infoMenu
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var infoMenu: some View {
        Menu {
            Button("Adjust Date & Time", action: onAdjustDate)
            Button("Adjust Location", action: onAdjustLocation)
            Button("Adjust Date and Location", action: onAdjustDateAndLocation)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "info.circle")
                    .font(.title2)
                    .foregroundStyle(Color.primary)
                    .frame(width: 44, height: 36)
                Text("Info")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .accessibilityLabel("Info")
    }

    private func toggleButton(
        systemName: String,
        label: String,
        isOn: Bool,
        accessibilityLabel: String,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemName)
                    .font(.title2)
                    .foregroundStyle(tint ?? (isOn ? Color.accentColor : Color.primary))
                    .frame(width: 44, height: 36)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
