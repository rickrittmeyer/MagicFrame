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

    /// Prefer apostrophe form even if an older caller passed "Rachel Birthday".
    private var canonicalTitle: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if MilestonePictureSearchDefaults.isPersonBirthdayTagValue(trimmed),
           trimmed.lowercased().hasSuffix("'s birthday") {
            return trimmed
        }
        let stripped = trimmed
            .replacingOccurrences(of: "'s Birthday", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: " Birthday", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return MilestonePictureSearchDefaults.personBirthdayTagValue(
            displayName: stripped.isEmpty ? trimmed : stripped
        )
    }

    private var listFilter: EventListFilter {
        .birthdayPerson(personId: personId, displayName: canonicalTitle)
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
                    "\(canonicalTitle) Events Failed",
                    systemImage: "exclamationmark.triangle",
                    description: Text(
                        errorMessage ?? "Could not score \(canonicalTitle) events."
                    )
                )
            case .ready:
                EventsLibraryListContent(
                    filter: listFilter,
                    vm: vm,
                    runsDateRepairOnLoad: false,
                    onBack: { vm.clearEventsTabFocus() },
                    landingTitle: "\(canonicalTitle) Events"
                )
            }
        }
        .navigationTitle(phase == .ready ? "" : canonicalTitle)
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
        statusLine = "Finding \(canonicalTitle) pictures…"

        let pipeline = await Task.detached(priority: .utility) { [personId] in
            await AppDependencies.database.runPersonBirthdayEventsPipeline(personId: personId) {
                phase in
                Task { @MainActor in
                    statusLine = phase
                }
            }
        }.value

        guard let pipeline else {
            errorMessage = "No birth date anchor for \(canonicalTitle)."
            phase = .failed
            return
        }

        print("\(canonicalTitle) events: \(pipeline.summaryLine)")
        statusLine = pipeline.summaryLine
        // Brief beat so scoring summary is readable before the list appears.
        try? await Task.sleep(nanoseconds: 400_000_000)
        phase = .ready

        vm.beginEventListLoad(for: listFilter)
        await vm.reloadEventsAsync(filter: listFilter, loadSlideshowIds: true)
    }
}
