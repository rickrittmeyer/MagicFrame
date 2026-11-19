import SwiftUI

/// Lets the user pick an existing event that contains the shifted date range.
struct PhotoDateAdjustEventPickerSheet: View {
    let events: [IndexedEvent]
    let onCancel: () -> Void
    let onSelect: (IndexedEvent) -> Void

    var body: some View {
        NavigationStack {
            List(events, id: \.eventId) { event in
                Button {
                    onSelect(event)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(event.listTitleText ?? event.name)
                            .foregroundStyle(.primary)
                        Text(PhotoDateAdjustResult.eventSummaryLine(for: event))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
            .navigationTitle("Add to Existing Event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
    }
}
