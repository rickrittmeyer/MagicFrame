import SwiftUI

struct MilestonesLandingView: View {

    @ObservedObject var vm: LibraryViewModel

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        ScrollView {
            if vm.milestoneLandingItems.isEmpty {
                ContentUnavailableView(
                    "No Milestones",
                    systemImage: "star.fill",
                    description: Text(
                        "Birthdays, weddings, graduations, and other milestones will appear here."
                    )
                )
                .padding(.top, 40)
            } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(vm.milestoneLandingItems) { item in
                        NavigationLink {
                            destination(for: item)
                        } label: {
                            CategoryTileCard(
                                title: item.title,
                                systemImage: item.systemImage,
                                tint: TagCategoryLandingCatalog.milestoneTint(for: item.tagValue),
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
        .navigationTitle("Milestones")
        .navigationBarTitleDisplayMode(.large)
        .task {
            await vm.refreshMilestoneLandingItems()
        }
        .onAppear {
            vm.clearEventsTabFocus()
            vm.setMainTabChromeMode(.landing)
        }
    }

    @ViewBuilder
    private func destination(for item: TagCategoryLandingItem) -> some View {
        let topicId = item.id.replacingOccurrences(of: "milestones:", with: "")
        if topicId == "birthdays" {
            BirthdaysLandingView(vm: vm)
        } else if let topic = MilestoneTopicCatalog.topic(id: topicId) {
            MilestoneTopicView(topic: topic, vm: vm)
        } else if let topic = MilestoneTopicCatalog.topic(forFilter: item.filter) {
            MilestoneTopicView(topic: topic, vm: vm)
        } else {
            EventsLibraryScreen(filter: item.filter, vm: vm)
        }
    }
}
