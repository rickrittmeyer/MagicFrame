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
                EventsLibraryScreen(filter: .allEvents, vm: vm)
            } label: {
                HomeCategoryCard(
                    title: "Collections",
                    countLabel: countText(vm.homeCollectionsCount, singular: "collection"),
                    systemImage: "photo.on.rectangle.angled",
                    tint: Color(red: 0.55, green: 0.45, blue: 0.85),
                    isEnabled: true
                )
            }
            .buttonStyle(.plain)

            NavigationLink {
                HolidaysLandingView(vm: vm)
            } label: {
                HomeCategoryCard(
                    title: "Holidays",
                    countLabel: countText(vm.homeChristmasCount, singular: "holiday"),
                    systemImage: "tree.fill",
                    tint: Color(red: 0.35, green: 0.68, blue: 0.45),
                    isEnabled: true
                )
            }
            .buttonStyle(.plain)

            NavigationLink {
                LocationsView()
            } label: {
                HomeCategoryCard(
                    title: "Locations",
                    countLabel: countText(vm.homeLocationsCount, singular: "location"),
                    systemImage: "mappin.and.ellipse",
                    tint: Color(red: 0.25, green: 0.62, blue: 0.72),
                    isEnabled: true
                )
            }
            .buttonStyle(.plain)

            placeholderCard(
                title: "Trips",
                systemImage: "suitcase.fill",
                tint: Color(red: 0.35, green: 0.55, blue: 0.9)
            )

            placeholderCard(
                title: "People",
                systemImage: "person.2.fill",
                tint: Color(red: 0.9, green: 0.45, blue: 0.55)
            )

            placeholderCard(
                title: "Activities",
                systemImage: "figure.run",
                tint: Color(red: 0.95, green: 0.55, blue: 0.25)
            )
        }
    }

    @ViewBuilder
    private func placeholderCard(title: String, systemImage: String, tint: Color) -> some View {
        HomeCategoryCard(
            title: title,
            countLabel: "Coming soon",
            systemImage: systemImage,
            tint: tint,
            isEnabled: false
        )
    }

    private func countText(_ count: Int, singular: String) -> String {
        if count == 1 {
            return "1 \(singular)"
        }
        let plural = singular + (singular.hasSuffix("s") ? "" : "s")
        return "\(count.formatted()) \(plural)"
    }
}
