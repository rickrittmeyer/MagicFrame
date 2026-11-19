import SwiftUI

private enum MainTab: Hashable, CaseIterable {
    case media
    case events
    case developer
    case search

    var title: String {
        switch self {
        case .media: return "Media"
        case .events: return "Events"
        case .developer: return "Developer"
        case .search: return "Search"
        }
    }

    var systemImage: String {
        switch self {
        case .media: return "photo.on.rectangle.angled"
        case .events: return "calendar"
        case .developer: return "hammer.fill"
        case .search: return "magnifyingglass"
        }
    }
}

/// Custom tab chrome — SwiftUI `TabView` delays system tab highlighting until it
/// reassigns hosting controllers. We also keep **highlight** separate from **content**
/// so tearing down a heavy Media stack (e.g. All Media) cannot block the tab paint.
struct MainTabView: View {

    @ObservedObject var vm: LibraryViewModel
    /// Tab bar selection — updates immediately on tap.
    @State private var highlightedTab: MainTab = .media
    /// Mounted tab content — swaps on the next turn after highlight.
    @State private var contentTab: MainTab = .media
    /// Events list mounts only after content has switched to Events.
    @State private var isEventsContentReady = false
    @State private var mediaPath = NavigationPath()
    /// Remount Media stack when deep-linking from another tab (Events back → Holidays).
    @State private var mediaStackID = UUID()
    @State private var isHelpPresented = false

    private var effectiveChromeMode: MainTabChromeMode {
        switch contentTab {
        case .media:
            return vm.mainTabChromeMode
        case .events, .developer, .search:
            return .full
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            bottomChrome
        }
        .environmentObject(vm)
        .background(Color(.systemBackground))
        .sheet(isPresented: $isHelpPresented) {
            NavigationStack {
                HelpPlaceholderView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { isHelpPresented = false }
                        }
                    }
            }
        }
        .onChange(of: vm.mediaNavigationRequest) { _, request in
            guard let request else { return }
            handleMediaNavigationRequest(request)
        }
    }

    @ViewBuilder
    private var bottomChrome: some View {
        Group {
            switch effectiveChromeMode {
            case .landing:
                LandingTabBar(
                    onHelp: { isHelpPresented = true },
                    onDeveloper: { selectTab(.developer) }
                )
            case .full:
                MainTabBar(highlightedTab: highlightedTab) { tab in
                    selectTab(tab)
                }
            }
        }
        // Hug content height — otherwise VStack can give the bar a flexible
        // height proposal and the tab buttons expand to ~half the screen.
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch contentTab {
        case .media:
            NavigationStack(path: $mediaPath) {
                HomeView(vm: vm)
                    .navigationDestination(for: MediaRoute.self) { route in
                        switch route {
                        case .holidays:
                            HolidaysLandingView(vm: vm)
                        case .allMediaPhotos:
                            PictureBrowserView(
                                title: "All",
                                loadsAllPhotos: true,
                                sortOptions: [.dateTaken, .dateImported],
                                usesNavigationTitle: true,
                                enablesVideoFilter: true,
                                browseMonthScope: .allLibrary
                            )
                        }
                    }
            }
            .id(mediaStackID)
        case .events:
            NavigationStack {
                if isEventsContentReady {
                    EventsTabRoot(vm: vm)
                } else {
                    ProgressView("Loading events…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        case .developer:
            NavigationStack {
                DeveloperTabRoot(vm: vm)
            }
        case .search:
            NavigationStack {
                MediaLibrarySearchView()
            }
        }
    }

    private func selectTab(_ tab: MainTab) {
        // From All Events, Media tab should open All Media Photos (not Home).
        if tab == .media,
           contentTab == .events,
           case .allEvents = vm.eventsTabFilter {
            vm.requestNavigateToAllMediaPhotos()
            return
        }

        // Search while Media is showing All Media / topic browsers: open Pictures search
        // in place instead of the old "coming soon" Search tab placeholder.
        if tab == .search,
           contentTab == .media,
           vm.mainTabChromeMode == .full {
            vm.requestOpenMediaPhotoSearch()
            return
        }

        guard tab != highlightedTab else { return }

        // 1) Paint tab bar immediately — do not swap content in this turn.
        highlightedTab = tab

        Task { @MainActor in
            // 2) After chrome paints, swap content (may tear down All Media / build Events).
            await Task.yield()
            guard highlightedTab == tab else { return }

            isEventsContentReady = false
            contentTab = tab

            guard tab == .events else { return }

            // 3) Mount heavy Events list after the Events placeholder is on screen.
            await Task.yield()
            guard highlightedTab == .events, contentTab == .events else { return }
            isEventsContentReady = true
        }
    }

    private func handleMediaNavigationRequest(_ request: MediaNavigationRequest) {
        vm.consumeMediaNavigationRequest()
        switch request {
        case .home:
            vm.mainTabChromeMode = .landing
            highlightedTab = .media
            mediaPath = NavigationPath()
            mediaStackID = UUID()
            contentTab = .media
            isEventsContentReady = false
        case .holidaysHub:
            vm.mainTabChromeMode = .landing
            highlightedTab = .media
            mediaPath = NavigationPath()
            mediaStackID = UUID()
            contentTab = .media
            isEventsContentReady = false
            Task { @MainActor in
                await Task.yield()
                mediaPath.append(MediaRoute.holidays)
            }
        case .allMediaPhotos:
            vm.mainTabChromeMode = .full
            highlightedTab = .media
            mediaPath = NavigationPath()
            mediaStackID = UUID()
            contentTab = .media
            isEventsContentReady = false
            Task { @MainActor in
                await Task.yield()
                mediaPath.append(MediaRoute.allMediaPhotos)
            }
        }
    }
}

/// Landing hubs: Help | Developer only (Figma).
private struct LandingTabBar: View {
    var onHelp: () -> Void
    var onDeveloper: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            landingButton(title: "Help", systemImage: "questionmark.circle", action: onHelp)
            landingButton(title: "Developer", systemImage: "hammer.fill", action: onDeveloper)
        }
        .background {
            Rectangle()
                .fill(.bar)
                .ignoresSafeArea(edges: .bottom)
        }
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private func landingButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .regular))
                Text(title)
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .foregroundStyle(Color.secondary)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

