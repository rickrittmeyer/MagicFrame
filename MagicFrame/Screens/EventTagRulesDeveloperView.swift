import SwiftUI

/// Developer tools to manage `similar_event_tags` and `event_name_templates`.
struct EventTagRulesDeveloperView: View {

    @State private var similarTags: [SimilarEventTagAlternative] = []
    @State private var nameTemplates: [EventNameTemplate] = []
    @State private var statusMessage: String?

    // Similar-event add form
    @State private var sourceCategory = EventAttributeField.milestoneType.tagCategory
    @State private var sourceValue = "Wedding"
    @State private var possibleCategory = EventAttributeField.milestoneType.tagCategory
    @State private var possibleValue = ""
    @State private var possiblePeopleCount = 1

    // Name-template add form
    @State private var templateCategory = EventAttributeField.milestoneType.tagCategory
    @State private var templateTagValue = ""
    @State private var templatePattern = "{person1}'s {tagValue}"
    @State private var templatePersonCount = 1

    private let categoryChoices: [(label: String, value: String)] = EventAttributeField.tagMenuCases.map {
        ($0.menuTitle, $0.tagCategory)
    }

    var body: some View {
        Form {
            if let statusMessage {
                Section {
                    Text(statusMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            similarEventSection
            nameTemplateSection
        }
        .navigationTitle("Event Tag Rules")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
    }

    // MARK: - Similar event tags

    private var similarEventSection: some View {
        Group {
            Section {
                Text(
                    "When the user removes an AI tag matching Source, offer Possible as alternatives. "
                        + "People count drives the post-pick person sheet (0–2)."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } header: {
                Text("Similar event tags")
            }

            Section("Add similar event tag") {
                categoryPicker("Source category", selection: $sourceCategory)
                TextField("Source tag value (e.g. Wedding)", text: $sourceValue)
                    .textInputAutocapitalization(.words)
                categoryPicker("Possible category", selection: $possibleCategory)
                TextField("Possible tag value (e.g. Senior Prom)", text: $possibleValue)
                    .textInputAutocapitalization(.words)
                Stepper("Main people: \(possiblePeopleCount)", value: $possiblePeopleCount, in: 0...2)

                Button("Add Similar Event Tag") {
                    addSimilarEventTag()
                }
                .disabled(!canAddSimilarTag)
            }

            Section("Existing similar event tags") {
                if similarTags.isEmpty {
                    Text("None yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(similarTags) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(row.tagValue) → \(row.possibleTagValue)")
                                .font(.body.weight(.medium))
                            Text(
                                "\(row.tagCategory) → \(row.possibleTagCategory) · "
                                    + "\(row.possibleNumberOfEventMainPeople) people"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Name templates

    private var nameTemplateSection: some View {
        Group {
            Section {
                Text(
                    "Suggested event names for a tag. Placeholders: {person1}, {person2}, {tagValue}. "
                        + "Wedding uses bride=person1, groom=person2."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } header: {
                Text("Suggested name templates")
            }

            Section("Add / update name template") {
                categoryPicker("Tag category", selection: $templateCategory)
                TextField("Tag value (e.g. Senior Prom)", text: $templateTagValue)
                    .textInputAutocapitalization(.words)
                TextField("Template", text: $templatePattern)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Stepper("Person count: \(templatePersonCount)", value: $templatePersonCount, in: 1...2)

                if let preview = templatePreview {
                    Text("Preview: \(preview)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("Save Name Template") {
                    saveNameTemplate()
                }
                .disabled(!canSaveTemplate)
            }

            Section("Existing name templates") {
                if nameTemplates.isEmpty {
                    Text("None yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(nameTemplates) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.tagValue)
                                .font(.body.weight(.medium))
                            Text(row.nameTemplate)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("\(row.tagCategory) · \(row.personCount) people")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            templateCategory = row.tagCategory
                            templateTagValue = row.tagValue
                            templatePattern = row.nameTemplate
                            templatePersonCount = max(1, min(2, row.personCount))
                            statusMessage = "Loaded “\(row.tagValue)” into the form."
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private var canAddSimilarTag: Bool {
        !sourceCategory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !sourceValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !possibleCategory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !possibleValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSaveTemplate: Bool {
        !templateCategory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !templateTagValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !templatePattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var templatePreview: String? {
        guard canSaveTemplate else { return nil }
        return MilestoneEventNaming.applyNameTemplate(
            templatePattern,
            person1: "Alex",
            person2: templatePersonCount >= 2 ? "Jordan" : nil,
            tagValue: templateTagValue
        )
    }

    @ViewBuilder
    private func categoryPicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            ForEach(categoryChoices, id: \.value) { choice in
                Text(choice.label).tag(choice.value)
            }
        }
    }

    private func reload() {
        similarTags = AppDependencies.database.fetchAllSimilarEventTags()
        nameTemplates = AppDependencies.database.fetchAllEventNameTemplates()
    }

    private func addSimilarEventTag() {
        guard let row = AppDependencies.database.insertSimilarEventTag(
            tagCategory: sourceCategory,
            tagValue: sourceValue,
            possibleTagCategory: possibleCategory,
            possibleTagValue: possibleValue,
            possibleNumberOfEventMainPeople: possiblePeopleCount
        ) else {
            statusMessage = "Could not add similar event tag."
            return
        }
        possibleValue = ""
        statusMessage = "Added \(row.tagValue) → \(row.possibleTagValue)."
        reload()
    }

    private func saveNameTemplate() {
        guard let row = AppDependencies.database.upsertEventNameTemplate(
            tagCategory: templateCategory,
            tagValue: templateTagValue,
            nameTemplate: templatePattern,
            personCount: templatePersonCount
        ) else {
            statusMessage = "Could not save name template."
            return
        }
        statusMessage = "Saved name template for \(row.tagValue)."
        reload()
    }
}
