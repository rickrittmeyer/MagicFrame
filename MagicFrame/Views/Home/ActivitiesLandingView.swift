import SwiftUI

struct ActivitiesLandingView: View {

    @ObservedObject var vm: LibraryViewModel

    var body: some View {
        TagCategoryLandingView(
            title: "Activities",
            emptySystemImage: "figure.run",
            emptyDescription: "Activity types like hiking and dance will appear here.",
            items: vm.activityLandingItems,
            tintForValue: TagCategoryLandingCatalog.activityTint(for:),
            vm: vm
        )
        .task {
            await vm.refreshActivityLandingItems()
        }
        .onAppear {
            vm.clearEventsTabFocus()
            vm.setMainTabChromeMode(.landing)
        }
    }
}
