import SwiftUI

/// Toolbar + year-grouped event list. Shared by full-screen collections and embedded location events.
struct EventsLibraryListContent: View {

    let filter: EventListFilter
    @ObservedObject var vm: LibraryViewModel
    var runsDateRepairOnLoad: Bool = false
    /// When false (e.g. location detail embed), keep a compact eye toggle instead of picture-style chrome.
    var showsPictureStyleHeader: Bool = true
    /// Events-tab focused collections are stack roots — provide this to show a picture-style back control.
    var onBack: (() -> Void)? = nil
    /// Landing title from the tile that opened this list (e.g. "Christmas Events").
    var landingTitle: String? = nil

    @State private var sort: EventListSort = .date
    @State private var eventBrowserFilter: EventListBrowserFilter = .allEvents
    @State private var isSelecting = false
    @State private var selectedEventIds: Set<Int> = []
    @State private var focusedYear: Int?
    @State private var pendingScrollSectionId: Int?
    /// Blocks preference-driven month memory until the shared Photos↔Events anchor is applied.
    /// Otherwise the list paints at the newest month and overwrites Media’s saved position.
    @State private var hasAppliedBrowseMonthRestore = false
    /// Filter for which the initial list load + month restore already finished.
    /// `.task` restarts when popping back from Event Detail — skip reload so scroll offset stays exact.
    @State private var loadedFilter: EventListFilter?
    /// Avoid rebuilding month sections on every `focusedYear` tap — that blocked chip highlight for 1–2s.
    @State private var cachedDisplayedSections: [EventYearSection] = []
    @State private var cachedAvailableYears: [Int] = []

    private var usesAllMediaChrome: Bool { showsPictureStyleHeader }

    /// Shared with paired Photos browsers (All Media ↔ All Events, topic ↔ topic).
    private var browseMonthScope: BrowseMonthScope {
        if filter == .allEvents {
            return .allLibrary
        }
        return .eventsFilter(filter)
    }

    private var baseTitle: String {
        landingTitle ?? filter.navigationTitle
    }

    private var headerTitle: String {
        guard usesAllMediaChrome else { return baseTitle }
        guard eventBrowserFilter != .allEvents else { return baseTitle }
        return "\(baseTitle) \(eventBrowserFilter.title)"
    }

    private var filteredItems: [EventListDisplayItem] {
        vm.eventSections.flatMap(\.items).filter(matchesActiveFilter)
    }

    /// Rebuild month layout only when event membership / filters change — not on slideshow enrichment.
    private var layoutCacheToken: Int {
        var hasher = Hasher()
        hasher.combine(sectionCacheFilterKey)
        hasher.combine(sort.rawValue)
        hasher.combine(eventBrowserFilter.rawValue)
        hasher.combine(vm.showHiddenEvents)
        hasher.combine(usesAllMediaChrome)
        hasher.combine(vm.eventSections.count)
        for section in vm.eventSections {
            hasher.combine(section.year)
            hasher.combine(section.items.count)
            for item in section.items {
                hasher.combine(item.id)
            }
        }
        return hasher.finalize()
    }

    /// Slideshow / game fields update after first paint; patch cache without rebuilding months.
    private var enrichmentCacheToken: Int {
        var hasher = Hasher()
        for section in vm.eventSections {
            for item in section.items {
                hasher.combine(item.id)
                hasher.combine(item.slideshowPhotoIds)
                hasher.combine(item.onFrameVideoId)
                hasher.combine(item.gameSuggestedName)
                hasher.combine(item.hasOnFramePhotos)
                hasher.combine(item.gameCoverScoreBoard != nil)
            }
        }
        return hasher.finalize()
    }

    private var sectionCacheFilterKey: String {
        switch filter {
        case .allEvents: return "allEvents"
        case .anyHoliday: return "anyHoliday"
        case .holidayTag(let value): return "holidayTag:\(value)"
        case .anyMilestone: return "anyMilestone"
        case .milestoneTag(let value): return "milestoneTag:\(value)"
        case .milestoneTags(let values): return "milestoneTags:\(values.joined(separator: ","))"
        case .anyBirthdayMilestone: return "anyBirthdayMilestone"
        case .trips: return "trips"
        case .anyActivity: return "anyActivity"
        case .activityTag(let value): return "activityTag:\(value)"
        case .eventTypeTag(let value): return "eventTypeTag:\(value)"
        case .eventTypeTags(let values): return "eventTypeTags:\(values.joined(separator: ","))"
        case .birthdayPerson(let personId, _): return "birthdayPerson:\(personId)"
        case .location(let locationId, _): return "location:\(locationId)"
        }
    }

