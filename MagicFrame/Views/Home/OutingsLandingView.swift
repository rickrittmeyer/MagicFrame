import SwiftUI

struct OutingsLandingView: View {

    @ObservedObject var vm: LibraryViewModel

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        ScrollView {
            if vm.outingLandingItems.isEmpty {
                ContentUnavailableView(
                    "No Outings",
                    systemImage: "ticket.fill",
                    description: Text(
                        "Sporting events, plays, and concerts will appear here."
                    )
                )
                .padding(.top, 40)
            } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(vm.outingLandingItems) { item in
                        NavigationLink {
                            destination(for: item)
                        } label: {
                            CategoryTileCard(
                                title: item.title,
                                systemImage: item.systemImage,
                                tint: TagCategoryLandingCatalog.outingTint(for: item.tagValue),
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
        .navigationTitle("Outings")
        .navigationBarTitleDisplayMode(.large)
        .task {
            await vm.refreshOutingLandingItems()
        }
        .onAppear {
            vm.clearEventsTabFocus()
        }
    }

    @ViewBuilder
    private func destination(for item: TagCategoryLandingItem) -> some View {
        let topicId = item.id.replacingOccurrences(of: "outings:", with: "")
        if let topic = OutingTopicCatalog.topic(id: topicId) {
            OutingTopicView(topic: topic, vm: vm)
        } else if let topic = OutingTopicCatalog.topic(forFilter: item.filter) {
            OutingTopicView(topic: topic, vm: vm)
        } else {
            EventsLibraryScreen(filter: item.filter, vm: vm)
        }
    }
}
