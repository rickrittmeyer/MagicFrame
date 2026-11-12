import SwiftUI

/// Events tab for a person birthday: birthday-anchored Picture Search → score → event list.
struct BirthdayPersonEventsEntryView: View {

    let personId: Int
    let displayName: String
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
        .birthdayPerson(personId: personId, displayName: displayName)
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
                    "\(displayName) Events Failed",
                    systemImage: "exclamationmark.triangle",
                    description: Text(
                        errorMessage ?? "Could not score \(displayName) events."
                    )
                )
            case .ready:
                EventsLibraryListContent(
                    filter: listFilter,
                    vm: vm,
                    runsDateRepairOnLoad: false,
                    onBack: { vm.clearEventsTabFocus() },
                    landingTitle: "\(displayName) Events"
                )
            }
        }
        .navigationTitle(phase == .ready ? "" : displayName)
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
        statusLine = "Finding \(displayName) pictures…"

        let pipeline = await Task.detached(priority: .utility) { [personId] in
            await AppDependencies.database.runPersonBirthdayEventsPipeline(personId: personId) {
                phase in
                Task { @MainActor in
                    statusLine = phase
                }
            }
        }.value

        guard let pipeline else {
            errorMessage = "No birth date anchor for \(displayName)."
            phase = .failed
            return
        }

        print("\(displayName) events: \(pipeline.summaryLine)")
        statusLine = pipeline.summaryLine
        phase = .ready

        vm.beginEventListLoad(for: listFilter)
        await vm.reloadEventsAsync(filter: listFilter, loadSlideshowIds: true)
    }
}
