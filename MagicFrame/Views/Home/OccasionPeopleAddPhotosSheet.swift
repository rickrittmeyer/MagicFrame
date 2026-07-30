import SwiftUI

struct OccasionPeopleAddPhotosSheet: View {

    let item: OccasionLandingItem
    @ObservedObject var vm: LibraryViewModel

    @Environment(\.dismiss) private var dismiss

    @State private var people: [PeopleRepository.PersonRecord] = []
    @State private var parentPersonId: Int?
    @State private var selectedChildIds: Set<Int> = []
    @State private var exactPeopleOnly = true
    @State private var searchResults: [String] = []
    @State private var selectedPhotoIds: Set<String> = []
    @State private var hasSearched = false
    @State private var step: WizardStep = .configure

    private let photoColumns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
    ]

    private enum WizardStep {
        case configure
        case results
    }

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .configure:
                    configureForm
                case .results:
                    resultsGrid
                }
            }
            .navigationTitle("Add by People")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                if step == .results {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Back") {
                            step = .configure
                        }
                    }

                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add (\(selectedPhotoIds.count))") {
                            applySelection()
                        }
                        .disabled(selectedPhotoIds.isEmpty)
                    }
                }
            }
            .onAppear {
                loadPeople()
            }
        }
    }

    private var configureForm: some View {
        Form {
            Section {
                Text(parentPrompt)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section(parentPickerTitle) {
                if item.isBirthday {
                    if let personId = parentPersonId,
                       let person = people.first(where: { $0.personId == personId }) {
                        Text(person.name)
                    } else {
                        Text("No person linked to this birthday.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Picker(parentPickerTitle, selection: $parentPersonId) {
                        Text("Choose…").tag(Optional<Int>.none)
                        ForEach(people) { person in
                            Text(person.name).tag(Optional(person.personId))
                        }
                    }
                }
            }

            if !item.isBirthday {
                Section("Children (optional)") {
                    if people.isEmpty {
                        Text("No people found in your library.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(people) { person in
                            if person.personId != parentPersonId {
                                Toggle(person.name, isOn: childBinding(for: person.personId))
                            }
                        }
                    }
                }
            }

            Section {
                Toggle(exactPeopleToggleTitle, isOn: $exactPeopleOnly)
            } footer: {
                Text(exactPeopleFooter)
            }

            Section {
                Button("Search photos") {
                    runSearch()
                }
                .disabled(!canSearch)
            }
        }
    }

    private var resultsGrid: some View {
        ScrollView {
            if searchResults.isEmpty {
                ContentUnavailableView(
                    "No Matching Photos",
                    systemImage: "person.2.slash",
                    description: Text(
                        "Try turning off “Only these people in photo” or add different children."
                    )
                )
                .padding(.top, 32)
            } else {
                LazyVGrid(columns: photoColumns, spacing: 8) {
                    ForEach(searchResults, id: \.self) { photoId in
                        OccasionPeoplePhotoPickerCell(
                            photoId: photoId,
                            isSelected: selectedPhotoIds.contains(photoId),
                            isAlreadyOnFrame: vm.occasionFrameSnapshot?.onFramePhotoIds.contains(photoId) == true,
                            onToggle: {
                                togglePhotoSelection(photoId)
                            }
                        )
                    }
                }
                .padding(12)
            }
        }
    }

    private var parentPickerTitle: String {
        if item.isBirthday {
            return "Birthday person"
        }
        return item.parentSubjectRole == .father ? "Father" : "Mother"
    }

    private var parentPrompt: String {
        if item.isBirthday {
            return "We'll find photos of this person across your whole library."
        }
        return item.parentSubjectRole == .father
            ? "Pick Dad and any children. We'll find matching photos across your whole library."
            : "Pick Mom and any children. We'll find matching photos across your whole library."
    }

    private var exactPeopleToggleTitle: String {
        item.isBirthday ? "Only this person in photo" : "Only these people in photo"
    }

    private var exactPeopleFooter: String {
        if item.isBirthday {
            return "When on, photos must include only the birthday person."
        }
        return "When on, photos must include the parent and at least one selected child, with no one else tagged."
    }

    private var canSearch: Bool {
        guard let parentPersonId else { return false }
        if item.isBirthday {
            return parentPersonId > 0
        }
        return !selectedChildIds.isEmpty
    }

    private func childBinding(for personId: Int) -> Binding<Bool> {
        Binding(
            get: { selectedChildIds.contains(personId) },
            set: { isOn in
                if isOn {
                    selectedChildIds.insert(personId)
                } else {
                    selectedChildIds.remove(personId)
                }
            }
        )
    }

    private func loadPeople() {
        people = vm.fetchAllPeople()

        let savedSubjects = vm.fetchOccasionSubjects(occasionKey: item.occasionKey)
        if parentPersonId == nil {
            if item.isBirthday {
                parentPersonId = vm.fetchOccasionPersonId(occasionKey: item.occasionKey)
                    ?? savedSubjects.first(where: { $0.role == .person })?.personId
            } else {
                parentPersonId = savedSubjects.first(where: {
                    $0.role == item.parentSubjectRole
                })?.personId
            }
        }

        if !item.isBirthday, selectedChildIds.isEmpty {
            selectedChildIds = Set(
                savedSubjects
                    .filter { $0.role == .child }
                    .map(\.personId)
            )
        }
    }

    private func runSearch() {
        guard let parentPersonId, canSearch else { return }

        if item.isBirthday {
            vm.saveOccasionPeopleSubjects(
                occasionKey: item.occasionKey,
                parentPersonId: parentPersonId,
                childPersonIds: [],
                parentRole: .person
            )

            searchResults = vm.searchOccasionPersonPhotos(
                personId: parentPersonId,
                exactPeopleOnly: exactPeopleOnly
            )
        } else {
            vm.saveOccasionPeopleSubjects(
                occasionKey: item.occasionKey,
                parentPersonId: parentPersonId,
                childPersonIds: Array(selectedChildIds),
                parentRole: item.parentSubjectRole
            )

            searchResults = vm.searchOccasionPeoplePhotos(
                parentPersonId: parentPersonId,
                childPersonIds: Array(selectedChildIds),
                exactPeopleOnly: exactPeopleOnly
            )
        }

        selectedPhotoIds = Set(
            searchResults.filter {
                vm.occasionFrameSnapshot?.onFramePhotoIds.contains($0) == true
            }
        )

        hasSearched = true
        step = .results
    }

    private func togglePhotoSelection(_ photoId: String) {
        if selectedPhotoIds.contains(photoId) {
            selectedPhotoIds.remove(photoId)
        } else {
            selectedPhotoIds.insert(photoId)
        }
    }

    private func applySelection() {
        let newPhotoIds = selectedPhotoIds.filter {
            vm.occasionFrameSnapshot?.onFramePhotoIds.contains($0) != true
        }

        vm.addPhotosToOccasionFrame(
            photoIds: Array(newPhotoIds),
            occasionKey: item.occasionKey,
            source: .people
        )

        dismiss()
    }
}

private struct OccasionPeoplePhotoPickerCell: View {

    let photoId: String
    let isSelected: Bool
    let isAlreadyOnFrame: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            PhotoThumbnailView(
                assetIdentifier: photoId,
                cornerRadius: 10,
                quality: .fast,
                cropContext: .frame
            )
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                }
            }
            .overlay(alignment: .topLeading) {
                if isAlreadyOnFrame {
                    Text("On frame")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        .padding(6)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, isSelected ? Color.accentColor : Color.black.opacity(0.35))
                    .padding(6)
            }
        }
        .buttonStyle(.plain)
    }
}
