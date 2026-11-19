import SwiftUI

struct EventsLibraryView: View {

    let eventSections: [EventYearSection]
    var listFilter: EventListFilter = .allEvents
    var emptyHint: String = "No events yet."
    var isBusy: Bool = false
    var isSelecting: Bool = false
    var selectedEventIds: Set<Int> = []
    var onToggleSelection: ((Int) -> Void)? = nil
    let onEventUpdated: (Int) -> Void
    let onEventHidden: (Int) -> Void
    let onEventUnhidden: (Int) -> Void
    var scrollTarget: EventListScrollTarget? = nil
    var onScrollTargetHandled: (() -> Void)? = nil
    var onExpandedYearChanged: ((Int) -> Void)? = nil
    /// When set, scrolls to the section whose `year` id matches (month sections use YYYYMM).
    var pendingScrollSectionId: Int? = nil
    var onPendingScrollHandled: (() -> Void)? = nil
    /// Called when sticky month headers indicate a new calendar year while scrolling (All Media–style chip sync).
    var onVisibleYearChanged: ((Int) -> Void)? = nil
    /// Called with `YYYYMM` when the pinned month section changes while scrolling.
    var onVisibleMonthChanged: ((Int) -> Void)? = nil
    /// Sticky month-style headers (All Events) vs divider headers (Sport/Team, milestones).
    var usesStickyMonthHeaders: Bool = false
    @Binding var expandedYear: Int?

    @State private var handledScrollRequestID: UUID?
    /// Fast covers while scrolling; upgrade to high after idle so list stays sharp without thrash.
    @State private var listThumbnailQuality: PhotoThumbnailView.Quality = .fast
    @State private var scrollIdleUpgradeTask: Task<Void, Never>?
    @StateObject private var videoPlayback = EventListVideoPlaybackController()

    private var allowsInlineVideoPlayback: Bool {
        listThumbnailQuality == .high && !isSelecting
    }

