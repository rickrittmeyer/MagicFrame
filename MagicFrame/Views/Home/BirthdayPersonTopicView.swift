import SwiftUI

/// Milestones → Birthdays → {Person}: birthday-anchored Picture Search → photo browser.
struct BirthdayPersonTopicView: View {

    let person: PeopleRepository.PersonBirthdayRecord
    @ObservedObject var vm: LibraryViewModel

    @State private var report: PictureSearchRunReport?
    @State private var statusMessage = "Preparing…"
    @State private var isRunning = true
    @State private var errorMessage: String?

    private var title: String {
        MilestonePictureSearchDefaults.personBirthdayTagValue(displayName: person.name)
    }

    private var listFilter: EventListFilter {
        .birthdayPerson(personId: person.personId, displayName: title)
    }

    private var anchorLabel: String {
        MilestonePictureSearchDefaults.monthDay(fromBirthDateISO: person.birthDateISO)
            ?? "their birthday"
    }

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
            } else if let report, !report.photoMatches.isEmpty {
                PictureBrowserView(
                    title: title,
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
                    enablesVideoFilter: true,
                    browseMonthScope: .eventsFilter(listFilter)
                )
            } else if report != nil {
                ContentUnavailableView(
                    "No Pictures",
                    systemImage: "birthday.cake.fill",
                    description: Text(
                        "Picture Search ran for \(title) (photos of \(person.name) near "
                            + "\(anchorLabel)). None matched yet."
                    )
                )
            } else {
                ContentUnavailableView(
                    "\(title) Search Failed",
                    systemImage: "birthday.cake.fill",
                    description: Text(
                        errorMessage ?? "Could not run \(title) Picture Search."
                    )
                )
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await runPhotosPipelineIfNeeded()
        }
        .onAppear {
            vm.setMainTabChromeMode(.full)
            vm.focusEventsTabOnMilestone(listFilter)
        }
    }

    @MainActor
    private func runPhotosPipelineIfNeeded() async {
        guard report == nil else { return }
        isRunning = true
        errorMessage = nil
        statusMessage = "Preparing \(title)…"

        let pipeline = await Task.detached(priority: .utility) { [personId = person.personId] in
            await AppDependencies.database.runPersonBirthdayPhotosPipeline(personId: personId) {
                phase in
                Task { @MainActor in
                    statusMessage = phase
                }
            }
        }.value

        guard let pipeline else {
            errorMessage = "No birth date anchor for \(person.name)."
            isRunning = false
            return
        }

        report = pipeline.report
        isRunning = false
        print(
            "\(title) photos: “\(pipeline.definition.name)” → \(pipeline.report.summaryLine)"
                + " · anchor \(pipeline.definition.dateSearch.sameDateSearchDate ?? "?")"
        )
    }
}