    private func rebuildSectionCache() {
        let items = filteredItems
        let sections: [EventYearSection]
        if usesAllMediaChrome {
            switch sort {
            case .sport, .team:
                sections = groupedSections(from: items, sort: sort)
            case .date, .confidence:
                sections = Self.monthSections(from: sortedItems(items))
            }
        } else {
            sections = legacySections(from: items)
        }
        cachedDisplayedSections = sections

        guard usesAllMediaChrome else {
            cachedAvailableYears = []
            return
        }
        var years: [Int] = []
        var seen = Set<Int>()
        for item in items {
            guard let year = item.event.eventYear, seen.insert(year).inserted else { continue }
            years.append(year)
        }
        cachedAvailableYears = years.sorted(by: >)
        patchCachedEnrichmentFromViewModel()
    }

    /// Copy slideshow / game enrichment into the month cache without regrouping events.
    private func patchCachedEnrichmentFromViewModel() {
        guard !cachedDisplayedSections.isEmpty else { return }

        var byId: [Int: EventListDisplayItem] = [:]
        byId.reserveCapacity(vm.eventSections.reduce(0) { $0 + $1.items.count })
        for section in vm.eventSections {
            for item in section.items {
                byId[item.id] = item
            }
        }

        var anyChange = false
        let updated = cachedDisplayedSections.map { section in
            var sectionChanged = false
            let items = section.items.map { item -> EventListDisplayItem in
                guard let source = byId[item.id] else { return item }
                if item.slideshowPhotoIds == source.slideshowPhotoIds,
                   item.onFrameVideoId == source.onFrameVideoId,
                   item.gameSuggestedName == source.gameSuggestedName,
                   item.gameCoverScoreBoard == source.gameCoverScoreBoard,
                   item.hasOnFramePhotos == source.hasOnFramePhotos,
                   item.gameLeague == source.gameLeague,
                   item.gameTeamSortKey == source.gameTeamSortKey {
                    return item
                }
                sectionChanged = true
                return EventListDisplayItem(
                    event: item.event,
                    slideshowPhotoIds: source.slideshowPhotoIds,
                    hasOnFramePhotos: source.hasOnFramePhotos,
                    onFrameVideoId: source.onFrameVideoId,
                    gameCoverScoreBoard: source.gameCoverScoreBoard,
                    gameSuggestedName: source.gameSuggestedName,
                    gameLeague: source.gameLeague,
                    gameTeamSortKey: source.gameTeamSortKey
                )
            }
            guard sectionChanged else { return section }
            anyChange = true
            return EventYearSection(
                year: section.year,
                items: items,
                presentation: section.presentation,
                headerTitle: section.headerTitle
            )
        }
        if anyChange {
            cachedDisplayedSections = updated
        }
    }

    private func legacySections(from items: [EventListDisplayItem]) -> [EventYearSection] {
        switch sort {
        case .sport, .team:
            return groupedSections(from: items, sort: sort)
        case .date, .confidence:
            let grouped = Dictionary(grouping: items) { $0.event.eventYear ?? 0 }
            return grouped.keys.sorted(by: >).map { year in
                EventYearSection(
                    year: year,
                    items: sortedItems(grouped[year, default: []]),
                    presentation: .yearAccordion
                )
            }
        }
    }

    private var visibleEventCount: Int {
        cachedDisplayedSections.reduce(0) { $0 + $1.eventCount }
    }

