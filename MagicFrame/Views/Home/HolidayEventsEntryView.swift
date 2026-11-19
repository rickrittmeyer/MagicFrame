import SwiftUI

/// Events tab for a holiday: Picture Search (reuse if fresh) → score candidates → event list.
struct HolidayEventsEntryView: View {

    let tagValue: String
    @ObservedObject var vm: LibraryViewModel

    @State private var phase: Phase = .running
    @State private var statusLine = "Finding pictures…"
    @State private var errorMessage: String?

    private enum Phase {
        case running
        case ready
        case failed
    }

    private var listFilter: EventListFilter {
        .holidayTag(value: tagValue)
    }

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
                    "\(tagValue) Events Failed",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage ?? "Could not score \(tagValue) events.")
                )
            case .ready:
                EventsLibraryListContent(
                    filter: listFilter,
                    vm: vm,
                    runsDateRepairOnLoad: false,
                    onBack: { vm.requestReturnToHolidaysHub() },
                    landingTitle: "\(tagValue) Events"
                )
            }
        }
        .navigationTitle(phase == .ready ? "" : tagValue)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if phase != .ready {
                ToolbarItem(placement: .topBarLeading) {
                    EventsTabBackButton(action: { vm.requestReturnToHolidaysHub() })
                }
            }
        }
        .onAppear {
            vm.setMainTabChromeMode(.full)
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
        statusLine = "Finding \(tagValue) pictures…"

        let pipeline = await Task.detached(priority: .utility) {
            await AppDependencies.database.runHolidayEventsPipeline(tagValue: tagValue) { phase in
                Task { @MainActor in
                    statusLine = phase
                }
            }
        }.value

        guard let pipeline else {
            errorMessage = "No Picture Search defaults for \(tagValue)."
            phase = .failed
            return
        }

        print("\(tagValue) events: \(pipeline.summaryLine)")
        statusLine = pipeline.summaryLine
        phase = .ready

        vm.beginEventListLoad(for: listFilter)
        await vm.reloadEventsAsync(filter: listFilter, loadSlideshowIds: true)
    }
}
