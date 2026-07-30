import SwiftUI

struct HomeCategoryCard: View {

    let title: String
    let countLabel: String
    let systemImage: String
    let tint: Color
    let isEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 28))
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)

            Text(countLabel)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Image(systemName: "chevron.right.circle.fill")
                    .font(.title3)
                    .foregroundStyle(tint.opacity(isEnabled ? 1 : 0.35))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .background(tint.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(tint.opacity(isEnabled ? 0.35 : 0.15), lineWidth: 1)
        }
        .opacity(isEnabled ? 1 : 0.55)
    }
}
