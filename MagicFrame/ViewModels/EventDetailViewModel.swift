import Foundation
import Combine
import SwiftUI

@MainActor
final class EventDetailViewModel: ObservableObject {

    @Published private(set) var event: IndexedEvent
    var onEventUpdated: ((Int) -> Void)?
    var onEventHidden: ((Int) -> Void)?
    var onEventUnhidden: ((Int) -> Void)?

    @Published private(set) var photos: [IndexedPhoto] = []
    @Published private(set) var tripSections: [TripEventSection] = []
    @Published var tripChildEventNameDrafts: [Int: String] = [:]
    @Published private(set) var photoDisplayItems: [EventPhotoDisplayItem] = []
    @Published private(set) var tripPhotoDisplaySections: [TripPhotoDisplaySection] = []
    @Published var activeSimilarGroup: SimilarPhotoGroup?
    @Published var similarGroupPickerSelection: Set<String> = []
    @Published var eventName: String
    @Published var userEditedName: Bool
    @Published private(set) var nameSaveStatus: String?

    @Published var eventType: String?
    @Published var activityType: String?
    @Published var tripType: String?
    @Published var milestoneType: String?
    @Published var holidayType: String?
    @Published var eventMainPerson: String?
    @Published var eventMainPerson2: String?
    @Published var weddingDate: String?

    @Published private(set) var eventTypeOptions: [String] = []
    @Published private(set) var activityTypeOptions: [String] = []
    @Published private(set) var tripTypeOptions: [String] = []
    @Published private(set) var milestoneTypeOptions: [String] = []
    @Published private(set) var holidayTypeOptions: [String] = []
    @Published private(set) var personOptions: [String] = []

    @Published var isAddingCustomOption = false
    @Published var customOptionField: EventAttributeField?
    @Published var newCustomOptionName = ""

    @Published var isSelectingPhotos = false
    @Published private(set) var selectedPhotoIds: Set<String> = []
    @Published var showHiddenPhotos = false
    @Published private(set) var analyzingFaceMetricsPhotoIds: Set<String> = []
    @Published private(set) var objectRecognitionStatus: String?
    @Published private(set) var visionLabelDebugStatus: String?
    @Published private(set) var holidayScorecards: [AITagScoringDetail] = []
    @Published private(set) var holidayScorecardRevision = 0
    @Published private(set) var aiTagScoringSaveStatus: String?
    private var faceAnalysisTask: Task<Void, Never>?
    private var objectRecognitionTask: Task<Void, Never>?
    private var visionLabelDebugTask: Task<Void, Never>?
    private var birthDateISOByPersonName: [String: String] = [:]
    private let database: any MagicFrameDatabase

    init(
        event: IndexedEvent,
        database: (any MagicFrameDatabase)? = nil,
        onEventUpdated: ((Int) -> Void)? = nil,
        onEventHidden: ((Int) -> Void)? = nil,
        onEventUnhidden: ((Int) -> Void)? = nil
    ) {
        self.database = database ?? AppDependencies.database
        let freshEvent = self.database.getEvent(eventId: event.eventId) ?? event
        self.event = freshEvent
        self.onEventUpdated = onEventUpdated
        self.onEventHidden = onEventHidden
        self.onEventUnhidden = onEventUnhidden
        self.eventName = freshEvent.name
        self.userEditedName = freshEvent.userEditedName
        syncClassification(from: freshEvent)
    }

    var photoCount: Int {
        photos.count
    }

    var visiblePhotoCount: Int {
        if event.isTripContainer {
            tripPhotoDisplaySections.reduce(0) { $0 + $1.displayItems.count }
        } else {
            photoDisplayItems.count
        }
    }

    var collapsedSimilarPhotoCount: Int {
        max(0, photos.count - visiblePhotoCount)
    }

    var displayRepresentatives: [IndexedPhoto] {
        if event.isTripContainer {
            tripPhotoDisplaySections.flatMap { $0.displayItems.map(\.representative) }
        } else {
            photoDisplayItems.map(\.representative)
        }
    }

