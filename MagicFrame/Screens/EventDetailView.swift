import SwiftUI

struct EventDetailView: View {

    @StateObject private var vm: EventDetailViewModel
    @State private var selectedPhotoIndex: Int?
    @State private var isConfirmingHideEvent = false
    @State private var isShowingAttributePicker = false
    @State private var attributePickerField: EventAttributeField?
    @State private var activeMilestonePersonPicker: MilestonePersonPickerKind?
    @State private var pendingMilestonePersonPicker: MilestonePersonPickerKind?
    @FocusState private var isNameFieldFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(
        event: IndexedEvent,
        onEventUpdated: ((Int) -> Void)? = nil,
        onEventHidden: ((Int) -> Void)? = nil,
        onEventUnhidden: ((Int) -> Void)? = nil
    ) {
        _vm = StateObject(
            wrappedValue: EventDetailViewModel(
                event: event,
                onEventUpdated: onEventUpdated,
                onEventHidden: onEventHidden,
                onEventUnhidden: onEventUnhidden
            )
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                nameSection
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                eventMetaSection
                    .padding(.horizontal, 16)

                photoGridHeader

                photoGrid

                if let objectStatus = vm.objectRecognitionStatus {
                    Text(objectStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                }

            }
        }
        .background(Color(.systemBackground))
        .navigationTitle("Event")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if vm.isSelectingPhotos {
                    Button("Cancel") {
                        vm.cancelPhotoSelection()
                    }
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                if vm.isSelectingPhotos {
                    Text("\(vm.selectedPhotoCount) selected")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 16) {
                        Button("Select") {
                            vm.beginPhotoSelection()
                        }

                        Menu {
                            Button(vm.showHiddenPhotos ? "Hide Hidden Photos" : "Show Hidden Photos") {
                                vm.toggleShowHiddenPhotos()
                            }

                            if vm.canLookupGameScore {
                                Button {
                                    Task { await vm.findGameScore() }
                                } label: {
                                    Label(
                                        vm.isLookingUpGameScore ? "Looking Up Score…" : "Find Game Score",
                                        systemImage: "sportscourt"
                                    )
                                }
                                .disabled(vm.isLookingUpGameScore)

                                if vm.gameResult != nil {
                                    Button("Clear Game Score", role: .destructive) {
                                        vm.clearSavedGameScore()
                                    }
                                }
                            }

                            if vm.isUserHidden {
                                Button("Unhide Event") {
                                    vm.unhideEvent()
                                }
                            } else {
                                Button("Hide Event", role: .destructive) {
                                    isConfirmingHideEvent = true
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .accessibilityLabel("More options")
                    }
                }
            }

            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    isNameFieldFocused = false
                    vm.saveEventName()
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if vm.isSelectingPhotos {
                photoSelectionBar
            }
        }
        .task(id: vm.event.eventId) {
            vm.loadPhotos()
            vm.loadClassificationOptions()
        }
        .onDisappear {
            vm.cancelObjectRecognition()
        }
        .sheet(isPresented: $vm.showGameLookupCandidates) {
            NavigationStack {
                List(vm.gameLookupCandidates) { candidate in
                    Button {
                        vm.saveGameCandidate(candidate)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            GameCoverScoreBoardView(
                                board: candidate.coverScoreBoard,
                                font: .body.weight(.semibold),
                                foregroundStyle: .primary
                            )
                            Text(candidate.detailLine)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .navigationTitle("Choose Game")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            vm.showGameLookupCandidates = false
                        }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .confirmationDialog(
            "Hide Event",
            isPresented: $isConfirmingHideEvent,
            titleVisibility: .visible
        ) {
            Button("Hide Event", role: .destructive) {
                vm.hideEvent()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This event will now be hidden. You can find this Event again by selecting Show Hidden Events."
            )
        }
        .alert(
            customOptionAlertTitle,
            isPresented: $vm.isAddingCustomOption
        ) {
            TextField("Name", text: $vm.newCustomOptionName)
            Button("Add") {
                vm.saveCustomOption()
            }
            Button("Cancel", role: .cancel) {
                vm.cancelAddingCustomOption()
            }
        } message: {
            Text(vm.customOptionField?.addCustomPrompt ?? "")
        }
        .fullScreenCover(isPresented: isFullscreenPresented) {
            EventPhotoFullscreenView(
                viewModel: vm,
                initialDisplayIndex: selectedPhotoIndex ?? 0,
                onDismiss: {
                    selectedPhotoIndex = nil
                    if vm.displayRepresentatives.isEmpty {
                        dismiss()
                    }
                }
            )
        }
        .sheet(isPresented: $isShowingAttributePicker) {
            EventAttributePickerSheet(
                viewModel: vm,
                selectedField: $attributePickerField,
                onDismiss: {
                    isShowingAttributePicker = false
                    attributePickerField = nil
                },
                onAddCustom: { field in
                    isShowingAttributePicker = false
                    attributePickerField = nil
                    vm.beginAddingCustomOption(for: field)
                },
                onMilestonePersonPickerRequested: { kind in
                    attributePickerField = nil
                    pendingMilestonePersonPicker = kind
                    isShowingAttributePicker = false
                }
            )
        }
        .onChange(of: isShowingAttributePicker) { _, isShowing in
            guard !isShowing, let kind = pendingMilestonePersonPicker else { return }
            pendingMilestonePersonPicker = nil
            activeMilestonePersonPicker = kind
        }
        .sheet(item: $activeMilestonePersonPicker) { kind in
            if kind.isCoupleMilestone {
                CoupleMilestonePickerSheet(
                    kind: kind,
                    items: vm.milestonePersonPickerItems(for: kind),
                    defaultWeddingDate: vm.defaultWeddingDate(),
                    onComplete: { person1, person2, weddingDate in
                        guard let person2 else { return }
                        vm.assignCoupleMilestone(
                            person1: person1,
                            person2: person2,
                            weddingDate: weddingDate
                        )
                    }
                )
            } else {
                MilestonePersonPickerSheet(
                    kind: kind,
                    items: vm.milestonePersonPickerItems(for: kind),
                    onSelect: { person in
                        vm.assignMilestonePerson(person)
                    }
                )
            }
        }
        .sheet(item: $vm.pendingSimilarEventAlternatives, onDismiss: {
            vm.pendingSimilarEventAlternatives = nil
        }) { request in
            SimilarEventAlternativesSheet(
                rejectedTagValue: request.rejectedTag.tagValue,
                alternatives: request.alternatives,
                onSelect: { alternative in
                    vm.applySimilarEventAlternative(alternative)
                },
                onSkip: {
                    vm.pendingSimilarEventAlternatives = nil
                }
            )
        }
        .sheet(item: $vm.pendingSimilarEventPeoplePick, onDismiss: {
            vm.pendingSimilarEventPeoplePick = nil
        }) { request in
            let personCount = max(1, min(2, request.alternative.possibleNumberOfEventMainPeople))
            CoupleMilestonePickerSheet(
                copy: .forSimilarEvent(
                    tagValue: request.alternative.possibleTagValue,
                    personCount: personCount
                ),
                personCount: personCount,
                items: request.people,
                defaultWeddingDate: vm.defaultWeddingDate(),
                includesWeddingDateStep: false,
                onComplete: { person1, person2, _ in
                    vm.completeSimilarEventPeoplePick(
                        person1: person1,
                        person2: person2
                    )
                }
            )
        }
    }

    private var isFullscreenPresented: Binding<Bool> {
        Binding(
            get: { selectedPhotoIndex != nil },
            set: { isPresented in
                if !isPresented {
                    selectedPhotoIndex = nil
                }
            }
        )
    }

    private var customOptionAlertTitle: String {
        if let field = vm.customOptionField {
            return "Add \(field.menuTitle)"
        }
        return "Add Option"
    }

    /// Tag control on the left; attribute chips flow in the remaining width above the photo grid.
    private var photoGridHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                attributePickerField = nil
                isShowingAttributePicker = true
            } label: {
                Image(systemName: "tag")
                    .font(.body.weight(.medium))
                    .frame(width: 36, height: 36)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Tags")

            selectedAttributeChips
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var selectedAttributeChips: some View {
        if !vm.event.libraryAttributeTags.isEmpty {
            FlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(vm.event.libraryAttributeTags) { tag in
                    EventAttributeTagChip(
                        tag: tag,
                        showsCategoryIcon: true,
                        showsScore: false,
                        onConfirmAI: tag.isAIDerived
                            ? {
                                if tag.category == .milestoneType,
                                   tag.tagValue.compare("Wedding", options: .caseInsensitive) == .orderedSame {
                                    vm.confirmAIWeddingMilestoneTag(tag)
                                    activeMilestonePersonPicker = .wedding
                                } else {
                                    vm.confirmAIAttributeTag(tag)
                                }
                            }
                            : nil,
                        onRemove: { vm.removeAttributeTag(tag) },
                        onShowScoreDetails: nil,
                        onTap: vm.isMilestonePersonPickerTag(tag) && !tag.isAIDerived
                            ? {
                                if let kind = MilestonePersonPickerKind.from(milestoneType: tag.tagValue) {
                                    activeMilestonePersonPicker = kind
                                }
                            }
                            : nil
                    )
                }
            }
        }
    }

    private var eventMetaSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let locationId = vm.event.locationId {
                NavigationLink {
                    LocationDetailView(locationId: locationId) {
                        vm.refreshEvent()
                    }
                } label: {
                    locationSummary(showChevron: true)
                }
                .buttonStyle(.plain)
            } else if vm.event.locationTitleLine != nil || vm.event.cityStateLine != nil {
                locationSummary(showChevron: false)
            }

            if let locationGeocodeStatus = vm.locationGeocodeStatus {
                Text(locationGeocodeStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let gameResult = vm.gameResult {
                VStack(alignment: .leading, spacing: 2) {
                    GameCoverScoreBoardView(
                        board: gameResult.coverScoreBoard,
                        font: .subheadline.weight(.semibold),
                        foregroundStyle: .primary
                    )
                    Text(
                        [
                            gameResult.league.displayName,
                            gameResult.venueName,
                        ]
                        .compactMap { $0 }
                        .filter { !$0.isEmpty }
                        .joined(separator: " · ")
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } else if let gameLookupStatus = vm.gameLookupStatus {
                Text(gameLookupStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                if vm.collapsedSimilarPhotoCount > 0 {
                    Text("\(vm.photoCount) photos · \(vm.visiblePhotoCount) shown · \(vm.videoCount) videos")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(vm.photoCount) photos · \(vm.videoCount) videos")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !vm.event.people.isEmpty {
                    Text(vm.event.people.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.blue)
                        .lineLimit(2)
                }
            }
        }
    }

    @ViewBuilder
    private func locationSummary(showChevron: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                if let locationTitle = vm.event.locationTitleLine {
                    Text(locationTitle)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                }

                if let cityState = vm.event.cityStateLine {
                    Text(cityState)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            if showChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
        }
        .contentShape(Rectangle())
    }

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Event name")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Spacer()

                if let status = vm.nameSaveStatus {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(status == "Saved" ? .green : .red)
                }
            }

            TextField("Event name", text: $vm.eventName)
                .font(.title2.bold())
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.words)
                .focused($isNameFieldFocused)
                .submitLabel(.done)
                .onSubmit {
                    isNameFieldFocused = false
                    vm.saveEventName()
                }
                .onChange(of: vm.eventName) { _, newValue in
                    if newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        != vm.suggestedName {
                        vm.markNameAsUserEdited()
                    }
                }

            if let suggestedName = vm.suggestedName,
               vm.showSuggestion {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Suggested name")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(alignment: .center, spacing: 12) {
                        Text(suggestedName)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Button("Use suggested name") {
                            vm.applySuggestedName()
                        }
                        .font(.subheadline)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var photoSelectionBar: some View {
        HStack(spacing: 12) {
            Button("Add to Frame") {
                vm.setSelectedPhotosOnFrame(true)
            }
            .buttonStyle(.borderedProminent)
            .disabled(vm.selectedPhotoCount == 0)

            Button("Remove from Frame") {
                vm.setSelectedPhotosOnFrame(false)
            }
            .buttonStyle(.bordered)
            .disabled(vm.selectedPhotoCount == 0)

            Button("Hide", role: .destructive) {
                if vm.hideSelectedPhotos() {
                    dismiss()
                }
            }
            .buttonStyle(.bordered)
            .disabled(vm.selectedPhotoCount == 0)
        }
        .font(.subheadline)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private func tripSectionHeader(_ section: TripPhotoDisplaySection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Day \(section.section.dayNumber)")
                .font(.headline)

            TextField("Day name", text: vm.tripChildEventNameBinding(subEventId: section.section.subEventId))
                .font(.subheadline)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                .onSubmit {
                    vm.saveTripChildEventName(subEventId: section.section.subEventId)
                }
        }
        .padding(.horizontal, 16)
    }

    private var photoGridSections: [PhotoGridSection] {
        if vm.event.isTripContainer, !vm.tripPhotoDisplaySections.isEmpty {
            return vm.tripPhotoDisplaySections.map { section in
                PhotoGridSection(id: "trip-\(section.id)", items: section.displayItems)
            }
        }
        return [PhotoGridSection(id: "photos", items: vm.photoDisplayItems)]
    }

    private var photoGrid: some View {
        PhotoGrid(
            sections: photoGridSections,
            isSelecting: vm.isSelectingPhotos,
            selectedPhotoIds: vm.selectedPhotoIds,
            onTap: { item in
                if vm.isSelectingPhotos {
                    vm.toggleDisplayItemSelection(item)
                } else if let index = vm.fullscreenDisplayItems.firstIndex(where: { $0.id == item.id }) {
                    selectedPhotoIndex = index
                }
            },
            sectionHeader: { section in
                if let trip = vm.tripPhotoDisplaySections.first(where: { "trip-\($0.id)" == section.id }) {
                    tripSectionHeader(trip)
                }
            },
            contextMenu: { item in
                Button(item.representative.showOnFrame ? "Remove from Frame" : "Add to Frame") {
                    vm.togglePhotoOnFrame(
                        photoId: item.representative.id,
                        in: item.isStack ? item.group : nil
                    )
                }
                Button("Hide") {
                    if vm.hideDisplayItem(item) {
                        dismiss()
                    }
                }
            }
        )
    }
}

private struct EventAttributePickerSheet: View {

    @ObservedObject var viewModel: EventDetailViewModel
    @Binding var selectedField: EventAttributeField?
    let onDismiss: () -> Void
    let onAddCustom: (EventAttributeField) -> Void
    let onMilestonePersonPickerRequested: (MilestonePersonPickerKind) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if let field = selectedField {
                    attributeOptionsList(for: field)
                } else {
                    attributeCategoryList
                }
            }
            .navigationTitle(selectedField?.menuTitle ?? "Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(selectedField == nil ? "Done" : "Back") {
                        if selectedField != nil {
                            selectedField = nil
                        } else {
                            onDismiss()
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var attributeCategoryList: some View {
        List(EventAttributeField.tagMenuCases) { field in
            Button {
                if field == .tripType {
                    viewModel.setSelection("Trip", for: .tripType)
                    onDismiss()
                } else {
                    selectedField = field
                }
            } label: {
                HStack {
                    Label(field.menuTitle, systemImage: field.iconName)
                    Spacer()
                    if field == .tripType,
                       viewModel.selection(for: .tripType) != nil {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func attributeOptionsList(for field: EventAttributeField) -> some View {
        List {
            if let current = viewModel.selection(for: field) {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: field.iconName)
                            .foregroundStyle(.secondary)
                        Text(current)
                    }
                }
            }

            Section {
                Button("Unset", role: .destructive) {
                    viewModel.setSelection(nil, for: field)
                    onDismiss()
                }
            }

            if !viewModel.options(for: field).isEmpty {
                Section {
                    ForEach(viewModel.options(for: field), id: \.self) { option in
                        Button(option) {
                            viewModel.setSelection(option, for: field)
                            if field == .milestoneType,
                               let kind = MilestonePersonPickerKind.from(milestoneType: option) {
                                onMilestonePersonPickerRequested(kind)
                            } else {
                                onDismiss()
                            }
                        }
                    }
                }
            }

            if field.allowsCustomOptions {
                Section {
                    Button("Add custom...") {
                        onAddCustom(field)
                    }
                }
            }
        }
    }
}

private struct SimilarPhotoGroupPickerView: View {

    let group: SimilarPhotoGroup
    @Binding var selectedPhotoIds: Set<String>
    let onDone: () -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var previewPhotoId: String?

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 2),
        count: 3
    )

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Choose the best shot\(group.photos.count == 1 ? "" : "s") to show. Other similar photos stay in this burst.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)

                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(group.photos, id: \.id) { photo in
                            photoCell(photo)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .navigationTitle("Similar Photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        onDone()
                        dismiss()
                    }
                }
            }
            .fullScreenCover(isPresented: isPreviewPresented) {
                if let photoId = previewPhotoId {
                    PhotoPreviewView(
                        items: [
                            EventPhotoDisplayItem(
                                group: group,
                                representative: group.photos.first { $0.id == photoId }
                                    ?? group.autoBestPhoto()
                            )
                        ],
                        resolvingPhotos: group.photos,
                        initialIndex: 0,
                        initialPhotoId: photoId,
                        showsActionBar: false,
                        onDismiss: { previewPhotoId = nil },
                        header: { context in
                            PhotoPreviewStandardHeader(
                                index: context.displayIndex + 1,
                                count: context.displayCount,
                                showsCounter: !context.isZoomed,
                                onClose: { previewPhotoId = nil }
                            )
                        },
                        actions: { _ in
                            EmptyView()
                        }
                    )
                }
            }
        }
        .onAppear {
            if selectedPhotoIds.isEmpty {
                selectedPhotoIds = [group.autoBestPhoto().id]
            }
        }
    }

    private var isPreviewPresented: Binding<Bool> {
        Binding(
            get: { previewPhotoId != nil },
            set: { isPresented in
                if !isPresented {
                    previewPhotoId = nil
                }
            }
        )
    }

    private func photoCell(_ photo: IndexedPhoto) -> some View {
        let isSelected = selectedPhotoIds.contains(photo.id)

        return Button {
            toggleSelection(for: photo.id)
        } label: {
            PhotoThumbnailView(
                assetIdentifier: photo.id,
                cornerRadius: 0,
                quality: .high
            )
            .aspectRatio(1, contentMode: .fill)
            .clipped()
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 0)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                    RoundedRectangle(cornerRadius: 0)
                        .fill(Color.accentColor.opacity(0.18))
                }
            }
            .overlay(alignment: .topTrailing) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, isSelected ? Color.accentColor : Color.black.opacity(0.35))
                    .padding(6)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Preview") {
                previewPhotoId = photo.id
            }
        }
    }

    private func toggleSelection(for photoId: String) {
        if selectedPhotoIds.contains(photoId) {
            if selectedPhotoIds.count > 1 {
                selectedPhotoIds.remove(photoId)
            }
        } else {
            selectedPhotoIds.insert(photoId)
        }
    }
}
