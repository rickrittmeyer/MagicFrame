import SwiftUI

struct EventsLibraryView: View {

    let eventSections: [EventYearSection]
    var listFilter: EventListFilter = .allEvents
    var emptyHint: String = "No events yet."
    var isBusy: Bool = false
    var showsHiddenEvents: Bool = false
    let onEventUpdated: (Int) -> Void
    let onEventHidden: (Int) -> Void
    let onEventUnhidden: (Int) -> Void
    var scrollTarget: EventListScrollTarget? = nil
    var onScrollTargetHandled: (() -> Void)? = nil
    var onConfirmAIAttributeTag: ((Int, EventAttributeTag) -> Void)? = nil
    var onRemoveAIAttributeTag: ((Int, EventAttributeTag) -> Void)? = nil
    var onExpandedYearChanged: ((Int) -> Void)? = nil
    var prefersFastSlideshowThumbnails: Bool = false
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
                        LazyVStack(spacing: 0) {
                            ForEach(eventSections) { section in
                                VStack(spacing: 12) {
                                    yearBanner(section)
                                        .id(section.year)

                                    if expandedYear == section.year {
                                        ForEach(section.items) { item in
                                            NavigationLink {
                                                EventDetailView(
                                                    event: item.event,
                                                    onEventUpdated: onEventUpdated,
                                                    onEventHidden: onEventHidden,
                                                    onEventUnhidden: onEventUnhidden
                                                )
                                            } label: {
                                                EventLibraryRowView(
                                                    event: item.event,
                                                    slideshowPhotoIds: item.slideshowPhotoIds,
                                                    slideshowQuality: prefersFastSlideshowThumbnails
                                                        ? .fast
                                                        : .high,
                                                    showsHiddenBadge: showsHiddenEvents,
                                                    onHide: showsHiddenEvents
                                                        ? nil
                                                        : { onEventHidden(item.event.eventId) },
                                                    onUnhide: showsHiddenEvents
                                                        ? { onEventUnhidden(item.event.eventId) }
                                                        : nil,
                                                    onConfirmAIAttributeTag: { tag in
                                                        onConfirmAIAttributeTag?(
                                                            item.event.eventId,
                                                            tag
                                                        )
                                                    },
                                                    onRemoveAIAttributeTag: { tag in
                                                        onRemoveAIAttributeTag?(
                                                            item.event.eventId,
                                                            tag
                                                        )
                                                    }
                                                )
                                                .contentShape(Rectangle())
                                            }
                                            .buttonStyle(.plain)
                                            .padding(.horizontal, 16)
                                            .id(item.id)
                                        }
                                    }
                                }
                                .padding(.bottom, 4)
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
                }
            }
        }
    }

    private func scrollToTargetEvent(using proxy: ScrollViewProxy) {
        guard let scrollTarget else { return }
        guard handledScrollRequestID != scrollTarget.requestID else { return }
        guard let section = eventSections.first(
            where: { $0.items.contains { $0.id == scrollTarget.eventId } }
        ) else {
            return
        }

        if expandedYear != section.year {
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