    var fullscreenDisplayItems: [EventPhotoDisplayItem] {
        if event.isTripContainer {
            tripPhotoDisplaySections.flatMap(\.displayItems)
        } else {
            photoDisplayItems
        }
    }

    func displayItem(containingPhotoId photoId: String) -> EventPhotoDisplayItem? {
        allDisplayItems.first { item in
            item.group.photos.contains { $0.id == photoId }
        }
    }

    func similarGroup(containingPhotoId photoId: String) -> SimilarPhotoGroup? {
        displayItem(containingPhotoId: photoId)?.group
    }

    var selectedPhotoCount: Int {
        selectedPhotoIds.count
    }

    var suggestedName: String? {
        let resolvedMilestoneType = event.resolvedAttributeValue(for: .milestoneType) ?? milestoneType
        let resolvedMainPerson = event.resolvedAttributeValue(for: .mainPerson) ?? eventMainPerson
        let resolvedMainPerson2 = event.resolvedAttributeValue(for: .secondaryMainPerson) ?? eventMainPerson2

        if MilestoneEventNaming.isCoupleMilestone(resolvedMilestoneType),
           let person1 = resolvedMainPerson?.trimmingCharacters(in: .whitespacesAndNewlines),
           let person2 = resolvedMainPerson2?.trimmingCharacters(in: .whitespacesAndNewlines),
           !person1.isEmpty,
           !person2.isEmpty,
           let milestoneName = MilestoneEventNaming.suggestCoupleEventName(
               person1: person1,
               person2: person2,
               milestoneType: resolvedMilestoneType,
               weddingDateISO: weddingDate,
               eventStartDate: event.startDate
           ) {
            return milestoneName
        }

        if MilestoneEventNaming.isPersonMilestone(resolvedMilestoneType),
           !MilestoneEventNaming.isCoupleMilestone(resolvedMilestoneType),
           let person = resolvedMainPerson?.trimmingCharacters(in: .whitespacesAndNewlines),
           !person.isEmpty {
            let birthISO = birthDateISOByPersonName[person.lowercased()]
            if let milestoneName = MilestoneEventNaming.suggestEventName(
                personName: person,
                milestoneType: resolvedMilestoneType,
                birthDateISO: birthISO,
                eventStartDate: event.startDate
            ) {
                return milestoneName
            }
        }

        return EventNameSuggester.suggest(
            locationDisplayText: event.locationDisplayText,
            startDate: event.startDate,
            endDate: event.endDate,
            people: event.people
        )
    }

    var showSuggestion: Bool {
        guard let name = suggestedName,
              !name.isEmpty else {
            return false
        }

        let trimmedEventName = eventName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedEventName != name else { return false }

        let resolvedMilestoneType = event.resolvedAttributeValue(for: .milestoneType) ?? milestoneType
        let resolvedMainPerson = event.resolvedAttributeValue(for: .mainPerson) ?? eventMainPerson
        let resolvedMainPerson2 = event.resolvedAttributeValue(for: .secondaryMainPerson) ?? eventMainPerson2

        if MilestoneEventNaming.isCoupleMilestone(resolvedMilestoneType),
           resolvedMainPerson?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
           resolvedMainPerson2?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return true
        }

