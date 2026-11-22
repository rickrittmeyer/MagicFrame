import SwiftUI

struct EventsLibraryView: View {

    let eventSections: [EventYearSection]
    var emptyHint: String = "No events yet."
    var isBusy: Bool = false
    var showsHiddenEvents: Bool = false
    let onEventUpdated: (Int) -> Void
    let onEventHidden: (Int) -> Void
    let onEventUnhidden: (Int) -> Void
    var scrollTarget: EventListScrollTarget? = nil
    var onScrollTargetHandled: (() -> Void)? = nil
    var isSelecting: Bool = false
    var selectedEventIds: Set<Int> = []
    var onToggleSelection: ((Int) -> Void)? = nil

    @State private var collapsedYears: Set<Int> = []
    @State private var handledScrollRequestID: UUID?

    var body: some View {
        Group {
            if isBusy {
                ContentUnavailableView {
                    ProgressView()
                } description: {
                    Text(emptyHint)
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
                        LazyVStack(spacing: 12, pinnedViews: [.sectionHeaders]) {
                            ForEach(eventSections) { section in
                                Section {
                                    if !collapsedYears.contains(section.year) {
                                        ForEach(section.items) { item in
                                            Group {
                                                if isSelecting {
                                                    Button {
                                                        onToggleSelection?(item.event.eventId)
                                                    } label: {
                                                        eventRow(item)
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
                                                        eventRow(item)
                                                    }
                                                    .buttonStyle(.plain)
                                                }
                                            }
                                            .padding(.horizontal, 16)
                                            .id(item.id)
                                        }
                                    }
                                } header: {
                                    yearBanner(section)
                                        .background(Color.clear)
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
                    .onChange(of: eventSections.map(\.id)) { _, _ in
                        scrollToTargetEvent(using: proxy)
                    }
                }
            }
        }
    }

    private func eventRow(_ item: EventListDisplayItem) -> some View {
        EventLibraryRowView(
            event: item.event,
            slideshowPhotoIds: item.slideshowPhotoIds,
            showsHiddenBadge: showsHiddenEvents,
            isSelected: selectedEventIds.contains(item.event.eventId),
            onHide: showsHiddenEvents
                ? nil
                : { onEventHidden(item.event.eventId) },
            onUnhide: showsHiddenEvents
                ? { onEventUnhidden(item.event.eventId) }
                : nil
        )
    }

    private func scrollToTargetEvent(using proxy: ScrollViewProxy) {
        guard let scrollTarget else { return }
        guard handledScrollRequestID != scrollTarget.requestID else { return }
        guard let section = eventSections.first(
            where: { $0.items.contains { $0.id == scrollTarget.eventId } }
        ) else {
            return
        }

        if collapsedYears.contains(section.year) {
            collapsedYears.remove(section.year)
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

    private func yearBanner(_ section: EventYearSection) -> some View {
        let isCollapsed = collapsedYears.contains(section.year)
        let yearLabel = section.year > 0 ? String(section.year) : "Unknown Year"
        let eventLabel = section.eventCount == 1 ? "Event" : "Events"
        let statsLine = "\(section.eventCount) \(eventLabel) • \(section.photoCount.formatted(.number.grouping(.automatic)))"

        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                if isCollapsed {
                    collapsedYears.remove(section.year)
                } else {
                    collapsedYears.insert(section.year)
                }
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
