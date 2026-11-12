import SwiftUI

/// Titles / empty copy for the shared 1- or 2-person milestone picker.
struct MilestonePeoplePickerCopy: Sendable, Equatable {
    var firstPersonTitle: String
    var secondPersonTitle: String
    var emptyDescription: String
    var addNameMessageFirst: String
    var addNameMessageSecond: String

    static func from(kind: MilestonePersonPickerKind) -> MilestonePeoplePickerCopy {
        MilestonePeoplePickerCopy(
            firstPersonTitle: kind.firstPersonStepTitle,
            secondPersonTitle: kind.secondPersonStepTitle,
            emptyDescription: kind.emptyDescription,
            addNameMessageFirst: kind == .wedding
                ? "Enter the bride’s name if they are not in People yet."
                : "Enter a name if they are not in People yet.",
            addNameMessageSecond: kind == .wedding
                ? "Enter the groom’s name if they are not in People yet."
                : "Enter a name if they are not in People yet."
        )
    }

    /// After rejecting Wedding (or similar) and choosing an alternative classification.
    static func forSimilarEvent(tagValue: String, personCount: Int) -> MilestonePeoplePickerCopy {
        let label = tagValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = label.isEmpty ? "event" : label
        let addMessage = "Enter a name if they are not in People yet."
        if personCount >= 2 {
            return MilestonePeoplePickerCopy(
                firstPersonTitle: "Who is this \(display) for?",
                secondPersonTitle: "Who is the other person?",
                emptyDescription: "Add people to your library to choose who this \(display) is for.",
                addNameMessageFirst: addMessage,
                addNameMessageSecond: addMessage
            )
        }
        return MilestonePeoplePickerCopy(
            firstPersonTitle: "Who is this \(display) for?",
            secondPersonTitle: "Who is this \(display) for?",
            emptyDescription: "Add people to your library to choose who this \(display) is for.",
            addNameMessageFirst: addMessage,
            addNameMessageSecond: addMessage
        )
    }
}

struct CoupleMilestonePickerSheet: View {

    let copy: MilestonePeoplePickerCopy
    /// 1 = single main person (e.g. Senior Prom); 2 = couple (Wedding / Engagement).
    let personCount: Int
    let items: [MilestonePersonPickerItem]
    let defaultWeddingDate: Date
    var allowsManualNameEntry: Bool = true
    /// When false, finishing the last person completes immediately (no wedding-date step).
    var includesWeddingDateStep: Bool = true
    let onComplete: (MilestonePersonPickerItem, MilestonePersonPickerItem?, Date) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var step: Step = .firstPerson
    @State private var firstPerson: MilestonePersonPickerItem?
    @State private var secondPerson: MilestonePersonPickerItem?
    @State private var weddingDate: Date
    @State private var manualNames: [MilestonePersonPickerItem] = []
    @State private var isAddingManualName = false
    @State private var manualNameDraft = ""

    private enum Step {
        case firstPerson
        case secondPerson
        case weddingDate
    }

    private var resolvedPersonCount: Int {
        personCount >= 2 ? 2 : 1
    }

    init(
        kind: MilestonePersonPickerKind,
        items: [MilestonePersonPickerItem],
        defaultWeddingDate: Date,
        allowsManualNameEntry: Bool = true,
        includesWeddingDateStep: Bool = true,
        personCount: Int? = nil,
        onComplete: @escaping (MilestonePersonPickerItem, MilestonePersonPickerItem?, Date) -> Void
    ) {
        self.copy = .from(kind: kind)
        self.personCount = personCount ?? (kind.isCoupleMilestone ? 2 : 1)
        self.items = items
        self.defaultWeddingDate = defaultWeddingDate
        self.allowsManualNameEntry = allowsManualNameEntry
        self.includesWeddingDateStep = includesWeddingDateStep && (personCount ?? 2) >= 2
        self.onComplete = onComplete
        _weddingDate = State(initialValue: defaultWeddingDate)
    }

