import SwiftUI

struct MainTabView: View {

    @ObservedObject var vm: LibraryViewModel

    var body: some View {
        TabView {
            NavigationStack {
                HomeView(vm: vm)
            }
            .environmentObject(vm)
            .tabItem {
                Label("Photos", systemImage: "photo.on.rectangle.angled")
            }

            NavigationStack {
                eventsTabRoot
            }
            .environmentObject(vm)
            .tabItem {
                Label("Events", systemImage: "calendar")
            }

            NavigationStack {
                developerTabRoot
            }
            .environmentObject(vm)
            .tabItem {
                Label("Developer", systemImage: "hammer.fill")
            }
        }
    }

    @ViewBuilder
    private var eventsTabRoot: some View {
        if case .holidayTag(let tagValue) = vm.eventsTabFilter {
            HolidayEventsEntryView(tagValue: tagValue, vm: vm)
        } else if case .birthdayPerson(let personId, let displayName) = vm.eventsTabFilter {
            BirthdayPersonEventsEntryView(
                personId: personId,
                displayName: displayName,
                vm: vm
            )
        } else if let topic = MilestoneTopicCatalog.topic(forFilter: vm.eventsTabFilter) {
            MilestoneEventsEntryView(topic: topic, vm: vm)
        } else if let topic = OutingTopicCatalog.topic(forFilter: vm.eventsTabFilter) {
            OutingEventsEntryView(topic: topic, vm: vm)
        } else {
            EventsLibraryScreen(filter: .allEvents, vm: vm)
        }
    }

    @ViewBuilder
    private var developerTabRoot: some View {
        if case .holidayTag(let tagValue) = vm.eventsTabFilter {
            HolidayDeveloperView(tagValue: tagValue, vm: vm)
        } else if case .birthdayPerson(let personId, let displayName) = vm.eventsTabFilter {
            BirthdayPersonDeveloperView(
                personId: personId,
                displayName: displayName,
                vm: vm
            )
        } else if OutingTopicCatalog.topic(forFilter: vm.eventsTabFilter)?.id == "sporting-events" {
            SportingEventsDeveloperView(vm: vm)
        } else {
            DeveloperView(vm: vm)
        }
    }
}
