import SwiftUI

/// Shared landing grid for tag categories (Milestones, Activities).
struct TagCategoryLandingView: View {

    let title: String
    let emptySystemImage: String
    let emptyDescription: String
    let items: [TagCategoryLandingItem]
    let tintForValue: (String) -> Color
    @ObservedObject var vm: LibraryViewModel

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        ScrollView {
            if items.isEmpty {
                ContentUnavailableView(
                    "No \(title)",
                    systemImage: emptySystemImage,
                    description: Text(emptyDescription)
                )
                .padding(.top, 40)
            } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(items) { item in
                        NavigationLink {
                            EventsLibraryScreen(filter: item.filter, vm: vm)
                        } label: {
                            CategoryTileCard(
                                title: item.title,
                                systemImage: item.systemImage,
                                tint: tintForValue(item.tagValue),
                                primarySubtitle: item.subtitle
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.large)
    }
}
