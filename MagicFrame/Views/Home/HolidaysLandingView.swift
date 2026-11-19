import SwiftUI

struct HolidaysLandingView: View {

    @ObservedObject var vm: LibraryViewModel

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        ScrollView {
            if !vm.hasLoadedHolidayLanding || vm.isLoadingHolidayLanding {
                ProgressView("Loading holidays…")
                    .frame(maxWidth: .infinity)
                    .padding(.top, 48)
            } else if vm.holidayLandingItems.isEmpty {
                ContentUnavailableView(
                    "No Holidays",
                    systemImage: "calendar",
                    description: Text("Built-in holidays and people with birthdays will appear here.")
                )
                .padding(.top, 40)
            } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(vm.holidayLandingItems) { item in
                        NavigationLink {
                            destination(for: item)
                        } label: {
                            HolidayLandingCard(item: item)
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
        .task {
            vm.scheduleHolidayLandingRefresh()
        }
        .onAppear {
            vm.clearEventsTabFocus()
            vm.setMainTabChromeMode(.landing)
        }
        .onDisappear {
            vm.cancelHolidayLandingRefresh()
        }
    }

    @ViewBuilder
    private func destination(for item: HolidayLandingItem) -> some View {
        switch item.kind {
        case .holidayTag(let value):
            HolidayTopicView(tagValue: value, vm: vm)
        case .birthdayPerson(let personId, _):
            if let person = vm.database.fetchPersonBirthdayRecord(personId: personId) {
                BirthdayPersonTopicView(person: person, vm: vm)
            } else {
                ContentUnavailableView(
                    "Birthday Unavailable",
                    systemImage: "birthday.cake",
                    description: Text("Could not load this person’s birthday photos.")
                )
            }
        }
    }
}
