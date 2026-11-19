import SwiftUI

/// Milestones → Birthdays: people with birth dates (each opens a birthday-anchored topic).
struct BirthdaysLandingView: View {

    @ObservedObject var vm: LibraryViewModel

    @State private var people: [PeopleRepository.PersonBirthdayRecord] = []
    @State private var isLoading = true

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        ScrollView {
            if isLoading {
                ProgressView("Loading birthdays…")
                    .frame(maxWidth: .infinity)
                    .padding(.top, 48)
            } else if people.isEmpty {
                ContentUnavailableView(
                    "No Birthdays",
                    systemImage: "birthday.cake.fill",
                    description: Text("People with birth dates in your library will appear here.")
                )
                .padding(.top, 40)
            } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(items) { item in
                        NavigationLink {
                            if let person = people.first(where: {
                                item.id == "birthday:\($0.personId)"
                            }) {
                                BirthdayPersonTopicView(person: person, vm: vm)
                            } else {
                                EventsLibraryScreen(filter: item.filter, vm: vm)
                            }
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
        .navigationTitle("Birthdays")
        .navigationBarTitleDisplayMode(.large)
        .task {
            await reload()
        }
        .onAppear {
            // Stay on Birthdays hub until a person topic focuses Events.
            vm.clearEventsTabFocus()
            vm.setMainTabChromeMode(.landing)
        }
    }

    private var items: [TagCategoryLandingItem] {
        TagCategoryLandingCatalog.birthdayPeople(peopleWithBirthDates: people)
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        people = await Task.detached(priority: .utility) {
            AppDependencies.database.fetchPeopleWithBirthDates()
        }.value
    }
}
