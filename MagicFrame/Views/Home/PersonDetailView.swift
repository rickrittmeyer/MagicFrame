import SwiftUI

/// Edit profile, birthdate, and relationships for one person in `people`.
struct PersonDetailView: View {

    let personId: Int

    @State private var displayName: String = ""
    @State private var firstName: String = ""
    @State private var lastName: String = ""
    @State private var birthDate: Date?
    @State private var hasBirthDate = false
    @State private var photoCount = 0
    @State private var avatarPhotoId: String?
    @State private var avatarBox: CGRect?
    @State private var relationships: [PeopleRelationship] = []
    @State private var allPeople: [PeopleRepository.PersonRecord] = []
    @State private var statusMessage: String?
    @State private var pendingRelationshipKind: RelationshipAddKind?
    @State private var isShowingPhotos = false
    @State private var isSaving = false

    private enum RelationshipAddKind: String, Identifiable {
        case mother
        case sibling
        case significantOther
        case husband
        case wife

        var id: String { rawValue }

        var title: String {
            switch self {
            case .mother: return "Mother"
            case .sibling: return "Sibling"
            case .significantOther: return "Significant Other"
            case .husband: return "Husband"
            case .wife: return "Wife"
            }
        }
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Spacer()
                    if let avatarPhotoId, let avatarBox {
                        FaceCircleAvatar(
                            photoId: avatarPhotoId,
                            faceBoundingBox: avatarBox,
                            size: 112
                        )
                    } else {
                        Circle()
                            .fill(Color(.secondarySystemFill))
                            .frame(width: 112, height: 112)
                            .overlay {
                                Image(systemName: "person.fill")
                                    .font(.largeTitle)
                                    .foregroundStyle(.secondary)
                            }
                    }
                    Spacer()
                }
                .listRowBackground(Color.clear)