    private var emptyHint: String {
        if eventBrowserFilter != .allEvents {
            return "No events match the current filter."
        }
        if vm.showHiddenEvents {
            return "No hidden events."
        }
        return filter.emptyHint
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsPictureStyleHeader {
                allMediaIconBar
                if showsYearJumpBar {
                    yearJumpBar
                }
            } else {
                compactHiddenToggle
            }

            EventsLibraryView(
                eventSections: cachedDisplayedSections,
                listFilter: filter,
                emptyHint: emptyHint,
                isBusy: vm.showsEventsLoadingPlaceholder,
                isSelecting: isSelecting,
                selectedEventIds: selectedEventIds,
                onToggleSelection: { eventId in
                    toggleSelection(eventId: eventId)
                },
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
                onExpandedYearChanged: { year in
                    if vm.activeHolidayVisionConfig != nil {
                        vm.handleHolidayYearExpanded(year)
                    } else {
                        vm.loadSlideshowPhotosForYear(year)
                    }
                },
                pendingScrollSectionId: pendingScrollSectionId,
                onPendingScrollHandled: {
                    pendingScrollSectionId = nil
                },
                onVisibleYearChanged: { year in
                    guard showsYearJumpBar, hasAppliedBrowseMonthRestore else { return }
                    guard focusedYear != year else { return }
                    focusedYear = year
                },
                onVisibleMonthChanged: { yyyymm in
                    guard showsYearJumpBar, hasAppliedBrowseMonthRestore else { return }
                    vm.rememberBrowseMonth(yyyymm: yyyymm, scope: browseMonthScope)
                },
                usesStickyMonthHeaders: usesAllMediaChrome && (sort == .date || sort == .confidence),
                expandedYear: $vm.expandedListYear
            )
            .frame(maxHeight: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isSelecting {
                selectionBar
            }
        }
        .onAppear {
            vm.setMainTabChromeMode(.full)
        }
        .modifier(EventsLibraryNavigationTitle(
            isEnabled: usesAllMediaChrome,
            title: headerTitle
        ))
        .toolbar {
            if let onBack, showsPictureStyleHeader, !isSelecting {
                ToolbarItem(placement: .topBarLeading) {
                    EventsTabBackButton(action: onBack)
                }
            }
        }
        .onChange(of: filter) { _, _ in
            if !availableSortOptions.contains(sort) {
                sort = .date
            }
        }
        .onChange(of: layoutCacheToken) { _, _ in
            rebuildSectionCache()
        }
        .onChange(of: enrichmentCacheToken) { _, _ in
            patchCachedEnrichmentFromViewModel()
        }
        .onChange(of: cachedAvailableYears) { _, years in
            if let focusedYear, years.contains(focusedYear) { return }
            if let anchor = vm.browseMonthAnchor(for: browseMonthScope),
               years.contains(anchor.year) {
                focusedYear = anchor.year
                return
            }
            focusedYear = years.first
        }
        .onAppear {
            if cachedDisplayedSections.isEmpty {
                rebuildSectionCache()
            }
        }
        .task(id: filter) {
            // Yield so tab selection / first chrome can paint before list load work.
            await Task.yield()
            guard !Task.isCancelled else { return }

            // NavigationLink push cancels this task; pop restarts it. Don't reload or
            // re-apply month restore — that snaps to the month header and loses the row offset.
            if loadedFilter == filter {
                return
            }

            cancelSelection()
            eventBrowserFilter = .allEvents
            sort = .date
            focusedYear = nil
            pendingScrollSectionId = nil
            hasAppliedBrowseMonthRestore = false
            if usesAllMediaChrome, vm.showHiddenEvents {
                vm.showHiddenEvents = false
            }
            vm.beginEventListLoad(for: filter)

            // Pushed screens: let the navigation animation finish before database work.
            // All Events is the Events tab root — no push delay.
            if filter != .allEvents {
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled else { return }
            }

            // Month layout landings load previews with the list (no year accordion expand).
            await vm.reloadEventsAsync(
                filter: filter,
                loadSlideshowIds: usesAllMediaChrome
            )
            guard !Task.isCancelled else { return }
            rebuildSectionCache()
            applyRestoredMonthAnchor()
            loadedFilter = filter

            if runsDateRepairOnLoad {
                vm.scheduleEventDateRepairIfNeeded()
            }
        }
        .onAppear {
            if usesAllMediaChrome { return }
            vm.reloadSlideshowPhotosForExpandedYearIfNeeded()
        }
        .onDisappear {
            if vm.activeHolidayVisionConfig != nil {
                vm.cancelHolidayLandingVisionScans()
            }
        }
        .sheet(item: $vm.pendingWeddingCoupleConfirm, onDismiss: {
            vm.pendingWeddingCoupleConfirm = nil
        }) { request in
            CoupleMilestonePickerSheet(
                kind: .wedding,
                items: request.people,
                defaultWeddingDate: EventDateParser.eventDayDate(from: request.event.startDate)
                    ?? Date(),
                onComplete: { bride, groom, weddingDate in
                    guard let groom else { return }
                    vm.completeWeddingCoupleConfirm(
                        displayEventId: request.displayEventId,
                        bride: bride,
                        groom: groom,
                        weddingDate: weddingDate
                    )
                }
            )
        }
        .sheet(item: $vm.pendingSimilarEventAlternatives, onDismiss: {
            vm.pendingSimilarEventAlternatives = nil
        }) { request in
            SimilarEventAlternativesSheet(
                rejectedTagValue: request.rejectedTag.tagValue,
                alternatives: request.alternatives,
                onSelect: { alternative in
                    vm.applySimilarEventAlternative(
                        displayEventId: request.displayEventId,
                        alternative: alternative
                    )
                },
                onSkip: {
                    vm.pendingSimilarEventAlternatives = nil
                }
            )
        }
        .sheet(item: $vm.pendingSimilarEventPeoplePick, onDismiss: {
            vm.pendingSimilarEventPeoplePick = nil
        }) { request in
            let personCount = max(1, min(2, request.alternative.possibleNumberOfEventMainPeople))
            CoupleMilestonePickerSheet(
                copy: .forSimilarEvent(
                    tagValue: request.alternative.possibleTagValue,
                    personCount: personCount
                ),
                personCount: personCount,
                items: request.people,
                defaultWeddingDate: EventDateParser.eventDayDate(from: request.event.startDate)
                    ?? Date(),
                includesWeddingDateStep: false,
                onComplete: { person1, person2, _ in
                    vm.completeSimilarEventPeoplePick(
                        displayEventId: request.displayEventId,
                        person1: person1,
                        person2: person2
                    )
                }
            )
        }
    }

