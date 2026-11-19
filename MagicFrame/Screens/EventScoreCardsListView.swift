import SwiftUI

/// Lists saved Event Score Cards. Opened from the Developer tag on Event Detail.
struct EventScoreCardsListView: View {

    @State private var cards: [PictureSearchEventScoreCardSettings] = []

    var body: some View {
        List {
            if cards.isEmpty {
                Section {
                    Text("No score cards yet. Choose a tag to create one.")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(groupedCards) { group in
                    Section(group.title) {
                        ForEach(group.cards, id: \.rowID) { card in
                            NavigationLink {
                                EventScoreCardEditorView(settings: card)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(card.targetEventType)
                                    Text(summary(for: card))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }

            Section {
                NavigationLink("Choose a tag") {
                    EventScoreCardBrowserView()
                }
            } footer: {
                Text("Pick a category and value to open that score card, or create one if it does not exist yet.")
            }
        }
        .navigationTitle("Event Score Cards")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
    }

    private var groupedCards: [ScoreCardGroup] {
        let grouped = Dictionary(grouping: cards) { card in
            EventAttributeField.fromTagCategory(card.targetTagCategory)?.menuTitle
                ?? card.targetTagCategory
        }
        let preferred = EventAttributeField.pictureSearchCategoryCases.map(\.menuTitle)
        let titles = preferred.filter { grouped[$0] != nil }
            + grouped.keys.filter { !preferred.contains($0) }.sorted()
        return titles.map { title in
            ScoreCardGroup(
                title: title,
                cards: (grouped[title] ?? []).sorted {
                    $0.targetEventType.localizedCaseInsensitiveCompare($1.targetEventType) == .orderedAscending
                }
            )
        }
    }

    private func summary(for card: PictureSearchEventScoreCardSettings) -> String {
        var parts: [String] = []
        if !card.visionTags.isEmpty {
            let label = card.visionTags.count == 1 ? "vision tag" : "vision tags"
            parts.append("\(card.visionTags.count) \(label)")
        }
        if !card.locations.isEmpty {
            let label = card.locations.count == 1 ? "location" : "locations"
            parts.append("\(card.locations.count) \(label)")
        }
        if !card.people.isEmpty {
            parts.append("\(card.people.count) people")
        }
        if card.minimumScoreForAI > 0 {
            parts.append(String(format: "AI ≥ %.0f", card.minimumScoreForAI))
        }
        return parts.isEmpty ? "No rules yet" : parts.joined(separator: " · ")
    }

    private func reload() {
        cards = AppDependencies.database.fetchAllEventScoreCardSettings()
    }
}

private struct ScoreCardGroup: Identifiable {
    let title: String
    let cards: [PictureSearchEventScoreCardSettings]

    var id: String { title }
}

private extension PictureSearchEventScoreCardSettings {
    var rowID: String {
        if let eventScoreCardId {
            return "card-\(eventScoreCardId)"
        }
        return "name-\(name)-\(targetTagCategory)-\(targetEventType)"
    }
}
