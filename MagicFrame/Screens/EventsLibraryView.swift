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
    /// Sticky month-style headers (All Events) vs divider headers (Sport/Team, milestones).
    var usesStickyMonthHeaders: Bool = false
    @Binding var expandedYear: Int?

    @State private var handledScrollRequestID: UUID?

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
                    .onAppear {
                        scrollToTargetEvent(using: proxy)
                    }
                    .onChange(of: scrollTarget?.requestID) { _, _ in
                        scrollToTargetEvent(using: proxy)
                    }
                    .onChange(of: eventSections.count) { _, _ in
                        scrollToTargetEvent(using: proxy)
                    }
                    .onChange(of: eventSections.map(\.year)) { _, newYears in
                        if let expandedYear, !newYears.contains(expandedYear) {
                            self.expandedYear = nil
                        }
                    }
                    .onChange(of: pendingScrollSectionId) { _, sectionId in
                        guard let sectionId else { return }
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(sectionId, anchor: .top)
                        }
                        onPendingScrollHandled?()
                    }
                }
            }
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
                    monthSectionHeader(title)
                        .id(section.year)
                } else {
                    sectionDividerHeader(title)
                        .id(section.year)
                }
            }
        }
    }

    private func monthSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(.systemBackground))
            .accessibilityAddTraits(.isHeader)
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
            slideshowQuality: .high
        )
        .contentShape(Rectangle())
        .overlay(alignment: .topTrailing) {
            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .padding(20)
            }
        }
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