    var body: some View {
        Group {
            if isBusy {
                ContentUnavailableView {
                    ProgressView()
                } description: {
                    Text("Loading events…")
                }
                .frame(maxHeight: .infinity)
            } else if eventSections.isEmpty {
                ContentUnavailableView(
                    "No Events",
                    systemImage: "calendar",
                    description: Text(emptyHint)
                )
                .frame(maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0, pinnedViews: usesStickyMonthHeaders ? [.sectionHeaders] : []) {
                            ForEach(eventSections) { section in
                                switch section.presentation {
                                case .yearAccordion:
                                    yearAccordionSection(section)
                                case .flatAlwaysVisible:
                                    flatSection(section)
                                }
                            }
                        }
                        .padding(.bottom, 16)
                    }
                    .coordinateSpace(name: Self.scrollCoordinateSpaceName)
                    .onPreferenceChange(EventsLibraryVisibleYearKey.self) { frames in
                        guard usesStickyMonthHeaders, pendingScrollSectionId == nil else { return }
                        guard let visible = Self.focusedVisibleMonth(from: frames) else { return }
                        onVisibleYearChanged?(visible.year)
                        onVisibleMonthChanged?(visible.yyyymm)
                    }
                    .environmentObject(videoPlayback)
                    .onScrollPhaseChange { _, newPhase in
                        handleScrollPhase(newPhase)
                    }
                    .onAppear {
                        scrollToTargetEvent(using: proxy)
                        // onChange does not fire when the list first mounts with pending already set
                        // (Media→Events restore after loading placeholder).
                        consumePendingSectionScroll(using: proxy)
                        scheduleHighQualityUpgrade()
                        updateVideoPlaybackAllowance()
                    }
                    .onDisappear {
                        scrollIdleUpgradeTask?.cancel()
                        scrollIdleUpgradeTask = nil
                        videoPlayback.clear()
                    }
                    .onChange(of: isSelecting) { _, _ in
                        updateVideoPlaybackAllowance()
                    }
                    .onChange(of: listThumbnailQuality) { _, _ in
                        updateVideoPlaybackAllowance()
                    }
                    .onChange(of: scrollTarget?.requestID) { _, _ in
                        scrollToTargetEvent(using: proxy)
                    }
                    .onChange(of: eventSections.count) { _, _ in
                        scrollToTargetEvent(using: proxy)
                        consumePendingSectionScroll(using: proxy)
                    }
                    .onChange(of: eventSections.map(\.year)) { _, newYears in
                        if let expandedYear, !newYears.contains(expandedYear) {
                            self.expandedYear = nil
                        }
                        consumePendingSectionScroll(using: proxy)
                    }
                    .onChange(of: pendingScrollSectionId) { _, sectionId in
                        guard sectionId != nil else { return }
                        consumePendingSectionScroll(using: proxy)
                    }
                }
            }
        }
    }

    private func handleScrollPhase(_ phase: ScrollPhase) {
        switch phase {
        case .idle:
            scheduleHighQualityUpgrade()
        case .interacting, .decelerating, .animating:
            scrollIdleUpgradeTask?.cancel()
            scrollIdleUpgradeTask = nil
            if listThumbnailQuality != .fast {
                listThumbnailQuality = .fast
            }
            updateVideoPlaybackAllowance()
        @unknown default:
            break
        }
    }

    private func scheduleHighQualityUpgrade() {
        scrollIdleUpgradeTask?.cancel()
        scrollIdleUpgradeTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            listThumbnailQuality = .high
            updateVideoPlaybackAllowance()
        }
    }

    private func updateVideoPlaybackAllowance() {
        videoPlayback.setPlaybackAllowed(allowsInlineVideoPlayback)
    }

    /// Honor `pendingScrollSectionId` from appear / section updates / onChange.
    private func consumePendingSectionScroll(using proxy: ScrollViewProxy) {
        guard let sectionId = pendingScrollSectionId else { return }
        jumpToSectionInstant(sectionId, using: proxy) {
            onPendingScrollHandled?()
        }
    }

    /// Snap to a month/year section with no animation so year jumps don’t glide through months.
    /// Keeps `pendingScrollSectionId` set until the retry finishes so preference updates
    /// don’t treat the pre-scroll (newest) month as the visible anchor.
    private func jumpToSectionInstant(
        _ sectionId: Int,
        using proxy: ScrollViewProxy,
        onFinished: (() -> Void)? = nil
    ) {
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            proxy.scrollTo(sectionId, anchor: .top)
        }
        // LazyVStack may not have mounted the target yet — one unanimated retry.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            var retry = Transaction()
            retry.animation = nil
            withTransaction(retry) {
                proxy.scrollTo(sectionId, anchor: .top)
            }
            // Second beat for deep months that mount after the first retry.
            try? await Task.sleep(for: .milliseconds(120))
            var retry2 = Transaction()
            retry2.animation = nil
            withTransaction(retry2) {
                proxy.scrollTo(sectionId, anchor: .top)
            }
            onFinished?()
        }
    }

    @ViewBuilder
    private func yearAccordionSection(_ section: EventYearSection) -> some View {
        VStack(spacing: 12) {
            yearBanner(section)
                .id(section.year)

            if expandedYear == section.year {
                eventRows(for: section)
            }
        }
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func flatSection(_ section: EventYearSection) -> some View {
        Section {
            VStack(spacing: 12) {
                eventRows(for: section)
            }
            .padding(.bottom, 4)
        } header: {
            if let title = section.headerTitle {
                if usesStickyMonthHeaders {
                    monthSectionHeader(title, sectionId: section.year)
                        .id(section.year)
                } else {
                    sectionDividerHeader(title)
                        .id(section.year)
                }
            }
        }
    }

    private func monthSectionHeader(_ title: String, sectionId: Int) -> some View {
        Text(title)
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(.systemBackground))
            .accessibilityAddTraits(.isHeader)
            .background {
                if let year = Self.calendarYear(fromSectionId: sectionId) {
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: EventsLibraryVisibleYearKey.self,
                            value: [
                                EventsLibraryVisibleYear(
                                    year: year,
                                    yyyymm: sectionId >= 10_000 ? sectionId : year * 100 + 1,
                                    minY: geo.frame(in: .named(Self.scrollCoordinateSpaceName)).minY
                                ),
                            ]
                        )
                    }
                }
            }
    }

    private static let scrollCoordinateSpaceName = "eventsLibraryScroll"

    /// Month header currently pinned / nearest the top of the scroll view.
    private static func focusedVisibleMonth(
        from frames: [EventsLibraryVisibleYear]
    ) -> EventsLibraryVisibleYear? {
        guard !frames.isEmpty else { return nil }
        let threshold: CGFloat = 8
        let scrolledPast = frames.filter { $0.minY <= threshold }
        if let active = scrolledPast.max(by: { $0.minY < $1.minY }) {
            return active
        }
        return frames.min(by: { $0.minY < $1.minY })
    }

    /// Month section ids are YYYYMM (e.g. 202611); calendar year is the high digits.
    private static func calendarYear(fromSectionId sectionId: Int) -> Int? {
        let year = sectionId >= 10_000 ? sectionId / 100 : sectionId
        return year >= 1000 ? year : nil
    }

    @ViewBuilder
    private func eventRows(for section: EventYearSection) -> some View {
        ForEach(section.items) { item in
            let isSelected = selectedEventIds.contains(item.id)

            Group {
                if isSelecting {
                    Button {
                        onToggleSelection?(item.id)
                    } label: {
                        eventRowLabel(item: item, isSelected: isSelected)
                    }
                    .buttonStyle(.plain)
                } else {
                    NavigationLink {
                        EventDetailView(
                            event: item.event,
                            onEventUpdated: onEventUpdated,
                            onEventHidden: onEventHidden,
                            onEventUnhidden: onEventUnhidden
                        )
                    } label: {
                        eventRowLabel(item: item, isSelected: false)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .id(item.id)
        }
    }

    private func eventRowLabel(item: EventListDisplayItem, isSelected: Bool) -> some View {
        EventLibraryRowView(
            event: item.event,
            slideshowPhotoIds: item.slideshowPhotoIds,
            gameCoverScoreBoard: item.gameCoverScoreBoard,
            gameSuggestedName: item.gameSuggestedName,
            slideshowQuality: listThumbnailQuality,
            isSelecting: isSelecting,
            isSelected: isSelected,
            onFrameVideoId: item.onFrameVideoId,
            allowsInlineVideoPlayback: allowsInlineVideoPlayback
        )
        .contentShape(Rectangle())
        .opacity(isSelecting && !isSelected ? 0.85 : 1)
    }

    private func scrollToTargetEvent(using proxy: ScrollViewProxy) {
        guard let scrollTarget else { return }
        guard handledScrollRequestID != scrollTarget.requestID else { return }
        guard let section = eventSections.first(
            where: { $0.items.contains { $0.id == scrollTarget.eventId } }
        ) else {
            return
        }

        if section.presentation == .yearAccordion, expandedYear != section.year {
            expandedYear = section.year
            onExpandedYearChanged?(section.year)
        }

        let eventId = scrollTarget.eventId
        let requestID = scrollTarget.requestID

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard self.scrollTarget?.requestID == requestID else { return }

            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(eventId, anchor: .top)
            }
            handledScrollRequestID = requestID
            onScrollTargetHandled?()
        }
    }

    private func sectionDividerHeader(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)

            Divider()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 4)
        .accessibilityAddTraits(.isHeader)
    }

    private func yearBanner(_ section: EventYearSection) -> some View {
        let isCollapsed = expandedYear != section.year
        let yearLabel = section.year > 0 ? String(section.year) : "Unknown Year"
        let eventLabel = section.eventCount == 1 ? "Event" : "Events"
        let statsLine = "\(section.eventCount) \(eventLabel) • \(section.photoCount.formatted(.number.grouping(.automatic)))"

        return Button {
            if isCollapsed {
                expandedYear = section.year
                onExpandedYearChanged?(section.year)
            } else {
                expandedYear = nil
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 4) {
                    Text(yearLabel)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.primary)

                    Text(statsLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .padding(.horizontal, 20)

                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(14)
                    .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                    .animation(.easeInOut(duration: 0.2), value: isCollapsed)
            }
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .accessibilityLabel(yearLabel)
        .accessibilityValue("\(statsLine). \(isCollapsed ? "Collapsed" : "Expanded")")
        .accessibilityHint(isCollapsed ? "Expand events for this year" : "Collapse events for this year")
    }
}

/// Month-section header frame used to drive year-chip highlighting while scrolling.
private struct EventsLibraryVisibleYear: Equatable {
    let year: Int
    let yyyymm: Int
    let minY: CGFloat
}

private struct EventsLibraryVisibleYearKey: PreferenceKey {
    static var defaultValue: [EventsLibraryVisibleYear] = []

    static func reduce(
        value: inout [EventsLibraryVisibleYear],
        nextValue: () -> [EventsLibraryVisibleYear]
    ) {
        value.append(contentsOf: nextValue())
    }
}