    private var availableSortOptions: [EventListSort] {
        EventListSort.options(for: filter)
    }

    private var showsYearJumpBar: Bool {
        usesAllMediaChrome
            && (sort == .date || sort == .confidence)
            && !cachedAvailableYears.isEmpty
    }

    private var allMediaIconBar: some View {
        HStack(spacing: 12) {
            if isSelecting {
                selectionStatus
            } else {
                if !vm.showsEventsLoadingPlaceholder || visibleEventCount > 0 {
                    Text(eventCountText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if availableSortOptions.count > 1 {
                    sortMenu
                }
                allMediaFilterMenu
                selectButton
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var yearJumpBar: some View {
        ScrollViewReader { yearProxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(cachedAvailableYears, id: \.self) { year in
                        let isFocused = focusedYear == year
                        Button {
                            jumpToYear(year)
                        } label: {
                            Text(String(year))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(isFocused ? Color(.systemBackground) : .primary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    isFocused ? Color.accentColor : Color(.secondarySystemFill),
                                    in: RoundedRectangle(cornerRadius: 8)
                                )
                        }
                        .buttonStyle(.plain)
                        .id(year)
                        .accessibilityLabel("Jump to \(year)")
                        .accessibilityAddTraits(isFocused ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(.bar)
            .onChange(of: focusedYear) { _, year in
                guard let year else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    yearProxy.scrollTo(year, anchor: .center)
                }
            }
        }
    }

    private func jumpToYear(_ year: Int) {
        // Only mutate highlight state here — any section rebuild in this handler
        // delayed the chip by 1–2s on large libraries.
        focusedYear = year
        Task { @MainActor in
            // Month section ids are YYYYMM; pick the first (newest) month for that year.
            guard let sectionId = cachedDisplayedSections.first(where: { $0.year / 100 == year })?.year else {
                return
            }
            pendingScrollSectionId = sectionId
            vm.rememberBrowseMonth(yyyymm: sectionId, scope: browseMonthScope)
        }
    }

    /// Restore remembered month (or fall back to newest year) after sections load.
    private func applyRestoredMonthAnchor() {
        defer { hasAppliedBrowseMonthRestore = true }
        if let anchor = vm.browseMonthAnchor(for: browseMonthScope) {
            focusedYear = anchor.year
            if cachedDisplayedSections.contains(where: { $0.year == anchor.yyyymm }) {
                pendingScrollSectionId = anchor.yyyymm
                return
            }
            if let fallback = cachedDisplayedSections.first(where: { $0.year / 100 == anchor.year })?.year {
                pendingScrollSectionId = fallback
                return
            }
        }
        focusedYear = cachedAvailableYears.first
    }

    private var selectionStatus: some View {
        Group {
            Button("Cancel") {
                cancelSelection()
            }
            .font(.body.weight(.medium))

            Spacer(minLength: 8)

            Text("\(selectedEventIds.count) selected")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var eventCountText: String {
        let count = visibleEventCount
        return "\(count.formatted()) \(count == 1 ? "event" : "events")"
    }

    private var sortMenu: some View {
        Menu {
            ForEach(availableSortOptions) { option in
                Button {
                    sort = option
                } label: {
                    if sort == option {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.body.weight(.semibold))
                .frame(width: 32, height: 32)
        }
        .accessibilityLabel("Sort")
    }

    private var allMediaFilterMenu: some View {
        Menu {
            ForEach(EventListBrowserFilter.allCases) { option in
                Button {
                    applyEventBrowserFilter(option)
                } label: {
                    if eventBrowserFilter == option {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
            }
        } label: {
            Image(
                systemName: eventBrowserFilter == .allEvents
                    ? "line.3.horizontal.decrease"
                    : "line.3.horizontal.decrease.circle.fill"
            )
            .font(.body.weight(.semibold))
            .frame(width: 32, height: 32)
        }
        .accessibilityLabel("Filter")
    }

    private var selectButton: some View {
        Button {
            beginSelection()
        } label: {
            Image(systemName: "checkmark.circle")
                .font(.body.weight(.semibold))
                .frame(width: 32, height: 32)
        }
        .accessibilityLabel("Select")
    }

    private var compactHiddenToggle: some View {
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
        .padding(.vertical, 8)
    }

    private var selectionBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Button("Favorite") {
                    vm.setEventsFavorite(eventIds: selectedEventIds, isFavorite: true)
                    cancelSelection()
                }
                .buttonStyle(.bordered)
                .disabled(selectedEventIds.isEmpty)

                Button("Unfavorite") {
                    vm.setEventsFavorite(eventIds: selectedEventIds, isFavorite: false)
                    cancelSelection()
                }
                .buttonStyle(.bordered)
                .disabled(selectedEventIds.isEmpty)

                Button("Hide", role: .destructive) {
                    vm.setEventsHidden(eventIds: selectedEventIds, hidden: true)
                    cancelSelection()
                }
                .buttonStyle(.bordered)
                .disabled(selectedEventIds.isEmpty)

                Button("Unhide") {
                    vm.setEventsHidden(eventIds: selectedEventIds, hidden: false)
                    cancelSelection()
                }
                .buttonStyle(.bordered)
                .disabled(selectedEventIds.isEmpty)

                Button("Merge Events (Coming soon)") {}
                    .buttonStyle(.bordered)
                    .disabled(true)
            }
            .font(.subheadline)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.bar)
    }

    private func beginSelection() {
        isSelecting = true
        selectedEventIds = []
    }

    private func cancelSelection() {
        isSelecting = false
        selectedEventIds = []
    }

    private func toggleSelection(eventId: Int) {
        if selectedEventIds.contains(eventId) {
            selectedEventIds.remove(eventId)
        } else {
            selectedEventIds.insert(eventId)
        }
    }

    private func matchesActiveFilter(_ item: EventListDisplayItem) -> Bool {
        guard usesAllMediaChrome else { return true }
        return matchesEventBrowserFilter(item)
    }

    private func matchesEventBrowserFilter(_ item: EventListDisplayItem) -> Bool {
        switch eventBrowserFilter {
        case .allEvents, .hiddenEvents:
            return true
        case .favoriteEvents:
            return item.event.isFavorite
        case .eventsOnFrame:
            return item.hasOnFramePhotos
        case .eventsOffFrame:
            return !item.hasOnFramePhotos
        }
    }

    private func applyEventBrowserFilter(_ option: EventListBrowserFilter) {
        cancelSelection()
        let wantsHidden = option == .hiddenEvents
        Task {
            // Load on-frame flags BEFORE applying the filter. Otherwise the layout
            // cache rebuilds with all hasOnFramePhotos=false (On Frame → empty),
            // and later flag merges have nothing to patch.
            if option == .eventsOnFrame || option == .eventsOffFrame {
                await vm.ensureOnFrameEventFlagsLoaded()
            }

            if vm.showHiddenEvents != wantsHidden {
                vm.showHiddenEvents = wantsHidden
                eventBrowserFilter = option
                await vm.reloadEventsAsync(filter: filter, loadSlideshowIds: true)
                if option == .eventsOnFrame || option == .eventsOffFrame {
                    await vm.ensureOnFrameEventFlagsLoaded()
                }
            } else {
                eventBrowserFilter = option
            }
        }
    }

    private func sortedItems(_ items: [EventListDisplayItem]) -> [EventListDisplayItem] {
        switch sort {
        case .confidence:
            return items.sorted { lhs, rhs in
                let left = confidenceScore(for: lhs)
                let right = confidenceScore(for: rhs)
                if left != right {
                    return left > right
                }
                if lhs.event.startDate != rhs.event.startDate {
                    return lhs.event.startDate > rhs.event.startDate
                }
                return lhs.event.eventId > rhs.event.eventId
            }
        case .date, .sport, .team:
            return items.sorted {
                if $0.event.startDate != $1.event.startDate {
                    return $0.event.startDate > $1.event.startDate
                }
                return $0.event.eventId > $1.event.eventId
            }
        }
    }

    private func confidenceScore(for item: EventListDisplayItem) -> Double {
        item.event.attributeTags.compactMap(\.totalScore).max() ?? -1
    }

    /// Month sections newest-first. Section id is YYYYMM (e.g. 202611) for scroll targets.
    private static func monthSections(from items: [EventListDisplayItem]) -> [EventYearSection] {
        var order: [Int] = []
        var buckets: [Int: [EventListDisplayItem]] = [:]

        for item in items {
            let key = monthSectionId(from: item.event.startDate)
            if buckets[key] == nil {
                order.append(key)
                buckets[key] = []
            }
            buckets[key, default: []].append(item)
        }

        return order.map { key in
            EventYearSection(
                year: key,
                items: buckets[key] ?? [],
                presentation: .flatAlwaysVisible,
                headerTitle: monthTitle(for: key)
            )
        }
    }

    private static func monthSectionId(from startDate: String) -> Int {
        let trimmed = startDate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 7 else { return 0 }
        let key = String(trimmed.prefix(7))
        guard key.count == 7,
              key[key.index(key.startIndex, offsetBy: 4)] == "-",
              let year = Int(key.prefix(4)),
              let month = Int(key.suffix(2)),
              (1...12).contains(month) else {
            return 0
        }
        return year * 100 + month
    }

    private static func monthTitle(for sectionId: Int) -> String {
        guard sectionId >= 10_000 else { return "Unknown Date" }
        let year = sectionId / 100
        let month = sectionId % 100
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = 1
        guard let date = Calendar(identifier: .gregorian).date(from: components) else {
            return "Unknown Date"
        }
        return monthTitleFormatter.string(from: date)
    }

    private static let monthTitleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "MMMM yyyy"
        return formatter
    }()

    /// Flat Sport / Team groups with a simple divider header between each group.
    private func groupedSections(
        from items: [EventListDisplayItem],
        sort: EventListSort
    ) -> [EventYearSection] {
        let otherTitle = sort == .sport ? "Other" : "Other Teams"
        let grouped = Dictionary(grouping: items) { item -> String in
            switch sort {
            case .sport:
                return item.gameLeague?.displayName ?? otherTitle
            case .team:
                return teamGroupTitle(for: item) ?? otherTitle
            case .date, .confidence:
                return otherTitle
            }
        }

        let titles = grouped.keys.sorted { lhs, rhs in
            if lhs == otherTitle { return false }
            if rhs == otherTitle { return true }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }

        let namespace = sort == .sport ? -2_100_000 : -2_200_000
        return titles.enumerated().map { index, title in
            EventYearSection(
                year: namespace - index,
                items: sortedItems(grouped[title, default: []]),
                presentation: .flatAlwaysVisible,
                headerTitle: title
            )
        }
    }

    /// Home-team label for Team sections (falls back to either side of the matchup).
    private func teamGroupTitle(for item: EventListDisplayItem) -> String? {
        if let home = item.gameCoverScoreBoard?.homeTeam,
           !home.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return home
        }
        if let parts = item.gameTeamSortKey?.split(separator: "\t"),
           let first = parts.first,
           !first.isEmpty {
            return String(first)
        }
        return nil
    }

}

struct EventsLibraryScreen: View {

    let filter: EventListFilter
    @ObservedObject var vm: LibraryViewModel
    var landingTitle: String? = nil
    var onBack: (() -> Void)? = nil

    private var resolvedLandingTitle: String {
        if let landingTitle { return landingTitle }
        if filter == .allEvents { return filter.navigationTitle }
        return "\(filter.navigationTitle) Events"
    }

    var body: some View {
        EventsLibraryListContent(
            filter: filter,
            vm: vm,
            runsDateRepairOnLoad: filter == .allEvents,
            onBack: onBack,
            landingTitle: resolvedLandingTitle
        )
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct EventsLibraryNavigationTitle: ViewModifier {
    let isEnabled: Bool
    let title: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
        } else {
            content
        }
    }
}

/// Circular chevron used when an Events-tab collection is a navigation-stack root.
struct EventsTabBackButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 32)
                .background {
                    Circle()
                        .fill(Color(.systemBackground))
                        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                }
        }
        .accessibilityLabel("Back")
    }
}