    init(
        copy: MilestonePeoplePickerCopy,
        personCount: Int,
        items: [MilestonePersonPickerItem],
        defaultWeddingDate: Date = Date(),
        allowsManualNameEntry: Bool = true,
        includesWeddingDateStep: Bool = false,
        onComplete: @escaping (MilestonePersonPickerItem, MilestonePersonPickerItem?, Date) -> Void
    ) {
        self.copy = copy
        self.personCount = personCount
        self.items = items
        self.defaultWeddingDate = defaultWeddingDate
        self.allowsManualNameEntry = allowsManualNameEntry
        self.includesWeddingDateStep = includesWeddingDateStep && personCount >= 2
        self.onComplete = onComplete
        _weddingDate = State(initialValue: defaultWeddingDate)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .firstPerson:
                    personList(people: peopleForCurrentStep) { person in
                        firstPerson = person
                        if resolvedPersonCount >= 2 {
                            step = .secondPerson
                        } else {
                            finish(person1: person, person2: nil)
                        }
                    }
                case .secondPerson:
                    personList(people: peopleForCurrentStep) { person in
                        guard let firstPerson else { return }
                        secondPerson = person
                        if includesWeddingDateStep {
                            step = .weddingDate
                        } else {
                            finish(person1: firstPerson, person2: person)
                        }
                    }
                case .weddingDate:
                    weddingDateForm
                }
            }
            .navigationTitle(currentNavigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if step == .firstPerson {
                        Button("Cancel") {
                            dismiss()
                        }
                    } else {
                        Button("Back") {
                            goBack()
                        }
                    }
                }

                if allowsManualNameEntry, step != .weddingDate {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Add Name") {
                            manualNameDraft = ""
                            isAddingManualName = true
                        }
                    }
                }
            }
            .alert("Add Name", isPresented: $isAddingManualName) {
                TextField("Name", text: $manualNameDraft)
                    .textInputAutocapitalization(.words)
                Button("Cancel", role: .cancel) {}
                Button("Add") {
                    addManualNameFromDraft()
                }
            } message: {
                Text(
                    step == .secondPerson
                        ? copy.addNameMessageSecond
                        : copy.addNameMessageFirst
                )
            }
        }
    }

    private var currentNavigationTitle: String {
        switch step {
        case .firstPerson:
            return copy.firstPersonTitle
        case .secondPerson:
            return copy.secondPersonTitle
        case .weddingDate:
            return "Wedding Date"
        }
    }

    private var allPeople: [MilestonePersonPickerItem] {
        var seenNames = Set(items.map { $0.name.lowercased() })
        var combined = items
        for manual in manualNames {
            let key = manual.name.lowercased()
            guard !seenNames.contains(key) else { continue }
            seenNames.insert(key)
            combined.append(manual)
        }
        return combined
    }

    private var peopleForCurrentStep: [MilestonePersonPickerItem] {
        switch step {
        case .firstPerson, .weddingDate:
            return allPeople
        case .secondPerson:
            guard let firstPerson else { return allPeople }
            return allPeople.filter { candidate in
                if firstPerson.personId > 0, candidate.personId > 0 {
                    return candidate.personId != firstPerson.personId
                }
                return candidate.name.compare(
                    firstPerson.name,
                    options: .caseInsensitive
                ) != .orderedSame
            }
        }
    }

    private var weddingDateForm: some View {
        Form {
            Section {
                DatePicker(
                    "Wedding date",
                    selection: $weddingDate,
                    displayedComponents: .date
                )
            } footer: {
                Text("Used to calculate anniversary names for future events.")
            }

            Section {
                Button("Save") {
                    guard let firstPerson else { return }
                    finish(person1: firstPerson, person2: secondPerson)
                }
            }
        }
    }

    @ViewBuilder
    private func personList(
        people: [MilestonePersonPickerItem],
        onSelect: @escaping (MilestonePersonPickerItem) -> Void
    ) -> some View {
        if people.isEmpty {
            ContentUnavailableView(
                "No People Found",
                systemImage: "person.crop.circle.badge.questionmark",
                description: Text(
                    allowsManualNameEntry
                        ? "\(copy.emptyDescription) Or tap Add Name."
                        : copy.emptyDescription
                )
            )
        } else {
            List(people) { item in
                Button {
                    onSelect(item)
                } label: {
                    Text(item.name)
                        .foregroundStyle(.primary)
                }
            }
        }
    }

    private func finish(
        person1: MilestonePersonPickerItem,
        person2: MilestonePersonPickerItem?
    ) {
        onComplete(person1, person2, weddingDate)
        dismiss()
    }

    private func addManualNameFromDraft() {
        let trimmed = manualNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let existing = allPeople.first(where: {
            $0.name.compare(trimmed, options: .caseInsensitive) == .orderedSame
        }) {
            selectManualOrExisting(existing)
            return
        }

        let item = MilestonePersonPickerItem.manual(name: trimmed)
        manualNames.append(item)
        selectManualOrExisting(item)
    }

    private func selectManualOrExisting(_ person: MilestonePersonPickerItem) {
        switch step {
        case .firstPerson:
            firstPerson = person
            if resolvedPersonCount >= 2 {
                step = .secondPerson
            } else {
                finish(person1: person, person2: nil)
            }
        case .secondPerson:
            guard let firstPerson else { return }
            secondPerson = person
            if includesWeddingDateStep {
                step = .weddingDate
            } else {
                finish(person1: firstPerson, person2: person)
            }
        case .weddingDate:
            break
        }
    }

    private func goBack() {
        switch step {
        case .firstPerson:
            break
        case .secondPerson:
            secondPerson = nil
            step = .firstPerson
        case .weddingDate:
            secondPerson = nil
            step = .secondPerson
        }
    }
}

extension MilestonePersonPickerItem {
    /// Names entered manually (not yet in People) use a stable negative id.
    static func manual(name: String) -> MilestonePersonPickerItem {
        let hash = abs(name.lowercased().hashValue)
        return MilestonePersonPickerItem(
            personId: hash == 0 ? -1 : -hash,
            name: name,
            birthDateISO: nil
        )
    }
}
