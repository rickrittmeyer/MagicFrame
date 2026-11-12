import SwiftUI

/// Milestones → {Topic}: Vision prep (if needed) → Picture Search → photo browser. No event scoring.
struct MilestoneTopicView: View {

    let topic: MilestoneTopic
    @ObservedObject var vm: LibraryViewModel

    @State private var report: PictureSearchRunReport?
    @State private var statusMessage = "Preparing…"
    @State private var isRunning = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isRunning {
                VStack(spacing: 16) {
                    ProgressView()
                    Text(statusMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let report {
                PictureBrowserView(
                    title: "\(topic.title) Photos",
                    photoIds: report.photoMatches.map(\.photoId),
                    confidenceByPhotoId: Dictionary(
                        report.photoMatches.compactMap { match in
                            guard let confidence = match.confidence else { return nil }
                            return (match.photoId, confidence)
                        },
                        uniquingKeysWith: { _, latest in latest }
                    ),
                    sortOptions: [.dateTaken, .confidence],
                    usesNavigationTitle: true,
                    enablesVideoFilter: true
                )
            } else {
                ContentUnavailableView(
                    "\(topic.title) Search Failed",
                    systemImage: topic.systemImage,
                    description: Text(
                        errorMessage ?? "Could not run \(topic.title) Picture Search."
                    )
                )
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await runPhotosPipelineIfNeeded()
        }
        .onAppear {
            vm.focusEventsTabOnMilestone(topic.filter)
        }
    }

    @MainActor
    private func runPhotosPipelineIfNeeded() async {
        guard report == nil else { return }
        isRunning = true
        errorMessage = nil

        statusMessage = "Preparing \(topic.title)…"
        let pipeline = await Task.detached(priority: .utility) { [topicId = topic.id] in
            await AppDependencies.database.runMilestonePhotosPipeline(topicId: topicId) { phase in
                Task { @MainActor in
                    statusMessage = phase
                }
            }
        }.value

        guard let pipeline else {
            errorMessage = "No Picture Search defaults for \(topic.title)."
            isRunning = false
            return
        }

        report = pipeline.report
        isRunning = false
        print(
            "\(topic.title) photos: “\(pipeline.definition.name)” → \(pipeline.report.summaryLine)"
        )
    }
}
