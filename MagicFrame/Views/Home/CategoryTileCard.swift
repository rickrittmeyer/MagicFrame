import SwiftUI

/// Shared tile used by the home grid and category landing screens.
struct CategoryTileCard: View {

    let title: String
    let systemImage: String
    let tint: Color
    var countLabel: String? = nil
    var primarySubtitle: String? = nil
    var isEnabled: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 28))
                .foregroundStyle(tint.opacity(isEnabled ? 1 : 0.55))
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .minimumScaleFactor(0.85)

            if let primarySubtitle {
                Text(primarySubtitle)
                    .font(.subheadline)
                    .fontWeight(.regular)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }

            if let countLabel {
                Text(countLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Image(systemName: "chevron.right.circle.fill")
                    .font(.title3)
                    .foregroundStyle(tint.opacity(isEnabled ? 1 : 0.35))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: primarySubtitle == nil ? 120 : 140, alignment: .topLeading)
        .background(tint.opacity(isEnabled ? 0.12 : 0.08))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(tint.opacity(isEnabled ? 0.35 : 0.15), lineWidth: 1)
        }
        .opacity(isEnabled ? 1 : 0.55)
    }
}
