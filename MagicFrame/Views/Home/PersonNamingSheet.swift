import SwiftUI

/// Name a face cluster: first / last / maiden / display, with type-ahead from `people`.
struct PersonNamingSheet: View {

    let title: String
    var initialDisplayName: String = ""
    var onCancel: () -> Void
    var onSave: (_ displayName: String, _ firstName: String?, _ lastName: String?, _ maidenName: String?) -> Void

    @State private var firstName = ""
    @State private var lastName = ""
    @State private var maidenName = ""
    @State private var displayName = ""
    @State private var displayNameEdited = false
    @State private var knownPeople: [PeopleRepository.PersonRecord] = []

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("First name", text: $firstName)
                        .textContentType(.givenName)
                        .autocorrectionDisabled()
                    TextField("Last name", text: $lastName)
                        .textContentType(.familyName)
                        .autocorrectionDisabled()
                    TextField("Maiden name (optional)", text: $maidenName)
                        .autocorrectionDisabled()
                    TextField("Display name", text: $displayName)
                        .autocorrectionDisabled()
                        .onChange(of: displayName) { _, _ in
                            displayNameEdited = true
                        }
                }

                if !typeAheadMatches.isEmpty {
                    Section("Existing people") {
                        ForEach(typeAheadMatches) { person in
                            Button {
                                applyExistingPerson(person)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(person.displayName)
                                        .foregroundStyle(.primary)
                                    if let detail = personDetailLine(person) {
                                        Text(detail)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }

                Section {
                    Text("Display name is what People, events, and pickers show. It auto-fills from first + last until you edit it. Pick an existing person to reuse their name.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmedDisplay = resolvedDisplayName
                        guard !trimmedDisplay.isEmpty else { return }
                        onSave(
                            trimmedDisplay,
                            trimmedOptional(firstName),
                            trimmedOptional(lastName),
                            trimmedOptional(maidenName)
                        )
                    }
                    .disabled(resolvedDisplayName.isEmpty)
                }
            }
            .onChange(of: firstName) { _, _ in
                refreshDisplayNameIfNeeded()
            }
            .onChange(of: lastName) { _, _ in
                refreshDisplayNameIfNeeded()
            }
            .onAppear {
                displayName = initialDisplayName
                displayNameEdited = !initialDisplayName.isEmpty
                knownPeople = AppDependencies.database.fetchAllPeople()
            }
        }
    }

    /// Matches against display / first / last as the user types.
    private var typeAheadMatches: [PeopleRepository.PersonRecord] {
        let query = typeAheadQuery
        guard query.count >= 1 else { return [] }

        return knownPeople
            .filter { person in
                person.displayName.localizedCaseInsensitiveContains(query)
                    || (person.firstName?.localizedCaseInsensitiveContains(query) ?? false)
                    || (person.lastName?.localizedCaseInsensitiveContains(query) ?? false)
                    || fullName(person).localizedCaseInsensitiveContains(query)
            }
            .prefix(12)
            .map { $0 }
    }

    private var typeAheadQuery: String {
        let display = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !display.isEmpty { return display }
        return suggestedDisplayName
    }

    private var resolvedDisplayName: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return suggestedDisplayName
    }

    private var suggestedDisplayName: String {
        [firstName, lastName]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func refreshDisplayNameIfNeeded() {
        guard !displayNameEdited else { return }
        displayName = suggestedDisplayName
    }

    private func applyExistingPerson(_ person: PeopleRepository.PersonRecord) {
        firstName = person.firstName ?? ""
        lastName = person.lastName ?? ""
        maidenName = person.maidenName ?? ""
        displayName = person.displayName
        displayNameEdited = true
    }

    private func fullName(_ person: PeopleRepository.PersonRecord) -> String {
        [person.firstName, person.lastName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func personDetailLine(_ person: PeopleRepository.PersonRecord) -> String? {
        let parts = [person.firstName, person.lastName, person.maidenName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        let joined = parts.joined(separator: " ")
        if joined.compare(person.displayName, options: .caseInsensitive) == .orderedSame {
            return nil
        }
        return joined
    }

    private func trimmedOptional(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
