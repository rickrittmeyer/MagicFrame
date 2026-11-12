import SwiftUI

/// Home → Weddings: ensures the “Weddings” Picture Search is saved, runs it, shows Identify Event Types results.
struct WeddingPictureSearchHomeView: View {

    @State private var definition: PictureSearchDefinition?
    @State private var report: PictureSearchRunReport?
    @State private var isRunning = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isRunning {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("Searching wedding pictures…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("Weddings")
                .navigationBarTitleDisplayMode(.inline)
            } else if let definition, let report {
                PictureSearchResultsView(
                    title: "Weddings",
                    definition: definition,
                    report: report
                )
            } else {
                ContentUnavailableView(
                    "Wedding Search Failed",
                    systemImage: "heart.slash",
                    description: Text(errorMessage ?? "Could not run Weddings Picture Search.")
                )
                .navigationTitle("Weddings")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .task {
            await runWeddingSearchIfNeeded()
        }
    }

    @MainActor
    private func runWeddingSearchIfNeeded() async {
        guard definition == nil, report == nil else { return }
        isRunning = true
        errorMessage = nil

        let result = await Task.detached(priority: .utility) {
            AppDependencies.database.runWeddingPictureSearch()
        }.value

        definition = result.definition
        report = result.report
        isRunning = false
        print(
            "Weddings home: “\(result.definition.name)” → \(result.report.summaryLine)"
        )
    }
}
