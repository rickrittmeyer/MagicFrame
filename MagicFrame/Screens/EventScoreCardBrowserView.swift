import SwiftUI

/// Developer: pick an AI event tag (like Event Detail), then open/create its scorecard.
struct EventScoreCardBrowserView: View {

    @State private var selectedField: EventAttributeField?
    @State private var optionsByField: [EventAttributeField: [String]] = [:]

    var body: some View {
        Group {
            if let field = selectedField {
                optionsList(for: field)
            } else {
                categoryList
            }
        }
        .navigationTitle(selectedField?.menuTitle ?? "Event Score Cards")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if selectedField != nil {
                    Button("Categories") { selectedField = nil }
                }
            }
        }
        .onAppear { reloadOptions() }
    }

    private var categoryList: some View {
        List(EventAttributeField.pictureSearchCategoryCases) { field in
            Button {
                selectedField = field
            } label: {
                Label(field.menuTitle, systemImage: field.iconName)
            }
        }
    }

    private func optionsList(for field: EventAttributeField) -> some View {
        let options = optionsByField[field] ?? []
        return List {
            if options.isEmpty {
                Text("No values yet for \(field.menuTitle).")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(options, id: \.self) { option in
                    NavigationLink {
                        EventScoreCardEditorView(
                            settings: AppDependencies.database.ensureEventScoreCardSettings(
                                tagCategory: field.tagCategory,
                                tagValue: option,
                                personNamesById: [:]
                            )
                        )
                    } label: {
                        Text(option)
                    }
                }
            }
        }
    }

    private func reloadOptions() {
        let scoreCardValuesByCategory = Dictionary(
            grouping: AppDependencies.database.fetchAllEventScoreCardSettings(),
            by: { $0.targetTagCategory.lowercased() }
        )
        var map: [EventAttributeField: [String]] = [:]
        for field in EventAttributeField.pictureSearchCategoryCases {
            var options = Set(AppDependencies.database.getEventAttributeOptions(for: field))
            if let fromCards = scoreCardValuesByCategory[field.tagCategory.lowercased()] {
                for card in fromCards {
                    let value = card.targetEventType.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty {
                        options.insert(value)
                    }
                }
            }
            map[field] = options.sorted {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            }
        }
        optionsByField = map
    }
}