        if MilestoneEventNaming.isPersonMilestone(resolvedMilestoneType),
           !MilestoneEventNaming.isCoupleMilestone(resolvedMilestoneType),
           resolvedMainPerson?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return true
        }

        return !userEditedName
    }

    func toggleShowHiddenPhotos() {
        showHiddenPhotos.toggle()
        loadPhotos()
    }

    func loadPhotos() {
        if event.isTripContainer {
            tripSections = database.getTripSections(
                for: event.eventId,
                includeHidden: showHiddenPhotos
            )
            photos = tripSections.flatMap(\.photos)
        } else {
            tripSections = []
            photos = database.getPhotosForEvent(
                eventId: event.eventId,
                includeHidden: showHiddenPhotos
            )
        }

        rebuildDisplayItems()
        selectedPhotoIds = selectedPhotoIds.intersection(Set(photos.map(\.id)))
        syncTripChildEventNameDrafts()
        analyzeFaceMetricsForStacksIfNeeded()
        runObjectRecognitionIfNeeded()
    }

    func loadHolidayScorecards() {
        rescoreCurrentEventHolidayScores()
        holidayScorecards = database.fetchHolidayScorecards(
            eventId: event.eventId,
            includesDescendantPhotos: event.isTripContainer
        )
        holidayScorecardRevision += 1
    }

    private func rescoreCurrentEventHolidayScores() {
        database.scoreHolidayEvent(eventId: event.eventId)
        refreshEvent(notifyList: false)
    }

    func syncTripChildEventNameDrafts() {
        tripChildEventNameDrafts = Dictionary(
            uniqueKeysWithValues: tripSections.map { ($0.subEventId, $0.childEventName) }
        )
    }

    func tripChildEventNameBinding(subEventId: Int) -> Binding<String> {
        Binding(
            get: { self.tripChildEventNameDrafts[subEventId] ?? "" },
            set: { self.tripChildEventNameDrafts[subEventId] = $0 }
        )
    }

    func saveTripChildEventName(subEventId: Int) {
        let trimmed = (tripChildEventNameDrafts[subEventId] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let saved = database.updateChildEventName(
            eventId: subEventId,
            name: trimmed,
            userEdited: true
        )
        guard saved else { return }

        loadPhotos()
        notifyEventUpdated()
    }

    private var allDisplayItems: [EventPhotoDisplayItem] {
        if event.isTripContainer {
            tripPhotoDisplaySections.flatMap(\.displayItems)
        } else {
            photoDisplayItems
        }
    }

    private func runObjectRecognitionIfNeeded() {
        objectRecognitionTask?.cancel()

        let eventId = event.eventId
        let includeHidden = showHiddenPhotos
        let database = database

        objectRecognitionTask = Task { [weak self] in
            guard let self else { return }

            let summary = database.enqueueEventObjectRecognitionJobs(
                eventId: eventId,
                includeHiddenPhotos: includeHidden,
                forceRescan: false,
                forcedOccasionKey: nil,
                priority: 100,
                scopeKey: nil
            )

            guard !Task.isCancelled else { return }

            if summary.enqueuedCount == 0 {
                self.objectRecognitionStatus = nil
                _ = summary.skippedReason
                return
            }

            while !Task.isCancelled {
                let pending = database.visionJobPendingCount(scopeKey: nil, eventId: eventId)
                if pending == 0 { break }

                let coordinator = AppDependencies.container.visionJobCoordinator
                if coordinator.snapshot.activeEventId == eventId,
                   let statusText = coordinator.snapshot.statusText {
                    self.objectRecognitionStatus = statusText
                }

                try? await Task.sleep(for: .milliseconds(250))
            }

            guard !Task.isCancelled else { return }

            self.objectRecognitionStatus = "Object scan complete."
            self.refreshEvent()
            self.loadHolidayScorecards()

            try? await Task.sleep(for: .seconds(4))
            if self.objectRecognitionStatus == "Object scan complete." {
                self.objectRecognitionStatus = nil
            }
        }
    }

    private func analyzeFaceMetricsForStacksIfNeeded() {
        faceAnalysisTask?.cancel()

        if database.faceMetricsAlgorithmVersion()
            != PhotoFaceAnalyzer.algorithmVersion {
            let stackPhotoIds = allDisplayItems
                .filter(\.isStack)
                .flatMap { $0.group.photos.map(\.id) }
            database.clearFaceMetrics(forPhotoIds: stackPhotoIds)
            database.setFaceMetricsAlgorithmVersion(PhotoFaceAnalyzer.algorithmVersion)
            reloadPhotosPreservingAnalysisState()
        }

        var photoIdsNeedingAnalysis: [String] = []
        for item in allDisplayItems where item.isStack {
            for photo in item.group.photos where needsFaceAnalysis(for: photo) {
                photoIdsNeedingAnalysis.append(photo.id)
            }
        }
        photoIdsNeedingAnalysis = Array(Set(photoIdsNeedingAnalysis))

        guard !photoIdsNeedingAnalysis.isEmpty else { return }

        faceAnalysisTask = Task {
            await analyzeFaceMetrics(for: photoIdsNeedingAnalysis)
        }
    }

    func analyzeFaceMetricsIfNeeded(for photoId: String, force: Bool = false) async {
        guard photos.contains(where: { $0.id == photoId }) else { return }

        if force {
            await analyzeFaceMetrics(for: [photoId], priority: .utility)
            return
        }

        guard let photo = photos.first(where: { $0.id == photoId }),
              needsFaceAnalysis(for: photo) else {
            return
        }

        await analyzeFaceMetrics(for: [photoId], priority: .utility)
    }

    func prefetchFaceMetrics(for group: SimilarPhotoGroup) async {
        let photoIds = group.photos
            .filter(needsFaceAnalysis(for:))
            .map(\.id)

        guard !photoIds.isEmpty else { return }
        await analyzeFaceMetrics(for: photoIds, priority: .background)
    }

    private func needsFaceAnalysis(for photo: IndexedPhoto) -> Bool {
        photo.faceEyesOpenScore == nil || photo.faceSmileScore == nil
    }

    private func analyzeFaceMetrics(
        for photoIds: [String],
        priority: TaskPriority = .utility
    ) async {
        guard !photoIds.isEmpty else { return }

        await Task(priority: priority) {
            analyzingFaceMetricsPhotoIds.formUnion(photoIds)
            defer {
                analyzingFaceMetricsPhotoIds.subtract(photoIds)
            }

            for photoId in photoIds {
                guard !Task.isCancelled else { return }

                if let metrics = await PhotoFaceAnalyzer.analyze(assetIdentifier: photoId) {
                    database.updateFaceMetrics(
                        photoId: photoId,
                        eyesOpenScore: metrics.eyesOpenScore,
                        smileScore: metrics.smileScore
                    )
                }
            }

            guard !Task.isCancelled else { return }
            reloadPhotosPreservingAnalysisState()
        }.value
    }

    private func reloadPhotosPreservingAnalysisState() {
        if event.isTripContainer {
            tripSections = database.getTripSections(
                for: event.eventId,
                includeHidden: showHiddenPhotos
            )
            photos = tripSections.flatMap(\.photos)
        } else {
            tripSections = []
            photos = database.getPhotosForEvent(
                eventId: event.eventId,
                includeHidden: showHiddenPhotos
            )
        }

        rebuildDisplayItems()
        selectedPhotoIds = selectedPhotoIds.intersection(Set(photos.map(\.id)))
    }

    private func rebuildDisplayItems() {
        if event.isTripContainer {
            tripPhotoDisplaySections = tripSections.map { section in
                TripPhotoDisplaySection(
                    section: section,
                    displayItems: EventSimilarPhotoGrouper.displayItems(from: section.photos)
                )
            }
            photoDisplayItems = []
        } else {
            tripPhotoDisplaySections = []
            photoDisplayItems = EventSimilarPhotoGrouper.displayItems(from: photos)
        }
    }

    func openSimilarGroup(_ group: SimilarPhotoGroup) {
        similarGroupPickerSelection = group.pickedPhotoIds(from: group.photos)
        if similarGroupPickerSelection.isEmpty {
            similarGroupPickerSelection = [group.autoBestPhoto().id]
        }
        activeSimilarGroup = group
    }

    func saveSimilarGroupPicks() {
        guard let group = activeSimilarGroup else { return }

        database.setSimilarGroupPicks(
            groupPhotoIds: group.photos.map(\.id),
            pickedPhotoIds: similarGroupPickerSelection
        )

        activeSimilarGroup = nil
        similarGroupPickerSelection = []
        loadPhotos()
    }

    func cancelSimilarGroupPicker() {
        activeSimilarGroup = nil
        similarGroupPickerSelection = []
    }

    func toggleDisplayItemSelection(_ item: EventPhotoDisplayItem) {
        togglePhotoSelection(photoId: item.representative.id)
    }

    @discardableResult
    func hideDisplayItem(_ item: EventPhotoDisplayItem) -> Bool {
        database.setPhotosHiddenInEvent(
            photoIds: item.group.photos.map(\.id),
            hidden: true
        )

        loadPhotos()
        refreshEvent()

        if showHiddenPhotos {
            return false
        }

        return photos.isEmpty
    }

    func loadClassificationOptions() {
        eventTypeOptions = database.getEventAttributeOptions(for: .eventType)
        activityTypeOptions = database.getEventAttributeOptions(for: .activityType)
        tripTypeOptions = database.getEventAttributeOptions(for: .tripType)
        milestoneTypeOptions = database.getEventAttributeOptions(for: .milestoneType)
        holidayTypeOptions = database.getEventAttributeOptions(for: .holidayType)

        var people = Set(database.getAllPersonNames())
        people.formUnion(event.people)
        personOptions = people.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }

        let birthdays = database.fetchPeopleWithBirthDates()
        birthDateISOByPersonName = Dictionary(
            uniqueKeysWithValues: birthdays.map { ($0.name.lowercased(), $0.birthDateISO) }
        )
    }

    func isMilestonePersonPickerTag(_ tag: EventAttributeTag) -> Bool {
        tag.category == .milestoneType &&
        MilestonePersonPickerKind.from(milestoneType: tag.tagValue) != nil
    }

    func milestonePersonPickerItems(for kind: MilestonePersonPickerKind) -> [MilestonePersonPickerItem] {
        switch kind {
        case .birthday:
            let eventDate = EventDateParser.parseDate(event.startDate) ?? Date()
            return BirthdayPersonPickerOrdering.items(
                peopleWithBirthDates: database.fetchPeopleWithBirthDates(),
                allPeople: database.fetchAllPeople(),
                eventDate: eventDate
            )
        case .graduation, .baptism, .wedding, .anniversary:
            return coupleMilestonePersonItems()
        }
    }

    func coupleMilestonePersonItems(
        excludingPersonId: Int? = nil
    ) -> [MilestonePersonPickerItem] {
        let items = EventMilestonePersonPickerOrdering.items(
            eventPeople: database.fetchEventPeople(
                eventId: event.eventId,
                includeChildEvents: event.isTripContainer
            ),
            allPeople: database.fetchAllPeople()
        )

        guard let excludingPersonId else { return items }
        return items.filter { $0.personId != excludingPersonId }
    }

    func defaultWeddingDate() -> Date {
        if let weddingDate,
           let stored = EventDateParser.parseDate(weddingDate) {
            return stored
        }
        return EventDateParser.eventDayDate(from: event.startDate) ?? Date()
    }

    func assignMilestonePerson(_ person: MilestonePersonPickerItem) {
        setEventMainPerson(person.name)
    }

    func showAITagScoringDetail(for tag: EventAttributeTag) {
        aiTagScoringSaveStatus = nil
        loadHolidayScorecards()
    }

    func saveOccasionDateScoringSettings(
        occasionId: Int,
        edit: OccasionDateScoringEdit
    ) {
        database.updateOccasionDateScoringSettings(
            occasionId: occasionId,
            edit: edit
        )
        rescoreCurrentEventAfterRuleChange(
            statusMessage: "Saved. This event was re-scored with the new date window."
        )
    }

    func saveOccasionObjectScoringRules(
        occasionId: Int,
        rules: [EditableObjectScoringRule]
    ) {
        let candidateCount = database.saveObjectScoringRules(
            occasionId: occasionId,
            rules: rules
        )
        rescoreCurrentEventAfterRuleChange(
            statusMessage: candidateCount > 0
                ? "Saved. \(candidateCount) \(candidateCount == 1 ? "event" : "events") queued for object re-scan (including this one)."
                : "Saved. Object rules updated and this event was re-scored."
        )
        loadPhotos()
    }

    private func rescoreCurrentEventAfterRuleChange(statusMessage: String) {
        rescoreCurrentEventHolidayScores()
        holidayScorecards = database.fetchHolidayScorecards(
            eventId: event.eventId,
            includesDescendantPhotos: event.isTripContainer
        )
        holidayScorecardRevision += 1
        aiTagScoringSaveStatus = statusMessage
    }

    func assignCoupleMilestone(
        person1: MilestonePersonPickerItem,
        person2: MilestonePersonPickerItem,
        weddingDate selectedDate: Date
    ) {
        setAttribute(.mainPerson, value: person1.name)
        setAttribute(.secondaryMainPerson, value: person2.name)

        let weddingDateISO = EventDateParser.dateOnlyISO(from: selectedDate)
        database.updateWeddingDate(eventId: event.eventId, weddingDate: weddingDateISO)
        weddingDate = weddingDateISO

        if milestoneType?.caseInsensitiveCompare("Wedding") == .orderedSame {
            _ = database.propagateAnniversaryTagsFromWedding(
                sourceEventId: event.eventId,
                person1: person1.name,
                person2: person2.name,
                weddingDateISO: weddingDateISO
            )
        }

        refreshEvent()
        notifyEventUpdated()
    }

    func setEventType(_ value: String?) {
        setAttribute(.eventType, value: value)
    }

    func setActivityType(_ value: String?) {
        setAttribute(.activityType, value: value)
    }

    func setTripType(_ value: String?) {
        setAttribute(.tripType, value: value)
    }

    func setMilestoneType(_ value: String?) {
        setAttribute(.milestoneType, value: value)
    }

    func setHolidayType(_ value: String?) {
        setAttribute(.holidayType, value: value)
    }

    func confirmAIAttributeTag(_ tag: EventAttributeTag) {
        guard tag.isAIDerived else { return }
        for eventId in tag.actionEventIds(displayEventId: event.eventId) {
            database.confirmAIAttributeTag(eventId: eventId, field: tag.category)
        }
        refreshEvent()
        notifyEventUpdated()
    }

    func rejectAIAttributeTag(_ tag: EventAttributeTag) {
        guard tag.isAIDerived else { return }
        for eventId in tag.actionEventIds(displayEventId: event.eventId) {
            database.rejectAIAttributeTag(eventId: eventId, field: tag.category)
        }
        refreshEvent()
        notifyEventUpdated()
    }

    func confirmAIHolidayTag() {
        guard let tag = event.holidayTag else { return }
        confirmAIAttributeTag(EventAttributeTag(holidayTag: tag))
    }

    func rejectAIHolidayTag() {
        guard let tag = event.holidayTag else { return }
        rejectAIAttributeTag(EventAttributeTag(holidayTag: tag))
    }

    func setEventMainPerson(_ value: String?) {
        setAttribute(.mainPerson, value: value)
    }

    func selection(for field: EventAttributeField) -> String? {
        switch field {
        case .eventType: return eventType
        case .activityType: return activityType
        case .tripType: return tripType
        case .milestoneType: return milestoneType
        case .holidayType: return holidayType
        case .mainPerson: return eventMainPerson
        case .secondaryMainPerson: return eventMainPerson2
        }
    }

    func options(for field: EventAttributeField) -> [String] {
        switch field {
        case .eventType: return eventTypeOptions
        case .activityType: return activityTypeOptions
        case .tripType: return tripTypeOptions
        case .milestoneType: return milestoneTypeOptions
        case .holidayType: return holidayTypeOptions
        case .mainPerson, .secondaryMainPerson: return personOptions
        }
    }

    func setSelection(_ value: String?, for field: EventAttributeField) {
        setAttribute(field, value: value)
    }

    func beginAddingCustomOption(for field: EventAttributeField) {
        guard field.allowsCustomOptions else { return }
        customOptionField = field
        newCustomOptionName = ""
        isAddingCustomOption = true
    }

    func saveCustomOption() {
        guard let field = customOptionField else { return }

        let trimmed = newCustomOptionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        database.addCustomEventAttributeOption(trimmed, for: field)
        loadClassificationOptions()
        setAttribute(field, value: trimmed)

        isAddingCustomOption = false
        customOptionField = nil
        newCustomOptionName = ""
    }

    func cancelAddingCustomOption() {
        isAddingCustomOption = false
        customOptionField = nil
        newCustomOptionName = ""
    }

    private func setAttribute(_ field: EventAttributeField, value: String?) {
        database.updateEventAttribute(
            eventId: event.eventId,
            field: field,
            value: value
        )

        switch field {
        case .eventType: eventType = value
        case .activityType: activityType = value
        case .tripType: tripType = value
        case .milestoneType: milestoneType = value
        case .holidayType: holidayType = value
        case .mainPerson: eventMainPerson = value
        case .secondaryMainPerson: eventMainPerson2 = value
        }

        refreshEvent()
    }

    private func syncClassification(from event: IndexedEvent) {
        eventType = event.eventType
        activityType = event.activityType
        tripType = event.tripType
        milestoneType = event.resolvedAttributeValue(for: .milestoneType) ?? event.milestoneType
        holidayType = event.displayHolidayLabel ?? event.holidayType
        eventMainPerson = event.resolvedAttributeValue(for: .mainPerson) ?? event.eventMainPerson
        eventMainPerson2 = event.resolvedAttributeValue(for: .secondaryMainPerson) ?? event.eventMainPerson2
        weddingDate = event.weddingDate
    }

    func beginPhotoSelection() {
        isSelectingPhotos = true
        selectedPhotoIds.removeAll()
    }

    func cancelPhotoSelection() {
        isSelectingPhotos = false
        selectedPhotoIds.removeAll()
    }

    func togglePhotoSelection(photoId: String) {
        if selectedPhotoIds.contains(photoId) {
            selectedPhotoIds.remove(photoId)
        } else {
            selectedPhotoIds.insert(photoId)
        }
    }

    func setSelectedPhotosOnFrame(_ show: Bool) {
        guard !selectedPhotoIds.isEmpty else { return }

        if show {
            for photoId in selectedPhotoIds {
                let group = similarGroup(containingPhotoId: photoId)
                setPhotoOnFrame(photoId: photoId, show: true, in: group)
            }
        } else {
            database.setPhotosShowOnFrame(
                photoIds: Array(selectedPhotoIds),
                show: false
            )
            loadPhotos()
            refreshEvent()
        }

        cancelPhotoSelection()
    }

    @discardableResult
    func hidePhoto(photoId: String) -> Bool {
        if let item = displayItem(forRepresentativeId: photoId) {
            return hideDisplayItem(item)
        }

        database.setPhotosHiddenInEvent(photoIds: [photoId], hidden: true)
        loadPhotos()
        refreshEvent()

        if showHiddenPhotos {
            return false
        }

        return photos.isEmpty
    }

    private func displayItem(forRepresentativeId photoId: String) -> EventPhotoDisplayItem? {
        let items = event.isTripContainer
            ? tripPhotoDisplaySections.flatMap(\.displayItems)
            : photoDisplayItems
        return items.first { $0.representative.id == photoId }
    }

    @discardableResult
    func hideSelectedPhotos() -> Bool {
        guard !selectedPhotoIds.isEmpty else { return false }

        database.setPhotosHiddenInEvent(
            photoIds: Array(selectedPhotoIds),
            hidden: true
        )

        cancelPhotoSelection()
        loadPhotos()
        refreshEvent()

        if showHiddenPhotos {
            return false
        }

        return photos.isEmpty
    }

    func hideEvent() {
        database.setEventUserHidden(eventId: event.eventId, hidden: true)
        onEventHidden?(event.eventId)
    }

    func unhideEvent() {
        database.setEventUserHidden(eventId: event.eventId, hidden: false)
        refreshEvent()
        onEventUnhidden?(event.eventId)
    }

    var isUserHidden: Bool {
        event.isUserHidden
    }

    func refreshEvent(notifyList: Bool = true) {
        guard let updated = database.getEvent(eventId: event.eventId) else {
            return
        }

        event = updated
        syncClassification(from: updated)
        if notifyList {
            notifyEventUpdated()
        }
    }

    func applySuggestedName() {
        guard let name = suggestedName else { return }

        eventName = name
        userEditedName = false
        saveEventName()
    }

    @discardableResult
    func saveEventName() -> Bool {
        let trimmed = eventName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            nameSaveStatus = "Name cannot be empty"
            return false
        }

        let saved = database.updateEventName(
            eventId: event.eventId,
            name: trimmed,
            userEdited: userEditedName
        )

        if saved {
            eventName = trimmed
            nameSaveStatus = "Saved"
            notifyEventUpdated()
            return true
        }

        nameSaveStatus = "Could not save name"
        return false
    }

    func markNameAsUserEdited() {
        userEditedName = true
        nameSaveStatus = nil
    }

    private func notifyEventUpdated() {
        let eventId = event.eventId
        let callback = onEventUpdated
        Task { @MainActor in
            await Task.yield()
            callback?(eventId)
        }
    }

    func togglePhotoOnFrame(photoId: String, in group: SimilarPhotoGroup? = nil) {
        let isOnFrame = photos.first(where: { $0.id == photoId })?.showOnFrame ?? false
        setPhotoOnFrame(photoId: photoId, show: !isOnFrame, in: group)
    }

    func setPhotoOnFrame(photoId: String, show: Bool, in group: SimilarPhotoGroup? = nil) {
        guard photos.contains(where: { $0.id == photoId }) else { return }

        let owningEventId = database.getEventIdForPhoto(photoId: photoId) ?? event.eventId

        if show, let group, group.isStack {
            for sibling in group.photos where sibling.id != photoId {
                let siblingEventId = database.getEventIdForPhoto(photoId: sibling.id) ?? owningEventId
                database.setPhotoShowOnFrame(
                    photoId: sibling.id,
                    eventId: siblingEventId,
                    show: false
                )
            }

            database.setSimilarGroupPicks(
                groupPhotoIds: group.photos.map(\.id),
                pickedPhotoIds: [photoId]
            )
        }

        database.setPhotoShowOnFrame(
            photoId: photoId,
            eventId: owningEventId,
            show: show
        )

        database.clearCropFocus(photoId: photoId)

        loadPhotos()
        notifyEventUpdated()
    }

    private func applyLocalPhotoUpdate(_ updated: IndexedPhoto) {
        if let index = photos.firstIndex(where: { $0.id == updated.id }) {
            photos[index] = updated
        }

        if event.isTripContainer {
            tripSections = tripSections.map { section in
                guard let photoIndex = section.photos.firstIndex(where: { $0.id == updated.id }) else {
                    return section
                }

                var updatedPhotos = section.photos
                updatedPhotos[photoIndex] = updated
                return TripEventSection(
                    dayNumber: section.dayNumber,
                    childEventName: section.childEventName,
                    subEventId: section.subEventId,
                    photos: updatedPhotos
                )
            }
        }

        rebuildDisplayItems()
    }

    func logVisionLabelsForPhoto(_ photo: IndexedPhoto) {
        visionLabelDebugTask?.cancel()
        visionLabelDebugTask = Task {
            visionLabelDebugStatus = "Analyzing Vision labels…"

            let objectKeys = database.christmasObjectKeysForVisionDebug()
            let result = await VisionLabelDebugService.analyze(
                assetIdentifier: photo.id,
                objectKeys: objectKeys
            )

            guard !Task.isCancelled else { return }
            visionLabelDebugStatus = result.statusMessage
        }
    }
}
