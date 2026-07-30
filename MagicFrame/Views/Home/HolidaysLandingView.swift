import SwiftUI

struct HolidaysLandingView: View {

    @ObservedObject var vm: LibraryViewModel

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        ScrollView {
            if !vm.hasLoadedOccasionLanding || vm.isLoadingOccasionLanding {
                ProgressView("Loading occasions…")
                    .frame(maxWidth: .infinity)
                    .padding(.top, 48)
            } else if vm.occasionLandingItems.isEmpty {
                ContentUnavailableView(
                    "No Occasions",
                    systemImage: "calendar",
                    description: Text("Holiday and birthday occasions will appear here after seed data is loaded.")
                )
                .padding(.top, 40)
            } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(vm.occasionLandingItems) { item in
                        NavigationLink {
                            destination(for: item)
                        } label: {
                            OccasionLandingCard(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .navigationTitle("Holidays")
        .navigationBarTitleDisplayMode(.large)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if vm.isLoadingOccasionLandingCounts {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Updating collection counts…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(.bar)
            }
        }
        .task {
            vm.scheduleOccasionLandingRefresh()
        }
        .onDisappear {
            vm.cancelOccasionLandingRefresh()
        }
    }

    @ViewBuilder
    private func destination(for item: OccasionLandingItem) -> some View {
        if item.usesOccasionFrameLanding {
            OccasionFrameLandingView(item: item, vm: vm)
        } else {
            EventsLibraryScreen(
                filter: .holidayTag(value: item.tagValue),
                vm: vm
            )
        }
    }
}
