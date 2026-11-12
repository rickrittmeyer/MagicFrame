import SwiftUI

struct EventAttributeTagChip: View {

    let tag: EventAttributeTag
    var showsCategoryIcon: Bool = false
    var showsScore: Bool = false
    var onConfirmAI: (() -> Void)?
    /// Remove this tag (AI reject or user delete). Triggers similar-event alternatives when configured.
    var onRemove: (() -> Void)?
    var onShowScoreDetails: (() -> Void)?
    var onTap: (() -> Void)?

    @State private var isShowingActionDialog = false

    /// Back-compat for call sites still using `onRemoveAI`.
    init(
        tag: EventAttributeTag,
        showsCategoryIcon: Bool = false,
        showsScore: Bool = false,
        onConfirmAI: (() -> Void)? = nil,
        onRemoveAI: (() -> Void)? = nil,
        onRemove: (() -> Void)? = nil,
        onShowScoreDetails: (() -> Void)? = nil,
        onTap: (() -> Void)? = nil
    ) {
        self.tag = tag
        self.showsCategoryIcon = showsCategoryIcon
        self.showsScore = showsScore
        self.onConfirmAI = onConfirmAI
        self.onRemove = onRemove ?? onRemoveAI
        self.onShowScoreDetails = onShowScoreDetails
        self.onTap = onTap
    }

    private var showsActionDialog: Bool {
        onConfirmAI != nil || onRemove != nil || (showsScore && onShowScoreDetails != nil)
    }

    var body: some View {
        Group {
            if showsActionDialog {
                Button {
                    isShowingActionDialog = true
                } label: {
                    chipLabel
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityTitle)
                .accessibilityHint("Opens tag actions")
            } else if let onTap {
                Button {
                    onTap()
                } label: {
                    chipLabel
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityTitle)
                .accessibilityHint("Opens tag options")
            } else {
                chipLabel
                    .accessibilityLabel(accessibilityTitle)
            }
        }
        .confirmationDialog(
            tag.tagValue,
            isPresented: $isShowingActionDialog,
            titleVisibility: .visible
        ) {
            if tag.isAIDerived, let onConfirmAI {
                Button("Confirm") {
                    onConfirmAI()
                }
            }
            if let onTap, !tag.isAIDerived {
                Button("Edit") {
                    onTap()
                }
            }
            if let onRemove {
                Button("Remove", role: .destructive) {
                    onRemove()
                }
            }
            if showsScore, tag.isAIDerived, let onShowScoreDetails {
                Button("Score breakdown") {
                    onShowScoreDetails()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if tag.isAIDerived {
                Text("Keep this \(tag.category.menuTitle.lowercased()) tag or remove it and stop auto-tagging.")
            } else {
                Text("Remove this \(tag.category.menuTitle.lowercased()) tag, or edit it.")
            }
        }
    }

    private var accessibilityTitle: String {
        let source = tag.isAIDerived ? "AI suggested" : "user"
        return "\(tag.tagValue) \(tag.category.menuTitle) tag, \(source)"
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
