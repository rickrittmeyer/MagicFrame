import SwiftUI

/// Developer tools scoped to a person birthday (mirrors HolidayDeveloperView).
struct BirthdayPersonDeveloperView: View {

    let personId: Int
    let displayName: String
    @ObservedObject var vm: LibraryViewModel

    @State private var person: PeopleRepository.PersonBirthdayRecord?
    @State private var isPreparingScorer = false
    @State private var statusMessage: String?
    @State private var scoreCardPayload: BirthdayScoreCardPayload?
    @State private var ensuredPictureSearchName: String?

    private var pictureSearchName: String {
        if let person {
            return MilestonePictureSearchDefaults.pictureSearchName(forPersonBirthday: person)
        }
        return ensuredPictureSearchName
            ?? "\(displayName.replacingOccurrences(of: " Birthday", with: "")) Birthday"
    }

    private var anchorMonthDayLabel: String {
        guard let person,
              let monthDay = MilestonePictureSearchDefaults.monthDay(
                fromBirthDateISO: person.birthDateISO
              ) else {
            return "Unknown"
        }
        return Self.monthDayDisplayFormatter.string(from: monthDay) ?? monthDay
    }

    private static let monthDayDisplayFormatter: MonthDayDisplayFormatter = .init()

    var body: some View {
        List {
            Section {
                Text(displayName)
                    .font(.title2.weight(.bold))
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
            }

            Section("Birthday anchor") {
                LabeledContent("Person", value: person?.name ?? displayName)
                LabeledContent("Birth date (people)", value: person?.birthDateISO ?? "—")
                LabeledContent("Anchor (every year)", value: anchorMonthDayLabel)
                Text(
                    "Default search: photos of this person on the birthday (±3 days) "
                        + "and Fri/Sat before & after. Vision (any): birthday_cake, balloon, decoration."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Picture search") {
                NavigationLink {
                    IdentifyEventTypesView(preferredSearchName: pictureSearchName)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Picture Search")
                        Text("Opens with \(pictureSearchName) as the default.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Event scoring") {
                Button {
                    Task { await openBirthdayEventScorer() }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(displayName) Event Scorer")
                            Text("Runs \(displayName) Picture Search, then opens the score card.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if isPreparingScorer {
                            ProgressView()
                        }
                    }
                }
                .disabled(isPreparingScorer || person == nil)

                NavigationLink {
                    BirthdayPersonEventsEntryView(
                        personId: personId,
                        displayName: displayName,
                        vm: vm
                    )
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Find Potential \(displayName) Events")
                        Text("Picture search → score candidates → Possible \(displayName) Events list.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let statusMessage {
                Section {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Full developer console") {
                NavigationLink("All Developer Tools") {
                    DeveloperView(vm: vm)
                }
            }
        }
        .navigationTitle(displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await ensureBirthdaySearch()
        }
        .navigationDestination(item: $scoreCardPayload) { payload in
            WeddingEventScoreCardView(
                title: "\(displayName) Event Score Card",
                definition: payload.definition,
                report: payload.report,
                settings: AppDependencies.database.ensureEventScoreCardSettings(
                    for: payload.definition,
                    personNamesById: Dictionary(
                        uniqueKeysWithValues: AppDependencies.database.fetchAllPeople()
                            .map { ($0.personId, $0.name) }
                    )
                )
            )
        }
    }

    @MainActor
    private func ensureBirthdaySearch() async {
        let loaded = await Task.detached(priority: .utility) { [personId] in
            let record = AppDependencies.database.fetchPersonBirthdayRecord(personId: personId)
            let definition = record.flatMap {
                AppDependencies.database.ensurePersonBirthdayPictureSearch(person: $0)
            }
            return (record, definition)
        }.value

        person = loaded.0
        if let definition = loaded.1 {
            ensuredPictureSearchName = definition.name
            let anchor = definition.dateSearch.sameDateSearchDate ?? "?"
            statusMessage =
                "Ready · “\(definition.name)” · anchor \(anchor)"
                + " · Fri/Sat before & after"
        } else {
            statusMessage = "No birth date on people record for \(displayName)."
        }
    }

    @MainActor
    private func openBirthdayEventScorer() async {
        guard let person else {
            statusMessage = "No birth date on people record for \(displayName)."
            return
        }
        isPreparingScorer = true
        defer { isPreparingScorer = false }
        statusMessage = "Running \(displayName) Picture Search…"

        let result = await Task.detached(priority: .utility) {
            AppDependencies.database.runPersonBirthdayPictureSearch(person: person)
        }.value

        guard let result else {
            statusMessage = "No Picture Search defaults for \(displayName)."
            return
        }

        statusMessage = result.report.summaryLine
        guard !result.report.candidateEventIds.isEmpty else {
            statusMessage = "\(result.report.summaryLine). No candidate events to score yet."
            return
        }

        scoreCardPayload = BirthdayScoreCardPayload(
            definition: result.definition,
            report: result.report
        )
    }
}

private struct BirthdayScoreCardPayload: Identifiable, Hashable {
    let definition: PictureSearchDefinition
    let report: PictureSearchRunReport

    var id: Int { report.pictureSearchRunId }

    static func == (lhs: BirthdayScoreCardPayload, rhs: BirthdayScoreCardPayload) -> Bool {
        lhs.report.pictureSearchRunId == rhs.report.pictureSearchRunId
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(report.pictureSearchRunId)
    }
}

/// Formats `MM-DD` as a locale month + day (e.g. "March 15").
private struct MonthDayDisplayFormatter {
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar.current
        f.locale = Locale.current
        f.dateFormat = "MMMM d"
        return f
    }()

    func string(from monthDay: String) -> String? {
        let parts = monthDay.split(separator: "-")
        guard parts.count == 2,
              let month = Int(parts[0]),
              let day = Int(parts[1]),
              let date = Calendar.current.date(
                from: DateComponents(year: 2000, month: month, day: day)
              ) else {
            return nil
        }
        return formatter.string(from: date)
    }
}
