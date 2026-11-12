import SwiftUI

struct PictureSearchResultsView: View {

    let title: String
    let definition: PictureSearchDefinition
    let report: PictureSearchRunReport

    @State private var selectedPhotoIndex: Int?
    @State private var showScoreCard = false

    private var uniqueEventCount: Int { report.candidateEventIds.count }

    private var lookForEventsButtonTitle: String {
        let type = definition.targetEventType.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = type.isEmpty ? "Wedding" : type
        return "Look for \(label) Events"
    }

    private var scoreCardTitle: String {
        let name = definition.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        let type = definition.targetEventType.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = type.isEmpty ? "Weddings" : type
        return label
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(report.summaryLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                Text(
                    "\(uniqueEventCount) unique candidate "
                        + (uniqueEventCount == 1 ? "event" : "events")
                        + " (distinct event IDs in results)"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)

                Button {
                    showScoreCard = true
                } label: {
                    Text(lookForEventsButtonTitle)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(uniqueEventCount == 0)
                .padding(.horizontal, 16)

                if uniqueEventCount == 0 {
                    Text("No event IDs on matching pictures yet — assign photos to events first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                }

                if report.photoMatches.isEmpty {
                    ContentUnavailableView(
                        "No Matching Pictures",
                        systemImage: "photo.on.rectangle.angled",
                        description: Text(
                            "No indexed pictures matched this search. Tag photos with Vision first, or widen the date / tag criteria."
                        )
                    )
                    .padding(.top, 24)
                } else {
                    FetchedPhotoGrid(photoIds: report.photoMatches.map(\.photoId)) { photoId in
                        selectedPhotoIndex = report.photoMatches.firstIndex { $0.photoId == photoId }
                    }
                }
            }
        }
        .background(Color(.systemBackground))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showScoreCard) {
            WeddingEventScoreCardView(
                title: scoreCardTitle,
                definition: definition,
                report: report,
                settings: AppDependencies.database.ensureEventScoreCardSettings(
                    for: definition,
                    personNamesById: Dictionary(
                        uniqueKeysWithValues: AppDependencies.database.fetchAllPeople()
                            .map { ($0.personId, $0.name) }
                    )
                )
            )
        }
        .fullScreenCover(isPresented: isPreviewPresented) {
            if let selectedPhotoIndex {
                FetchedPhotoPreview(
                    photoIds: report.photoMatches.map(\.photoId),
                    initialPhotoId: report.photoMatches[selectedPhotoIndex].photoId
                )
            }
        }
    }

    private var isPreviewPresented: Binding<Bool> {
        Binding(
            get: { selectedPhotoIndex != nil },
            set: { isPresented in
                if !isPresented { selectedPhotoIndex = nil }
            }
        )
    }
}