private struct MainTabBar: View {
    let highlightedTab: MainTab
    var onSelect: (MainTab) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(MainTab.allCases, id: \.self) { tab in
                Button {
                    onSelect(tab)
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 22, weight: .regular))
                        Text(tab.title)
                            .font(.caption2)
                    }
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(highlightedTab == tab ? Color.accentColor : Color.secondary)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(highlightedTab == tab ? .isSelected : [])
            }
        }
        .background {
            Rectangle()
                .fill(.bar)
                .ignoresSafeArea(edges: .bottom)
        }
        .overlay(alignment: .top) {
            Divider()
        }
    }
}

/// Search tab root when not intercepting from All Media (e.g. opened from Events).
private struct MediaLibrarySearchView: View {
    @State private var resultPhotoIds: [String] = []
    @State private var resultTitle = "Search Results"
    @State private var isShowingResults = false

    var body: some View {
        MediaPhotoSearchSheet(
            showsCancelButton: false,
            embedsNavigationStack: false,
            navigationTitle: "Search Pictures",
            dismissesAfterSearch: false
        ) { _, report in
            resultPhotoIds = report.photoIds
            resultTitle = "\(report.matchCount.formatted()) match\(report.matchCount == 1 ? "" : "es")"
            isShowingResults = true
        }
        .navigationDestination(isPresented: $isShowingResults) {
            PictureBrowserView(
                title: resultTitle,
                photoIds: resultPhotoIds,
                usesNavigationTitle: true,
                enablesVideoFilter: true
            )
        }
    }
}

private struct HelpPlaceholderView: View {
    var body: some View {
        ContentUnavailableView(
            "Help",
            systemImage: "questionmark.circle",
            description: Text("Help content — coming soon.")
        )
        .navigationTitle("Help")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Observes `LibraryViewModel` only inside the Events tab, not at the tab-chrome level.
private struct EventsTabRoot: View {
    @ObservedObject var vm: LibraryViewModel

    var body: some View {
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
            EventsLibraryScreen(
                filter: .allEvents,
                vm: vm,
                onBack: { vm.requestReturnToHome() }
            )
        }
    }
}

private struct DeveloperTabRoot: View {
    @ObservedObject var vm: LibraryViewModel

    var body: some View {
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
