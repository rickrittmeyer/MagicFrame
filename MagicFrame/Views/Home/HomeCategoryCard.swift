import SwiftUI

/// Home-grid tile. Thin wrapper around the shared `CategoryTileCard`.
struct HomeCategoryCard: View {

    let title: String
    let systemImage: String
    let tint: Color
    let isEnabled: Bool
    var countLabel: String? = nil

    var body: some View {
        CategoryTileCard(
            title: title,
            systemImage: systemImage,
            tint: tint,
            countLabel: countLabel,
            isEnabled: isEnabled
        )
    }
}
