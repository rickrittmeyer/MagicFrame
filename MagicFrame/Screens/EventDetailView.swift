import CoreLocation
import SwiftUI

struct PendingOutsidePhotoMove {
    let destination: IndexedEvent
    let dates: [String: Date]
    let window: PhotoMoveWindow
}

struct EventDetailView: View {

    @StateObject private var vm: EventDetailViewModel
    @State private var selectedPhotoIndex: Int?
    @State private var isConfirmingHideEvent = false
    @State private var isShowingAttributePicker = false
    @State private var attributePickerField: EventAttributeField?
    @State private var activeMilestonePersonPicker: MilestonePersonPickerKind?
    @State private var pendingMilestonePersonPicker: MilestonePersonPickerKind?
    @State private var isShowingEventScoreCards = false
    @State private var isShowingAdjustDateSheet = false
    @State private var isShowingAdjustLocationSheet = false
    @State private var pendingDateAdjustPreview: PhotoDateAdjustPreview?
    @State private var pendingLocationAdjustPreview: PhotoLocationAdjustPreview?
    @State private var isShowingLeaveEventPrompt = false
    @State private var isShowingExistingEventPicker = false
    @State private var candidateEventsForDateAdjust: [IndexedEvent] = []
    @State private var isShowingMoveEventPicker = false
    @State private var moveTargetEvents: [IndexedEvent] = []
    @State private var pendingOutsideMove: PendingOutsidePhotoMove?
    @State private var isShowingOutsideMoveDialog = false
    @State private var isShowingYearExtendDialog = false
    @State private var isShowingInsideDatePicker = false
    @State private var insideMoveDate = Date()
    @State private var isShowingNoMatchingEventAlert = false
    @State private var dateAdjustSuccessEvent: IndexedEvent?
    @State private var isShowingDateAdjustSuccess = false
    @State private var shouldDismissAfterDateAdjust = false
    @State private var destinationEventToOpen: IndexedEvent?
    @State private var isNavigatingToDestinationEvent = false
    @State private var dateAdjustErrorMessage: String?
    @State private var pendingApplePhotosDateUpdates: [(photoId: String, newDate: Date)] = []
    @State private var isShowingApplePhotosSyncConfirm = false
    @State private var isSyncingApplePhotosDates = false
    @State private var pendingApplePhotosLocationUpdates: [(photoId: String, latitude: Double, longitude: Double)] = []
    @State private var isShowingApplePhotosLocationSyncConfirm = false
    @State private var isSyncingApplePhotosLocations = false
    @State private var locationAdjustErrorMessage: String?
    @State private var isShowingDuplicatesSheet = false
    @State private var pendingDuplicateDeleteIds: [String] = []
    @State private var isConfirmingDuplicateDelete = false
    @State private var isDeletingDuplicates = false
    @State private var duplicateActionErrorMessage: String?
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
        eventDetailChrome
            .sheet(isPresented: $isShowingAdjustLocationSheet) {
                PhotoAdjustLocationSheet(
                    originalLabel: vm.adjustLocationAnchorLabel,
                    originalCoordinate: vm.adjustLocationAnchorCoordinate.map {
                        CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                    },
                    selectedCount: vm.selectedPhotoCount,
                    locations: vm.locationsForAdjust(),
                    onCancel: {
                        isShowingAdjustLocationSheet = false
                    },
                    onAdjust: { location in
                        isShowingAdjustLocationSheet = false
                        handleLocationAdjust(location: location)
                    }
                )
            }
            .alert(
                "Also update these photos in Apple Photos?",
                isPresented: $isShowingApplePhotosLocationSyncConfirm
            ) {
                Button("Update Photos") {
                    Task { await confirmApplePhotosLocationSync(shouldSync: true) }
                }
                Button("Not Now", role: .cancel) {
                    Task { await confirmApplePhotosLocationSync(shouldSync: false) }
                }
            } message: {
                Text(
                    "This will change the location stored in the Photos app for the selected photos."
                )
            }
            .alert(
                "Couldn’t Adjust Location",
                isPresented: Binding(
                    get: { locationAdjustErrorMessage != nil },
                    set: { if !$0 { locationAdjustErrorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(locationAdjustErrorMessage ?? "")
            }
            .sheet(isPresented: $isShowingDuplicatesSheet) {
                EventDuplicatesReviewSheet(
                    matches: vm.duplicateMatches,
                    onCancel: {
                        isShowingDuplicatesSheet = false
                    },
                    onHide: { photoIds in
                        vm.hideDuplicatePhotos(photoIds: photoIds)
                        if vm.duplicateMatches.isEmpty {
                            isShowingDuplicatesSheet = false
                        }
                    },
                    onDelete: { photoIds in
                        pendingDuplicateDeleteIds = photoIds
                        isConfirmingDuplicateDelete = true
                    }
                )
            }
            .alert(
                "Delete Selected Photos?",
                isPresented: $isConfirmingDuplicateDelete
            ) {
                Button("Delete", role: .destructive) {
                    let ids = pendingDuplicateDeleteIds
                    pendingDuplicateDeleteIds = []
                    Task { await deleteSelectedDuplicates(ids) }
                }
                Button("Cancel", role: .cancel) {
                    pendingDuplicateDeleteIds = []
                }
            } message: {
                Text(
                    "This removes \(pendingDuplicateDeleteIds.count) photo\(pendingDuplicateDeleteIds.count == 1 ? "" : "s") from Magic Frame and Apple Photos."
                )
            }
            .alert(
                "Couldn’t Finish Delete",
                isPresented: Binding(
                    get: { duplicateActionErrorMessage != nil },
                    set: { if !$0 { duplicateActionErrorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(duplicateActionErrorMessage ?? "")
            }
            .overlay {
                if isDeletingDuplicates {
                    ZStack {
                        Color.black.opacity(0.25).ignoresSafeArea()
                        ProgressView("Deleting…")
                            .padding(20)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .allowsHitTesting(true)
                }
            }
    }

    @ViewBuilder
    private var duplicatesFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                vm.findDuplicates()
            } label: {
                HStack {
                    if vm.isFindingDuplicates {
                        ProgressView()
                    } else {
                        Image(systemName: "doc.on.doc")
                    }
                    Text(vm.isFindingDuplicates ? "Finding Duplicates…" : "Find Duplicates")
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .disabled(vm.isFindingDuplicates || vm.isRunningAIAssist)

            if let duplicateScanStatus = vm.duplicateScanStatus {
                Text(duplicateScanStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }

            if !vm.duplicateMatches.isEmpty {
                Button {
                    isShowingDuplicatesSheet = true
                } label: {
                    HStack {
                        Image(systemName: "eye")
                        Text("Duplicates detected")
                        Spacer()
                        Text("\(vm.duplicateMatches.count)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    @MainActor
    private func deleteSelectedDuplicates(_ photoIds: [String]) async {
        isDeletingDuplicates = true
        let error = await vm.deleteDuplicatePhotos(photoIds: photoIds)
        isDeletingDuplicates = false
        if let error {
            duplicateActionErrorMessage = error
        }
        if vm.duplicateMatches.isEmpty {
            isShowingDuplicatesSheet = false
        }
    }

    private var eventDetailChrome: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16, pinnedViews: [.sectionHeaders]) {
                eventMetaSection
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                photoGridHeader

                Section {
                    photoGridContent

                    if let objectStatus = vm.objectRecognitionStatus {
                        Text(objectStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                    }

                    duplicatesFooter
                } header: {
                    stickyPhotoControlsBar
                }
            }
        }
        .background(Color(.systemBackground))
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $isShowingEventScoreCards) {
            EventScoreCardsListView()
        }
        .navigationDestination(isPresented: $isNavigatingToDestinationEvent) {
            if let destinationEventToOpen {
                EventDetailView(
                    event: destinationEventToOpen,
                    onEventUpdated: vm.onEventUpdated,
                    onEventHidden: vm.onEventHidden,
                    onEventUnhidden: vm.onEventUnhidden
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(vm.eventName)
                    .font(.headline)
                    .foregroundStyle(vm.userEditedName ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityLabel("Event name")
            }

            ToolbarItem(placement: .topBarLeading) {
                if vm.isSelectingPhotos {
                    Button("Cancel") {
                        vm.cancelPhotoSelection()
                    }
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                if !vm.isSelectingPhotos {
                    HStack(spacing: 16) {
                        Button {
                            vm.runAIAssist()
                        } label: {
                            if vm.isRunningAIAssist {
                                ProgressView()
                            } else {
                                Image(systemName: "sparkles")
                            }
                        }
                        .disabled(vm.isRunningAIAssist)
                        .accessibilityLabel("AI Assist")

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
                .navigationTitle(
                    vm.gameLookupCandidates.count == 1 ? "Confirm Game Score" : "Choose Game"
                )
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Dismiss") {
                            vm.dismissGameLookupCandidates()
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
        .sheet(isPresented: $isShowingAdjustDateSheet) {
            if let originalDate = vm.adjustDateAnchorDate {
                PhotoAdjustDateTimeSheet(
                    originalDate: originalDate,
                    selectedCount: vm.selectedPhotoCount,
                    onCancel: {
                        isShowingAdjustDateSheet = false
                    },
                    onAdjust: { adjustedDate, _ in
                        isShowingAdjustDateSheet = false
                        handleDateAdjust(adjustedAnchor: adjustedDate)
                    }
                )
            }
        }
        .confirmationDialog(
            "Change Event?",
            isPresented: $isShowingLeaveEventPrompt,
            titleVisibility: .visible
        ) {
            Button("Create New Event") {
                runAfterDialogDismisses {
                    Task { await commitDateAdjust(destination: .createNew) }
                }
            }
            Button("Add to Existing Event") {
                runAfterDialogDismisses {
                    presentExistingEventChoices()
                }
            }
            Button("Cancel", role: .cancel) {
                pendingDateAdjustPreview = nil
            }
        } message: {
            Text(
                "Changing the dates of these photos will remove them from this event. Do you want to create a new event with these photos, or add them to an existing event with the same date range?"
            )
        }
        .sheet(isPresented: $isShowingExistingEventPicker) {
            PhotoDateAdjustEventPickerSheet(
                events: candidateEventsForDateAdjust,
                onCancel: {
                    isShowingExistingEventPicker = false
                    pendingDateAdjustPreview = nil
                },
                onSelect: { event in
                    isShowingExistingEventPicker = false
                    runAfterDialogDismisses {
                        Task { await commitDateAdjust(destination: .existing(eventId: event.eventId)) }
                    }
                }
            )
        }
        .background { photoMovePrompts }
        .overlay {
            if vm.isAdjustingDates || vm.isAdjustingLocations || vm.isMovingPhotos
                || isSyncingApplePhotosDates || isSyncingApplePhotosLocations {
                ZStack {
                    Color.black.opacity(0.25).ignoresSafeArea()
                    ProgressView(progressOverlayTitle)
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
                .allowsHitTesting(true)
            }
        }
        .alert(
            "No Matching Events",
            isPresented: $isShowingNoMatchingEventAlert
        ) {
            Button("Create New Event") {
                Task { await commitDateAdjust(destination: .createNew) }
            }
            Button("Cancel", role: .cancel) {
                pendingDateAdjustPreview = nil
            }
        } message: {
            Text("No existing events contain this date range. Create a new event instead?")
        }
        .alert(
            "Also update these photos in Apple Photos?",
            isPresented: $isShowingApplePhotosSyncConfirm
        ) {
            Button("Update Photos") {
                Task { await confirmApplePhotosDateSync(shouldSync: true) }
            }
            Button("Not Now", role: .cancel) {
                Task { await confirmApplePhotosDateSync(shouldSync: false) }
            }
        } message: {
            Text(
                "This will change the date/time stored in the Photos app for the selected photos."
            )
        }
        .alert(
            "Photos Moved",
            isPresented: $isShowingDateAdjustSuccess
        ) {
            Button("Go to Event") {
                if let event = dateAdjustSuccessEvent {
                    destinationEventToOpen = event
                    isNavigatingToDestinationEvent = true
                }
            }
            Button(shouldDismissAfterDateAdjust ? "Close Event" : "Stay Here", role: .cancel) {
                if shouldDismissAfterDateAdjust {
                    dismiss()
                }
            }
        } message: {
            if let event = dateAdjustSuccessEvent {
                Text(
                    "These pictures were added to \(PhotoDateAdjustResult.eventSummaryLine(for: event)). Do you want to go to that event?"
                )
            }
        }
        .alert(
            "Couldn’t Adjust Date",
            isPresented: Binding(
                get: { dateAdjustErrorMessage != nil },
                set: { if !$0 { dateAdjustErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(dateAdjustErrorMessage ?? "")
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
        .sheet(isPresented: $vm.showWeddingCoupleNaming) {
            if let photoId = vm.weddingCoupleNamingPhotoId,
               vm.weddingCoupleNamingFaces.count >= 2 {
                WeddingCoupleNamingSheet(
                    photoId: photoId,
                    faces: vm.weddingCoupleNamingFaces,
                    defaultWeddingDate: vm.defaultWeddingDate(),
                    onComplete: { brideFaceId, brideName, groomFaceId, groomName, weddingDate in
                        vm.completeWeddingCoupleNaming(
                            brideFaceId: brideFaceId,
                            brideName: brideName,
                            groomFaceId: groomFaceId,
                            groomName: groomName,
                            weddingDate: weddingDate
                        )
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

    /// Tag control on the left; Developer and attribute chips flow in the remaining width.
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

    private var selectedAttributeChips: some View {
        FlowLayout(spacing: 8, lineSpacing: 8) {
            developerTag

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
                                if !vm.showWeddingCoupleNaming {
                                    activeMilestonePersonPicker = .wedding
                                }
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

    /// Opens the Event Score Cards list.
    private var developerTag: some View {
        Button {
            isShowingEventScoreCards = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "hammer.fill")
                    .font(.caption2.weight(.semibold))
                Text("Developer")
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(.tertiarySystemFill))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Developer")
        .accessibilityHint("Opens Event Score Cards")
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

            if let eventDate = EventDateParser.detailDisplayDateRange(
                startDate: vm.event.startDate,
                endDate: vm.event.endDate
            ) {
                Text(eventDate)
                    .font(.subheadline)
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

    private var photoSelectionBar: some View {
        PhotoSelectionToggleBar(
            isEnabled: vm.selectedPhotoCount > 0,
            isFrameOn: vm.selectedAllOnFrame,
            isFavoriteOn: vm.selectedAllFavorite,
            isHiddenOn: vm.selectedAllHidden,
            onToggleFrame: {
                vm.toggleSelectedPhotosOnFrame()
            },
            onToggleFavorite: {
                vm.toggleSelectedPhotosFavorite()
            },
            onToggleHide: {
                if vm.toggleSelectedPhotosHidden() {
                    dismiss()
                }
            },
            onAdjustDate: {
                guard vm.adjustDateAnchorDate != nil else { return }
                isShowingAdjustDateSheet = true
            },
            onAdjustLocation: {
                guard vm.selectedPhotoCount > 0 else { return }
                isShowingAdjustLocationSheet = true
            },
            onMoveToEveryday: {
                guard vm.selectedPhotoCount > 0 else { return }
                Task { await vm.moveSelectedPhotosToEveryday() }
            },
            onMoveToEvent: {
                guard vm.selectedPhotoCount > 0 else { return }
                moveTargetEvents = vm.eventsForPhotoMove()
                isShowingMoveEventPicker = true
            }
        )
    }

    private var progressOverlayTitle: String {
        if isSyncingApplePhotosDates || isSyncingApplePhotosLocations {
            return "Updating Apple Photos…"
        }
        if vm.isAdjustingLocations {
            return "Updating locations…"
        }
        if vm.isMovingPhotos {
            return "Moving photos…"
        }
        return "Updating dates…"
    }

    private func handleDateAdjust(adjustedAnchor: Date) {
        guard let preview = vm.makeDateAdjustPreview(adjustedAnchor: adjustedAnchor) else {
            dateAdjustErrorMessage = "Could not prepare date adjustment."
            return
        }
        pendingDateAdjustPreview = preview
        if preview.leavesCurrentEvent {
            // Wait for the adjust sheet to finish dismissing before the next presentation.
            runAfterDialogDismisses {
                isShowingLeaveEventPrompt = true
            }
        } else {
            Task { await commitDateAdjust(destination: nil) }
        }
    }

    private var photoMovePrompts: some View {
        let outsideCount = pendingOutsideMove?.window.outside.count ?? 0
        let insideDateTitle = outsideCount > 1 ? "Change all photo dates" : "Choose a date in the event"
        let eventSummary = pendingOutsideMove?.destination.listTitleText ?? ""
        let moveMessage = pendingOutsideMove?.window.message(eventSummary: eventSummary) ?? ""
        return Color.clear
            .sheet(isPresented: $isShowingMoveEventPicker) {
                PhotoDateAdjustEventPickerSheet(
                    events: moveTargetEvents,
                    onCancel: {
                        isShowingMoveEventPicker = false
                    },
                    onSelect: { event in
                        isShowingMoveEventPicker = false
                        beginMoveToExistingEvent(event)
                    }
                )
            }
            .confirmationDialog(
                "Photo date is outside this event",
                isPresented: $isShowingOutsideMoveDialog,
                titleVisibility: .visible
            ) {
                Button(insideDateTitle) {
                    if let window = pendingOutsideMove?.window {
                        insideMoveDate = window.windowStart
                    }
                    isShowingInsideDatePicker = true
                }
                Button("Extend the event") {
                    if pendingOutsideMove?.window.needsYearConfirmation == true {
                        isShowingYearExtendDialog = true
                    } else {
                        commitPendingMove(expandDestinationDates: true)
                    }
                }
                Button("Cancel", role: .cancel) {
                    pendingOutsideMove = nil
                }
            } message: {
                Text(moveMessage)
            }
            .confirmationDialog(
                "This extends the event by more than a year",
                isPresented: $isShowingYearExtendDialog,
                titleVisibility: .visible
            ) {
                Button("Extend the event") {
                    commitPendingMove(expandDestinationDates: true)
                }
                Button("Cancel", role: .cancel) {
                    pendingOutsideMove = nil
                }
            } message: {
                Text(moveMessage)
            }
            .sheet(isPresented: $isShowingInsideDatePicker) {
                insideDatePicker
            }
    }

    private func beginMoveToExistingEvent(_ destination: IndexedEvent) {
        let dates = vm.selectedPhotoDateMap()
        guard let window = vm.moveWindow(for: destination, dates: dates) else { return }
        if window.isEmpty {
            vm.moveSelectedPhotos(
                to: destination.eventId,
                dates: dates,
                expandDestinationDates: false
            )
            return
        }
        pendingOutsideMove = PendingOutsidePhotoMove(
            destination: destination,
            dates: dates,
            window: window
        )
        isShowingOutsideMoveDialog = true
    }

    private func commitPendingMove(expandDestinationDates: Bool) {
        guard let pending = pendingOutsideMove else { return }
        pendingOutsideMove = nil
        vm.moveSelectedPhotos(
            to: pending.destination.eventId,
            dates: pending.dates,
            expandDestinationDates: expandDestinationDates
        )
    }

    private func commitInsideDateMove() {
        guard let pending = pendingOutsideMove else { return }
        let updates = pending.window.outside.map { (photoId: $0.photoId, newCreationDate: insideMoveDate) }
        let destinationId = pending.destination.eventId
        let dates = pending.dates
        pendingOutsideMove = nil
        vm.applyInsideDatesThenMove(
            updates: updates,
            destinationId: destinationId,
            dates: dates
        )
    }

    private var insideDatePicker: some View {
        NavigationStack {
            VStack(spacing: 16) {
                DatePicker(
                    "Date inside the event",
                    selection: $insideMoveDate,
                    in: (pendingOutsideMove?.window.windowStart ?? Date()) ... (pendingOutsideMove?.window.windowEnd ?? Date()),
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .padding()
                Spacer()
            }
            .navigationTitle("Date inside the event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isShowingInsideDatePicker = false
                        pendingOutsideMove = nil
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use this date") {
                        isShowingInsideDatePicker = false
                        commitInsideDateMove()
                    }
                }
            }
        }
    }

    private func presentExistingEventChoices() {
        guard let preview = pendingDateAdjustPreview else { return }
        let candidates = vm.candidateEventsForDateAdjust(preview: preview)
        if candidates.isEmpty {
            isShowingNoMatchingEventAlert = true
        } else if candidates.count == 1, let only = candidates.first {
            Task { await commitDateAdjust(destination: .existing(eventId: only.eventId)) }
        } else {
            candidateEventsForDateAdjust = candidates
            isShowingExistingEventPicker = true
        }
    }

    /// Avoid SwiftUI freezes from presenting a sheet/alert while another dialog is still dismissing.
    private func runAfterDialogDismisses(_ action: @escaping () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            action()
        }
    }

    @MainActor
    private func commitDateAdjust(destination: PhotoDateAdjustDestination?) async {
        guard let preview = pendingDateAdjustPreview else { return }
        let photosUpdates = preview.updates.map { (photoId: $0.photoId, newDate: $0.newDate) }
        let result = await vm.commitDateAdjust(preview: preview, destination: destination)
        pendingDateAdjustPreview = nil

        // Dates are always written first; only abort the Photos prompt when the user still
        // needs to pick a destination (incomplete leave-event flow).
        if let error = result.errorMessage,
           result.destinationEvent == nil,
           destination == nil,
           preview.leavesCurrentEvent {
            dateAdjustErrorMessage = error
            return
        }

        if let error = result.errorMessage, result.destinationEvent == nil, destination != nil {
            dateAdjustErrorMessage = error
        }

        pendingApplePhotosDateUpdates = photosUpdates
        dateAdjustSuccessEvent = result.destinationEvent
        shouldDismissAfterDateAdjust = result.sourceEmptied

        runAfterDialogDismisses {
            isShowingApplePhotosSyncConfirm = true
        }
    }

    @MainActor
    private func confirmApplePhotosDateSync(shouldSync: Bool) async {
        let updates = pendingApplePhotosDateUpdates
        pendingApplePhotosDateUpdates = []

        if shouldSync, !updates.isEmpty {
            isSyncingApplePhotosDates = true
            let error = await vm.syncAdjustedDatesToApplePhotos(updates)
            isSyncingApplePhotosDates = false
            if let error {
                dateAdjustErrorMessage = error
            }
        }

        if dateAdjustSuccessEvent != nil {
            runAfterDialogDismisses {
                isShowingDateAdjustSuccess = true
            }
        } else if shouldDismissAfterDateAdjust {
            dismiss()
        }
    }

    private func handleLocationAdjust(location: ManagedLocation) {
        guard let preview = vm.makeLocationAdjustPreview(location: location) else {
            locationAdjustErrorMessage = "Could not prepare location adjustment."
            return
        }
        pendingLocationAdjustPreview = preview
        Task { await commitLocationAdjust() }
    }

    @MainActor
    private func commitLocationAdjust() async {
        guard let preview = pendingLocationAdjustPreview else { return }
        let photosUpdates = preview.photoIds.map {
            (photoId: $0, latitude: preview.latitude, longitude: preview.longitude)
        }
        let result = await vm.commitLocationAdjust(preview: preview)
        pendingLocationAdjustPreview = nil

        if let error = result.errorMessage {
            locationAdjustErrorMessage = error
            return
        }

        pendingApplePhotosLocationUpdates = photosUpdates
        runAfterDialogDismisses {
            isShowingApplePhotosLocationSyncConfirm = true
        }
    }

    @MainActor
    private func confirmApplePhotosLocationSync(shouldSync: Bool) async {
        let updates = pendingApplePhotosLocationUpdates
        pendingApplePhotosLocationUpdates = []

        if shouldSync, !updates.isEmpty {
            isSyncingApplePhotosLocations = true
            let error = await vm.syncAdjustedLocationsToApplePhotos(updates)
            isSyncingApplePhotosLocations = false
            if let error {
                locationAdjustErrorMessage = error
            }
        }
    }

    private var stickyPhotoControlsBar: some View {
        HStack(spacing: 12) {
            if vm.isSelectingPhotos {
                Text("\(vm.selectedPhotoCount) selected")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
            } else {
                Spacer(minLength: 8)
                sortMenu
                filterMenu
                Button("Select") {
                    vm.beginPhotoSelection()
                }
                .font(.subheadline.weight(.semibold))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private var sortMenu: some View {
        Menu {
            ForEach(EventDetailPhotoSort.allCases) { option in
                Button {
                    vm.photoSort = option
                } label: {
                    if vm.photoSort == option {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
                .labelStyle(.iconOnly)
                .font(.body.weight(.semibold))
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Sort")
        .accessibilityValue(vm.photoSort.title)
    }

    private var filterMenu: some View {
        Menu {
            ForEach(PictureBrowserFilter.allCases) { option in
                Button {
                    vm.photoFilter = option
                } label: {
                    if vm.photoFilter == option {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
            }
        } label: {
            Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                .labelStyle(.iconOnly)
                .font(.body.weight(.semibold))
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Filter")
        .accessibilityValue(vm.photoFilter.title)
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

    private func sortGroupHeader(title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .background(Color(.systemBackground))
    }

    @ViewBuilder
    private var photoGridContent: some View {
        let blocks = vm.gridBlocks
        if blocks.isEmpty {
            ContentUnavailableView(
                "No Pictures",
                systemImage: "photo.on.rectangle.angled",
                description: Text("Nothing matches the current filter.")
            )
            .padding(.top, 24)
        } else {
            ForEach(blocks) { block in
                if let trip = block.tripSection {
                    tripSectionHeader(trip)
                        .padding(.top, 8)
                }

                PhotoGrid(
                    sections: block.groups.map {
                        PhotoGridSection(id: $0.id, items: $0.items)
                    },
                    isSelecting: vm.isSelectingPhotos,
                    selectedPhotoIds: vm.selectedPhotoIds,
                    pinsSectionHeaders: false,
                    onTap: { item in
                        if vm.isSelectingPhotos {
                            vm.toggleDisplayItemSelection(item)
                        } else if let index = vm.fullscreenDisplayItems.firstIndex(where: { $0.id == item.id }) {
                            selectedPhotoIndex = index
                        }
                    },
                    sectionHeader: { section in
                        if let group = block.groups.first(where: { $0.id == section.id }) {
                            sortGroupHeader(title: group.title)
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
                selectedField = field
            } label: {
                HStack {
                    Label(field.menuTitle, systemImage: field.iconName)
                    Spacer()
                    if viewModel.selection(for: field) != nil {
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
                                photo: context.photo,
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
