import SwiftUI

struct CoupleMilestonePickerSheet: View {

    let kind: MilestonePersonPickerKind
    let items: [MilestonePersonPickerItem]
    let defaultWeddingDate: Date
    let onComplete: (MilestonePersonPickerItem, MilestonePersonPickerItem, Date) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var step: Step = .firstPerson
    @State private var firstPerson: MilestonePersonPickerItem?
    @State private var secondPerson: MilestonePersonPickerItem?
    @State private var weddingDate: Date

    private enum Step {
        case firstPerson
        case secondPerson
        case weddingDate
    }

    init(
        kind: MilestonePersonPickerKind,
        items: [MilestonePersonPickerItem],
        defaultWeddingDate: Date,
        onComplete: @escaping (MilestonePersonPickerItem, MilestonePersonPickerItem, Date) -> Void
    ) {
        self.kind = kind
        self.items = items
        self.defaultWeddingDate = defaultWeddingDate
        self.onComplete = onComplete
        _weddingDate = State(initialValue: defaultWeddingDate)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .firstPerson:
                    personList(people: items) { person in
                        firstPerson = person
                        step = .secondPerson
                    }
                case .secondPerson:
                    personList(people: secondPersonChoices) { person in
                        secondPerson = person
                        step = .weddingDate
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
            }
        }
    }

    private var currentNavigationTitle: String {
        switch step {
        case .firstPerson:
            return kind.firstPersonStepTitle
        case .secondPerson:
            return kind.secondPersonStepTitle
        case .weddingDate:
            return kind.weddingDateStepTitle
        }
    }

    private var secondPersonChoices: [MilestonePersonPickerItem] {
        guard let firstPerson else { return items }
        return items.filter { $0.personId != firstPerson.personId }
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
                    guard let firstPerson, let secondPerson else { return }
                    onComplete(firstPerson, secondPerson, weddingDate)
                    dismiss()
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
                description: Text(kind.emptyDescription)
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
