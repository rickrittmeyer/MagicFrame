import SwiftUI

struct EventAttributeTagChip: View {

    let tag: EventAttributeTag
    var showsCategoryIcon: Bool = false
    var showsScore: Bool = false
    var onConfirmAI: (() -> Void)?
    var onRemoveAI: (() -> Void)?
    var onShowScoreDetails: (() -> Void)?
    var onTap: (() -> Void)?

    @State private var isShowingAIActionDialog = false

    var body: some View {
        Group {
            if tag.isAIDerived, onConfirmAI != nil || onRemoveAI != nil {
                Button {
                    isShowingAIActionDialog = true
                } label: {
                    chipLabel
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(tag.tagValue) \(tag.category.menuTitle) tag, AI suggested")
                .accessibilityHint("Opens confirm or remove options")
            } else if let onTap {
                Button {
                    onTap()
                } label: {
                    chipLabel
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(tag.tagValue) \(tag.category.menuTitle) tag")
                .accessibilityHint("Opens birthday person picker")
            } else {
                chipLabel
                    .accessibilityLabel("\(tag.tagValue) \(tag.category.menuTitle) tag")
            }
        }
        .confirmationDialog(
            tag.tagValue,
            isPresented: $isShowingAIActionDialog,
            titleVisibility: .visible
        ) {
            if let onConfirmAI {
                Button("Confirm") {
                    onConfirmAI()
                }
            }
            if let onRemoveAI {
                Button("Remove", role: .destructive) {
                    onRemoveAI()
                }
            }
            if showsScore, let onShowScoreDetails {
                Button("Score breakdown") {
                    onShowScoreDetails()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Keep this \(tag.category.menuTitle.lowercased()) tag or remove it and stop auto-tagging.")
        }
    }

    private var chipLabel: some View {
        HStack(spacing: 6) {
            if showsCategoryIcon {
                Image(systemName: tag.category.iconName)
                    .font(.caption2.weight(.semibold))
            }

            Text(tag.tagValue)
                .font(.caption.weight(.semibold))

            if showsScore,
               tag.isAIDerived,
               let formattedScore = tag.formattedScore {
                Text(formattedScore)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(accentColor.opacity(0.85))
            }
        }
        .foregroundStyle(accentColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(accentColor.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(accentColor, style: strokeStyle)
        }
    }

    private var accentColor: Color {
        tag.isAIDerived ? .orange : .green
    }

    private var strokeStyle: StrokeStyle {
        if tag.isAIDerived {
            StrokeStyle(lineWidth: 1, dash: [4, 3])
        } else {
            StrokeStyle(lineWidth: 1)
        }
    }
}
