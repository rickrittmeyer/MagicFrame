import SwiftUI

/// Events tab for a milestone topic: Picture Search (reuse if fresh) → score candidates → event list.
struct MilestoneEventsEntryView: View {

    let topic: MilestoneTopic
    @ObservedObject var vm: LibraryViewModel

    @State private var phase: Phase = .running
    @State private var statusLine = "Finding pictures…"
    @State private var errorMessage: String?

    private enum Phase {
        case running
        case ready
        case failed
    }

    private var listFilter: EventListFilter { topic.filter }

    var body: some View {
        Group {
            switch phase {
            case .running:
                VStack(spacing: 16) {
                    ProgressView()
                    Text(statusLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed:
                ContentUnavailableView(
                    "\(topic.title) Events Failed",
                    systemImage: "exclamationmark.triangle",
                    description: Text(
                        errorMessage ?? "Could not score \(topic.title) events."
                    )
                )
            case .ready:
                EventsLibraryListContent(
                    filter: listFilter,
                    vm: vm,
                    runsDateRepairOnLoad: false,
                    onBack: { vm.clearEventsTabFocus() },
                    landingTitle: "\(topic.title) Events"
                )
            }
        }
        .navigationTitle(phase == .ready ? "" : topic.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if phase != .ready {
                ToolbarItem(placement: .topBarLeading) {
                    EventsTabBackButton(action: { vm.clearEventsTabFocus() })
                }
            }
        }
        .task {
            await runEventsPipelineIfNeeded()
        }
    }

    @MainActor
    private func runEventsPipelineIfNeeded() async {
        guard phase != .ready else { return }
        phase = .running
        errorMessage = nil
        statusLine = "Finding \(topic.title) pictures…"

        let pipeline = await Task.detached(priority: .utility) { [topicId = topic.id] in
            await AppDependencies.database.runMilestoneEventsPipeline(topicId: topicId) { phase in
                Task { @MainActor in
                    statusLine = phase
                }
            }
        }.value

        guard let pipeline else {
            errorMessage = "No Picture Search defaults for \(topic.title)."
            phase = .failed
            return
        }

        print("\(topic.title) events: \(pipeline.summaryLine)")
        statusLine = pipeline.summaryLine
        phase = .ready

        vm.beginEventListLoad(for: listFilter)
        await vm.reloadEventsAsync(filter: listFilter, loadSlideshowIds: true)
    }
}
