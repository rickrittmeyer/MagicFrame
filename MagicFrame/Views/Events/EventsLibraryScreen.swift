import SwiftUI

/// Toolbar + year-grouped event list. Shared by full-screen collections and embedded location events.
struct EventsLibraryListContent: View {

    let filter: EventListFilter
    @ObservedObject var vm: LibraryViewModel
    var runsDateRepairOnLoad: Bool = false

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Spacer()

                Button {
                    vm.toggleShowHiddenEvents()
                } label: {
                    Image(systemName: vm.showHiddenEvents ? "eye.slash" : "eye.fill")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(vm.showHiddenEvents ? "Show visible events" : "Show hidden events")

                Text(vm.isLoadingEvents ? "…" : "\(vm.events.count)")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)

            EventsLibraryView(
                eventSections: vm.eventSections,
                listFilter: filter,
                emptyHint: filter.emptyHint,
                isBusy: vm.showsEventsLoadingPlaceholder,
                showsHiddenEvents: vm.showHiddenEvents,
                onEventUpdated: { eventId in
                    vm.refreshEvent(eventId: eventId)
                },
                onEventHidden: { eventId in
                    vm.hideEvent(eventId: eventId)
                },
                onEventUnhidden: { eventId in
                    vm.unhideEvent(eventId: eventId)
                },
                scrollTarget: vm.eventListScrollTarget,
                onScrollTargetHandled: {
                    vm.acknowledgeEventListScroll()
                },
                onConfirmAIAttributeTag: { eventId, tag in
                    vm.confirmAIAttributeTag(displayEventId: eventId, tag: tag)
                },
                onRemoveAIAttributeTag: { eventId, tag in
                    vm.rejectAIAttributeTag(displayEventId: eventId, tag: tag)
                },
                onExpandedYearChanged: { year in
                    if vm.activeHolidayVisionConfig != nil {
                        vm.handleHolidayYearExpanded(year)
                    } else {
                        vm.loadSlideshowPhotosForYear(year)
                    }
                },
                prefersFastSlideshowThumbnails: vm.isHolidayVisionScanActive,
                expandedYear: $vm.expandedListYear
            )
            .frame(maxHeight: .infinity)
        }
        .task(id: filter) {
            vm.beginEventListLoad(for: filter)

            // Let the navigation push animation finish before database + layout work.
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }

            await vm.reloadEventsAsync(filter: filter, loadSlideshowIds: false)
            guard !Task.isCancelled else { return }

            if runsDateRepairOnLoad {
                vm.scheduleEventDateRepairIfNeeded()
            }
        }
        .onAppear {
            vm.reloadSlideshowPhotosForExpandedYearIfNeeded()
        }
        .onDisappear {
            if vm.activeHolidayVisionConfig != nil {
                vm.cancelHolidayLandingVisionScans()
            }
        }
    }
}

struct EventsLibraryScreen: View {

    let filter: EventListFilter
    @ObservedObject var vm: LibraryViewModel

    var body: some View {
        EventsLibraryListContent(
            filter: filter,
            vm: vm,
            runsDateRepairOnLoad: filter == .allEvents
        )
        .navigationTitle(filter.navigationTitle)
        .navigationBarTitleDisplayMode(.large)
    }
}
