import SwiftUI

/// Stable navigation destination keyed by `eventId` (not the list row value).
struct EventDetailRouteView: View {

    let eventId: Int
    let initialEvent: IndexedEvent?
    let resolveEvent: (Int) -> IndexedEvent?
    let onEventUpdated: (Int) -> Void
    let onEventHidden: (Int) -> Void
    let onEventUnhidden: (Int) -> Void
    let onDismissed: (Int) -> Void

    @State private var event: IndexedEvent?

    init(
        eventId: Int,
        initialEvent: IndexedEvent?,
        resolveEvent: @escaping (Int) -> IndexedEvent?,
        onEventUpdated: @escaping (Int) -> Void,
        onEventHidden: @escaping (Int) -> Void,
        onEventUnhidden: @escaping (Int) -> Void,
        onDismissed: @escaping (Int) -> Void
    ) {
        self.eventId = eventId
        self.initialEvent = initialEvent
        self.resolveEvent = resolveEvent
        self.onEventUpdated = onEventUpdated
        self.onEventHidden = onEventHidden
        self.onEventUnhidden = onEventUnhidden
        self.onDismissed = onDismissed
        _event = State(initialValue: initialEvent)
    }

    var body: some View {
        Group {
            if let event {
                EventDetailView(
                    event: event,
                    onEventUpdated: onEventUpdated,
                    onEventHidden: onEventHidden,
                    onEventUnhidden: onEventUnhidden
                )
            } else {
                ProgressView("Loading event…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: eventId) {
            if event == nil {
                event = initialEvent ?? resolveEvent(eventId)
            }
        }
        .onDisappear {
            onDismissed(eventId)
        }
    }
}