                if photoCount > 0 {
                    Button {
                        isShowingPhotos = true
                    } label: {
                        Label(
                            "\(photoCount) photo\(photoCount == 1 ? "" : "s")",
                            systemImage: "photo.on.rectangle"
                        )
                    }
                }
            }

            Section("Name") {
                TextField("Display name", text: $displayName)
                    .textInputAutocapitalization(.words)
                TextField("First name", text: $firstName)
                    .textInputAutocapitalization(.words)
                TextField("Last name", text: $lastName)
                    .textInputAutocapitalization(.words)
            }

            Section("Birthday") {
                Toggle("Has birth date", isOn: $hasBirthDate)
                if hasBirthDate {
                    DatePicker(
                        "Birth date",
                        selection: Binding(
                            get: { birthDate ?? Date(timeIntervalSince1970: 0) },
                            set: { birthDate = $0 }
                        ),
                        displayedComponents: .date
                    )
                }
                Text(
                    "Saving a birth date creates a Milestone tag and scorecard named “\(previewBirthdayTag)”."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Relationships") {
                if relationships.isEmpty {
                    Text("No relationships yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(relationships) { relationship in
                        relationshipRow(relationship)
                    }
                    .onDelete(perform: deleteRelationships)
                }

                Menu("Add relationship") {
                    Button("Mother") { pendingRelationshipKind = .mother }
                    Button("Sibling") { pendingRelationshipKind = .sibling }
                    Button("Significant Other") { pendingRelationshipKind = .significantOther }
                    Button("Husband") { pendingRelationshipKind = .husband }
                    Button("Wife") { pendingRelationshipKind = .wife }
                }
            }

            if let statusMessage {
                Section {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(displayName.isEmpty ? "Person" : displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task { await save() }
                }
                .disabled(isSaving || displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .task {
            await reload()
        }
        .onAppear {
            Task { await reload() }
        }
        .navigationDestination(isPresented: $isShowingPhotos) {
            PersonPhotosBrowserView(
                person: PeopleRepository.PersonRecord(
                    personId: personId,
                    displayName: displayName,
                    firstName: firstName.isEmpty ? nil : firstName,
                    lastName: lastName.isEmpty ? nil : lastName,
                    maidenName: nil
                )
            )
        }
        .sheet(item: $pendingRelationshipKind) { kind in
            NavigationStack {
                List(otherPeople) { person in
                    Button(person.displayName) {
                        Task {
                            await addRelationship(kind: kind, otherPersonId: person.personId)
                            pendingRelationshipKind = nil
                        }
                    }
                }
                .navigationTitle(kind.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { pendingRelationshipKind = nil }
                    }
                }
            }
        }
    }

    private var previewBirthdayTag: String {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return MilestonePictureSearchDefaults.personBirthdayTagValue(
            displayName: name.isEmpty ? "Person" : name
        )
    }

    private var otherPeople: [PeopleRepository.PersonRecord] {
        allPeople.filter { $0.personId != personId }
    }

    private func relationshipRow(_ relationship: PeopleRelationship) -> some View {
        let otherId = relationship.personIdA == personId
            ? relationship.personIdB
            : relationship.personIdA
        let otherName = allPeople.first(where: { $0.personId == otherId })?.displayName
            ?? "Person \(otherId)"
        // Role of the *other* person relative to this profile.
        let otherRole = relationship.personIdA == personId
            ? relationship.roleB
            : relationship.roleA
        return VStack(alignment: .leading, spacing: 2) {
            Text(otherName)
            Text(relationshipCaption(otherRole: otherRole, type: relationship.relationshipType))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func relationshipCaption(
        otherRole: PeopleRelationshipRole,
        type: PeopleRelationshipType
    ) -> String {
        switch type {
        case .parent:
            return otherRole == .mother ? "Mother" : otherRole.rawValue.capitalized
        case .sibling:
            return "Sibling"
        case .married:
            switch otherRole {
            case .husband: return "Husband"
            case .wife: return "Wife"
            default: return "Married"
            }
        case .dating:
            return "Significant other"
        default:
            return type.rawValue
        }
    }

    @MainActor
    private func reload() async {
        let loaded = await Task.detached(priority: .utility) { [personId] in
            // Backfill Picture Search + scorecard if birth date already exists.
            if AppDependencies.database.fetchPersonBirthdayRecord(personId: personId) != nil {
                _ = AppDependencies.database.ensurePersonBirthdaySearchAndScoreCard(
                    personId: personId
                )
            }
            let detail = AppDependencies.database.fetchPersonDetail(personId: personId)
            let relationships = AppDependencies.database.fetchRelationships(
                involvingPersonId: personId
            )
            let people = AppDependencies.database.fetchAllPeople()
            return (detail, relationships, people)
        }.value

        guard let detail = loaded.0 else { return }
        displayName = detail.displayName
        firstName = detail.firstName ?? ""
        lastName = detail.lastName ?? ""
        photoCount = detail.photoCount
        avatarPhotoId = detail.avatarPhotoId
        avatarBox = detail.avatarBoundingBox
        if let iso = detail.birthDateISO, let date = EventDateParser.parseDate(iso) {
            birthDate = date
            hasBirthDate = true
        } else {
            birthDate = nil
            hasBirthDate = false
        }
        relationships = loaded.1
        allPeople = loaded.2
    }

    @MainActor
    private func save() async {
        isSaving = true
        defer { isSaving = false }

        let trimmedDisplay = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDisplay.isEmpty else { return }

        let first = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        let last = lastName.trimmingCharacters(in: .whitespacesAndNewlines)
        let birthISO: String? = {
            guard hasBirthDate, let birthDate else { return nil }
            return Self.isoDateString(from: birthDate)
        }()

        let ensuredName: String? = await Task.detached(priority: .utility) { () -> String? in
            AppDependencies.database.updatePersonProfile(
                personId: personId,
                displayName: trimmedDisplay,
                firstName: first.isEmpty ? nil : first,
                lastName: last.isEmpty ? nil : last,
                maidenName: nil
            )
            guard let birthISO else { return nil }
            return AppDependencies.database.setPersonBirthDate(
                personId: personId,
                birthDateISO: birthISO
            )?.targetEventType
        }.value

        if birthISO == nil {
            statusMessage = "Saved."
        } else if let ensuredName {
            statusMessage = "Saved · scorecard “\(ensuredName)” ready."
        } else {
            statusMessage = "Saved birth date, but could not create \(previewBirthdayTag) scorecard."
        }
        await reload()
    }

    @MainActor
    private func addRelationship(kind: RelationshipAddKind, otherPersonId: Int) async {
        await Task.detached(priority: .utility) { [personId] in
            switch kind {
            case .mother:
                _ = AppDependencies.database.upsertParentChildRelationship(
                    parentPersonId: otherPersonId,
                    childPersonId: personId,
                    parentRole: .mother
                )
            case .sibling:
                _ = AppDependencies.database.upsertSiblingRelationship(
                    personIdA: personId,
                    personIdB: otherPersonId
                )
            case .significantOther:
                _ = AppDependencies.database.upsertRomanticRelationship(
                    personIdA: personId,
                    personIdB: otherPersonId,
                    relationshipType: .dating,
                    roleA: .boyfriend,
                    roleB: .girlfriend
                )
            case .husband:
                _ = AppDependencies.database.upsertRomanticRelationship(
                    personIdA: otherPersonId,
                    personIdB: personId,
                    relationshipType: .married,
                    roleA: .husband,
                    roleB: .wife
                )
            case .wife:
                _ = AppDependencies.database.upsertRomanticRelationship(
                    personIdA: otherPersonId,
                    personIdB: personId,
                    relationshipType: .married,
                    roleA: .wife,
                    roleB: .husband
                )
            }
        }.value
        await reload()
        statusMessage = "Relationship added."
    }

    private func deleteRelationships(at offsets: IndexSet) {
        let ids = offsets.map { relationships[$0].relationshipId }
        Task {
            await Task.detached(priority: .utility) {
                for id in ids {
                    AppDependencies.database.deletePeopleRelationship(relationshipId: id)
                }
            }.value
            await reload()
        }
    }

    private static func isoDateString(from date: Date) -> String {
        let calendar = Calendar.current
        let y = calendar.component(.year, from: date)
        let m = calendar.component(.month, from: date)
        let d = calendar.component(.day, from: date)
        return String(format: "%04d-%02d-%02d", y, m, d)
    }
}
