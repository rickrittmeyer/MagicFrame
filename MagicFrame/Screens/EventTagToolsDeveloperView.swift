import SwiftUI

/// Developer testing: hard-clear event tags (user + AI + rejected tombstones).
struct EventTagToolsDeveloperView: View {

    private struct TagRow: Identifiable, Hashable {
        let category: String
        let tagValue: String
        let source: String
        let isRejected: Bool

        var id: String { "\(category)|\(tagValue)|\(source)|\(isRejected)" }

        var detailLine: String {
            var parts = [source]
            if isRejected { parts.append("rejected") }
            return parts.joined(separator: " · ")
        }
    }

    @State private var eventIdText = ""
    @State private var loadedEventId: Int?
    @State private var eventTitle: String?
    @State private var rows: [TagRow] = []
    @State private var selectedCategory: String?
    @State private var selectedValue: String?
    @State private var statusMessage: String?

    private var categoriesOnEvent: [String] {
        Array(Set(rows.map(\.category))).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    private var valuesForSelectedCategory: [String] {
        guard let selectedCategory else { return [] }
        return Array(
            Set(
                rows
                    .filter {
                        $0.category.compare(selectedCategory, options: .caseInsensitive) == .orderedSame
                    }
                    .map(\.tagValue)
            )
        )
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var body: some View {
        Form {
            Section("Event") {
                TextField("Event ID", text: $eventIdText)
                    .keyboardType(.numberPad)

                Button("Load event tags") {
                    loadEvent()
                }

                if let loadedEventId {
                    Text("Loaded event \(loadedEventId)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let eventTitle {
                    Text(eventTitle)
                        .font(.subheadline.weight(.semibold))
                }
            }

            if loadedEventId != nil {
                Section("Tags on event") {
                    if rows.isEmpty {
                        Text("No tag rows (including rejected).")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(rows) { row in
                            Button {
                                selectedCategory = row.category
                                selectedValue = row.tagValue
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(row.category) · \(row.tagValue)")
                                        .foregroundStyle(.primary)
                                    Text(row.detailLine)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Section("Hard clear one tag") {
                    Picker("Category", selection: $selectedCategory) {
                        Text("Select").tag(String?.none)
                        ForEach(categoriesOnEvent, id: \.self) { category in
                            Text(category).tag(Optional(category))
                        }
                    }
                    .onChange(of: selectedCategory) { _, _ in
                        if let selectedValue,
                           !valuesForSelectedCategory.contains(where: {
                               $0.compare(selectedValue, options: .caseInsensitive) == .orderedSame
                           }) {
                            self.selectedValue = valuesForSelectedCategory.first
                        }
                    }

                    Picker("Value", selection: $selectedValue) {
                        Text("Select").tag(String?.none)
                        ForEach(valuesForSelectedCategory, id: \.self) { value in
                            Text(value).tag(Optional(value))
                        }
                    }

                    Button("Purge category + value", role: .destructive) {
                        purgeSelected()
                    }
                    .disabled(selectedCategory == nil || selectedValue == nil)

                    Text(
                        "Deletes user, AI, and rejected tombstone rows for that exact pair so AI Assist can re-apply it."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Section("Bulk") {
                    Button("Purge all rejected tombstones on event", role: .destructive) {
                        purgeAllRejected()
                    }
                }
            }

            if let statusMessage {
                Section {
                    Text(statusMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Event Tag Tools")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func loadEvent() {
        statusMessage = nil
        guard let eventId = Int(eventIdText.trimmingCharacters(in: .whitespacesAndNewlines)),
              eventId > 0 else {
            statusMessage = "Enter a valid event ID."
            loadedEventId = nil
            eventTitle = nil
            rows = []
            return
        }

        let event = AppDependencies.database.getEvent(eventId: eventId)
        loadedEventId = eventId
        eventTitle = event?.name
        refreshRows(eventId: eventId)
        if event == nil {
            statusMessage = "No event row for \(eventId); tags (if any) still listed."
        } else {
            statusMessage = "Loaded \(rows.count) tag row(s)."
        }
        selectedCategory = categoriesOnEvent.first
        selectedValue = valuesForSelectedCategory.first
    }

    private func refreshRows(eventId: Int) {
        rows = AppDependencies.database.fetchAllAttributeTagRowsForEvent(eventId: eventId).map {
            TagRow(
                category: $0.category,
                tagValue: $0.tagValue,
                source: $0.source,
                isRejected: $0.isRejected
            )
        }
    }

    private func purgeSelected() {
        guard let eventId = loadedEventId,
              let category = selectedCategory,
              let value = selectedValue else {
            return
        }
        let deleted = AppDependencies.database.purgeEventAttributeTag(
            eventId: eventId,
            category: category,
            tagValue: value
        )
        refreshRows(eventId: eventId)
        selectedCategory = categoriesOnEvent.first
        selectedValue = valuesForSelectedCategory.first
        statusMessage = "Purged \(deleted) row(s) for \(category) · \(value)."
    }

    private func purgeAllRejected() {
        guard let eventId = loadedEventId else { return }
        let deleted = AppDependencies.database.purgeRejectedAttributeTags(eventId: eventId)
        refreshRows(eventId: eventId)
        statusMessage = "Purged \(deleted) rejected row(s)."
    }
}
