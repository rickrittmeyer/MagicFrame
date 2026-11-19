import SwiftUI

struct HomeCategoryGridView: View {

    @ObservedObject var vm: LibraryViewModel

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            NavigationLink {
                PictureBrowserView(
                    title: "All",
                    loadsAllPhotos: true,
                    sortOptions: [.dateTaken, .dateImported],
                    usesNavigationTitle: true,
                    enablesVideoFilter: true,
                    browseMonthScope: .allLibrary
                )
            } label: {
                HomeCategoryCard(
                    title: "All Media",
                    systemImage: "photo.on.rectangle.angled",
                    tint: Color(red: 0.55, green: 0.45, blue: 0.85),
                    isEnabled: true,
                    countLabel: countText(vm.homeAllPhotosCount, singular: "photo")
                )
            }
            .buttonStyle(.plain)

            NavigationLink {
                HolidaysLandingView(vm: vm)
            } label: {
                HomeCategoryCard(
                    title: "Holidays",
                    systemImage: "gift.fill",
                    tint: Color(red: 0.35, green: 0.68, blue: 0.45),
                    isEnabled: true
                )
            }
            .buttonStyle(.plain)

            NavigationLink {
                MilestonesLandingView(vm: vm)
            } label: {
                HomeCategoryCard(
                    title: "Milestones",
                    systemImage: "star.fill",
                    tint: Color(red: 0.78, green: 0.32, blue: 0.48),
                    isEnabled: true
                )
            }
            .buttonStyle(.plain)

            NavigationLink {
                OutingsLandingView(vm: vm)
            } label: {
                HomeCategoryCard(
                    title: "Outings",
                    systemImage: "ticket.fill",
                    tint: Color(red: 0.45, green: 0.4, blue: 0.7),
                    isEnabled: true
                )
            }
            .buttonStyle(.plain)

            NavigationLink {
                EventsLibraryScreen(filter: .trips, vm: vm)
            } label: {
                HomeCategoryCard(
                    title: "Trips",
                    systemImage: "suitcase.fill",
                    tint: Color(red: 0.35, green: 0.55, blue: 0.9),
                    isEnabled: true
                )
            }
            .buttonStyle(.plain)

            NavigationLink {
                ActivitiesLandingView(vm: vm)
            } label: {
                HomeCategoryCard(
                    title: "Activities",
                    systemImage: "figure.run",
                    tint: Color(red: 0.95, green: 0.55, blue: 0.25),
                    isEnabled: true
                )
            }
            .buttonStyle(.plain)

            placeholderCard(
                title: "Vibes",
                systemImage: "sparkles",
                tint: Color(red: 0.65, green: 0.4, blue: 0.85)
            )

            NavigationLink {
                PeopleLandingView(vm: vm)
            } label: {
                HomeCategoryCard(
                    title: "People",
                    systemImage: "person.2.fill",
                    tint: Color(red: 0.9, green: 0.45, blue: 0.55),
                    isEnabled: true,
                    countLabel: countText(vm.homePeopleCount, singular: "person")
                )
            }
            .buttonStyle(.plain)

            NavigationLink {
                LocationsView()
            } label: {
                HomeCategoryCard(
                    title: "Locations",
                    systemImage: "mappin.and.ellipse",
                    tint: Color(red: 0.25, green: 0.62, blue: 0.72),
                    isEnabled: true,
                    countLabel: countText(vm.homeLocationsCount, singular: "location")
                )
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func placeholderCard(title: String, systemImage: String, tint: Color) -> some View {
        HomeCategoryCard(
            title: title,
            systemImage: systemImage,
            tint: tint,
            isEnabled: false,
            countLabel: "Coming soon"
        )
    }

    private func countText(_ count: Int, singular: String) -> String {
        if count == 1 {
            return "1 \(singular)"
        }
        let plural: String
        switch singular {
        case "person":
            plural = "people"
        default:
            plural = singular.hasSuffix("s") ? singular : singular + "s"
        }
        return "\(count.formatted()) \(plural)"
    }
}
