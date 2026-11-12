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
    @Published private(set) var gameResult: EventGameResult?
    @Published private(set) var gameLookupStatus: String?
    @Published private(set) var isLookingUpGameScore = false
    @Published var gameLookupCandidates: [SportsGameCandidate] = []
    @Published var showGameLookupCandidates = false
    @Published private(set) var locationGeocodeStatus: String?
    @Published var pendingSimilarEventAlternatives: SimilarEventAlternativesRequest?
    @Published var pendingSimilarEventPeoplePick: SimilarEventPeoplePickRequest?
    private var faceAnalysisTask: Task<Void, Never>?
    private var similarGroupRefineTask: Task<Void, Never>?
    private var objectRecognitionTask: Task<Void, Never>?
    private var visionLabelDebugTask: Task<Void, Never>?
    private var locationGeocodeTask: Task<Void, Never>?
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
        self.gameResult = self.database.fetchEventGameResult(eventId: freshEvent.eventId)
    }

    var canLookupGameScore: Bool {
        let type = eventType?.trimmingCharacters(in: .whitespacesAndNewlines)
        return type == "Sporting event" || gameResult != nil
    }

    var photoCount: Int {
        photos.filter { !$0.isVideo }.count
    }

    var videoCount: Int {
        photos.filter(\.isVideo).count
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
        if let gameResult {
            return gameResult.suggestedEventName
        }

        let resolvedMilestoneType = event.resolvedAttributeValue(for: .milestoneType) ?? milestoneType
        let resolvedMainPerson = event.resolvedAttributeValue(for: .mainPerson) ?? eventMainPerson
        let resolvedMainPerson2 = event.resolvedAttributeValue(for: .secondaryMainPerson) ?? eventMainPerson2
        let mainPeople = event.orderedMainPersonNames
        let person1 = mainPeople.first
            ?? resolvedMainPerson?.trimmingCharacters(in: .whitespacesAndNewlines)
        let person2 = mainPeople.count > 1
            ? mainPeople[1]
            : resolvedMainPerson2?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let resolvedMilestoneType,
           let template = database.fetchEventNameTemplate(
               tagCategory: EventAttributeField.milestoneType.tagCategory,
               tagValue: resolvedMilestoneType
           ),
           let templated = MilestoneEventNaming.suggestTemplatedEventName(
               nameTemplate: template,
               person1: person1,
               person2: person2
           ) {
            return templated
        }

        if MilestoneEventNaming.isCoupleMilestone(resolvedMilestoneType),
           let person1,
           let person2,
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
           let person = person1,
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
        let mainPeople = event.orderedMainPersonNames
        let resolvedMainPerson = mainPeople.first
            ?? event.resolvedAttributeValue(for: .mainPerson)
            ?? eventMainPerson
        let resolvedMainPerson2 = mainPeople.count > 1
            ? mainPeople[1]
            : (event.resolvedAttributeValue(for: .secondaryMainPerson) ?? eventMainPerson2)

        if let resolvedMilestoneType,
           let template = database.fetchEventNameTemplate(
               tagCategory: EventAttributeField.milestoneType.tagCategory,
               tagValue: resolvedMilestoneType
           ) {
            let hasPerson1 = resolvedMainPerson?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            let needsPerson2 = template.nameTemplate.contains("{person2}")
            let hasPerson2 = resolvedMainPerson2?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            if hasPerson1, !needsPerson2 || hasPerson2 {
                return true
            }
        }

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
        reloadPhotoCollections()
        rebuildDisplayItems()
        selectedPhotoIds = selectedPhotoIds.intersection(Set(photos.map(\.id)))
        syncTripChildEventNameDrafts()
        // Face metrics wait until visual refine finishes — otherwise mega metadata
        // stacks (shared import timestamps) thrash: refine ↔ face reload ↔ regroup.
        refineSimilarGroupsWithVisualSimilarityIfNeeded()
        runObjectRecognitionIfNeeded()
        enqueueFaceRecognitionIfNeeded()
        ensureLocationGeocodedIfNeeded()
    }

    func cancelLocationGeocode() {
        locationGeocodeTask?.cancel()
        locationGeocodeTask = nil
        locationGeocodeStatus = nil
    }

    private func ensureLocationGeocodedIfNeeded() {
        locationGeocodeTask?.cancel()

        let eventId = event.eventId
        let alreadyHasPlace =
            !(event.placeName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            || !(event.city?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

        locationGeocodeTask = Task { [weak self] in
            guard let self else { return }
            if !alreadyHasPlace {
                self.locationGeocodeStatus = "Looking up location…"
            }

            let didUpdate = await database.ensureEventLocationGeocoded(eventId: eventId)
            guard !Task.isCancelled else { return }

            if didUpdate {
                self.refreshEvent(notifyList: true)
            }
            self.locationGeocodeStatus = nil
        }
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

    func cancelObjectRecognition() {
        objectRecognitionTask?.cancel()
        objectRecognitionTask = nil
        objectRecognitionStatus = nil
        cancelLocationGeocode()
    }

    private func runObjectRecognitionIfNeeded() {
        objectRecognitionTask?.cancel()

        let eventId = event.eventId
        let includeHidden = showHiddenPhotos
        let database = database

        objectRecognitionTask = Task { [weak self] in
            guard let self else { return }

            // Full Tag Photos–style classify for gaps only (`visionAnalyzed = 0`).
            // Already analyzed photos are skipped; does not use photo_vision_scans.
            let report = await database.scanEventPhotosWithVisionTags(
                eventId: eventId,
                includeHiddenPhotos: includeHidden
            ) { current, total in
                Task { @MainActor [weak self] in
                    guard let self, !Task.isCancelled else { return }
                    self.objectRecognitionStatus =
                        "Tagging photos… \(current.formatted())/\(total.formatted())"
                }
            }

            guard !Task.isCancelled else { return }

            if report.photosScanned == 0 && report.photosFailed == 0 {
                self.objectRecognitionStatus = nil
                return
            }

            let completeMessage = report.stoppedEarly
                ? "Vision tagging cancelled."
                : "Vision tags: \(report.photosScanned.formatted()) scanned · "
                    + "\(report.tagsWritten.formatted()) labels."
            self.objectRecognitionStatus = completeMessage
            self.refreshEvent()

            try? await Task.sleep(for: .seconds(4))
            if self.objectRecognitionStatus == completeMessage {
                self.objectRecognitionStatus = nil
            }
        }
    }

    /// Seeds face detect+embed for unscanned photos in this event (no live matching).
    private func enqueueFaceRecognitionIfNeeded() {
        let eventId = event.eventId
        let includeHidden = showHiddenPhotos
        Task.detached(priority: .utility) { [database] in
            _ = database.enqueueFaceRecognitionForEvent(
                eventId: eventId,
                includeHidden: includeHidden
            )
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
            reloadPhotoCollections()
            refreshDisplayItemsPreservingGroups()
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
            // Refresh scores in place — do not metadata-regroup or re-run visual refine.
            reloadPhotoCollections()
            refreshDisplayItemsPreservingGroups()
            selectedPhotoIds = selectedPhotoIds.intersection(Set(photos.map(\.id)))
        }.value
    }

    /// Loads trip day sections when present; otherwise falls back to flat event photos.
    /// Many `isTripEvent` rows have photos on the parent and zero child days — list previews
    /// still show `coverPhotoId`/slideshow, but day-only loading left detail empty.
    private func reloadPhotoCollections() {
        if event.isTripContainer {
            var sections = database.getTripSections(
                for: event.eventId,
                includeHidden: showHiddenPhotos
            )
            let allLinked = database.getPhotosForEvent(
                eventId: event.eventId,
                includeHidden: showHiddenPhotos
            )

            if sections.isEmpty {
                tripSections = []
                photos = allLinked
                return
            }

            let childPhotoIds = Set(sections.flatMap { $0.photos.map(\.id) })
            let parentOnly = allLinked.filter { !childPhotoIds.contains($0.id) }
            if !parentOnly.isEmpty {
                let parentSection = TripEventSection(
                    dayNumber: 1,
                    childEventName: "Trip photos",
                    subEventId: event.eventId,
                    photos: parentOnly
                )
                sections.insert(parentSection, at: 0)
            }

            tripSections = sections
            photos = sections.flatMap(\.photos)
        } else {
            tripSections = []
            photos = database.getPhotosForEvent(
                eventId: event.eventId,
                includeHidden: showHiddenPhotos
            )
        }
    }

    private func rebuildDisplayItems() {
        if event.isTripContainer, !tripSections.isEmpty {
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

    /// Keep current stack membership; swap in fresher `IndexedPhoto` rows (face scores, etc.).
    private func refreshDisplayItemsPreservingGroups() {
        let byId = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) })

        func refreshItems(_ items: [EventPhotoDisplayItem]) -> [EventPhotoDisplayItem] {
            items.map { item in
                let refreshedPhotos = item.group.photos.map { byId[$0.id] ?? $0 }
                let group = SimilarPhotoGroup(id: item.group.id, photos: refreshedPhotos)
                let picks = group.pickedPhotoIds(from: refreshedPhotos)
                return EventPhotoDisplayItem(
                    group: group,
                    representative: group.displayPhoto(picks: picks)
                )
            }
        }

        if event.isTripContainer, !tripPhotoDisplaySections.isEmpty {
            tripPhotoDisplaySections = tripPhotoDisplaySections.map { section in
                TripPhotoDisplaySection(
                    section: section.section,
                    displayItems: refreshItems(section.displayItems)
                )
            }
            photoDisplayItems = []
        } else if !photoDisplayItems.isEmpty {
            photoDisplayItems = refreshItems(photoDisplayItems)
            tripPhotoDisplaySections = []
        } else {
            rebuildDisplayItems()
        }
    }

    /// After metadata burst grouping, split stacks whose images are not visually alike.
    private func refineSimilarGroupsWithVisualSimilarityIfNeeded() {
        similarGroupRefineTask?.cancel()
        faceAnalysisTask?.cancel()

        let hasCandidateStacks = allDisplayItems.contains(where: \.isStack)
        guard hasCandidateStacks else {
            analyzeFaceMetricsForStacksIfNeeded()
            return
        }

        let useTripSections = event.isTripContainer && !tripSections.isEmpty
        let tripSnapshot = tripSections
        let flatSnapshot = photos
        let eventId = event.eventId

        similarGroupRefineTask = Task { [weak self] in
            guard let self else { return }

            if useTripSections {
                var refinedSections: [TripPhotoDisplaySection] = []
                refinedSections.reserveCapacity(tripSnapshot.count)
                for section in tripSnapshot {
                    if Task.isCancelled { return }
                    let items = await Task.detached(priority: .utility) {
                        await EventSimilarPhotoGrouper.refinedDisplayItems(from: section.photos)
                    }.value
                    refinedSections.append(
                        TripPhotoDisplaySection(section: section, displayItems: items)
                    )
                }
                guard !Task.isCancelled, self.event.eventId == eventId else { return }
                self.tripPhotoDisplaySections = refinedSections
                self.photoDisplayItems = []
                self.analyzeFaceMetricsForStacksIfNeeded()
            } else {
                let items = await Task.detached(priority: .utility) {
                    await EventSimilarPhotoGrouper.refinedDisplayItems(from: flatSnapshot)
                }.value
                guard !Task.isCancelled, self.event.eventId == eventId else { return }
                self.photoDisplayItems = items
                self.tripPhotoDisplaySections = []
                self.analyzeFaceMetricsForStacksIfNeeded()
            }
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
        case .wedding:
            // Event people first (by photo count), then the rest of the library.
            return EventMilestonePersonPickerOrdering.items(
                eventPeople: database.fetchEventPeople(
                    eventId: event.eventId,
                    includeChildEvents: true
                ),
                allPeople: database.fetchAllPeople()
            )
        case .graduation, .baptism, .anniversary:
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

    func assignCoupleMilestone(
        person1: MilestonePersonPickerItem,
        person2: MilestonePersonPickerItem,
        weddingDate selectedDate: Date
    ) {
        let isWedding = (milestoneType ?? event.resolvedAttributeValue(for: .milestoneType))?
            .caseInsensitiveCompare("Wedding") == .orderedSame

        if isWedding {
            // Bride then Groom — both under eventMainPerson.
            database.replaceUserEventMainPeople(
                eventId: event.eventId,
                names: [person1.name, person2.name]
            )
            eventMainPerson = person1.name
            eventMainPerson2 = person2.name
        } else {
            setAttribute(.mainPerson, value: person1.name)
            setAttribute(.secondaryMainPerson, value: person2.name)
        }

        let weddingDateISO = EventDateParser.dateOnlyISO(from: selectedDate)
        database.updateWeddingDate(eventId: event.eventId, weddingDate: weddingDateISO)
        weddingDate = weddingDateISO

        if isWedding {
            _ = database.propagateAnniversaryTagsFromWedding(
                sourceEventId: event.eventId,
                person1: person1.name,
                person2: person2.name,
                weddingDateISO: weddingDateISO
            )
            database.updateWeddingCoverPhotoForEvent(eventId: event.eventId)
            applyWeddingSuggestedNameIfAllowed(bride: person1.name, groom: person2.name)
        }

        refreshEvent()
        notifyEventUpdated()
    }

    /// Confirm AI Wedding milestone (source → user), then caller presents Bride/Groom picker.
    func confirmAIWeddingMilestoneTag(_ tag: EventAttributeTag) {
        guard tag.isAIDerived,
              tag.category == .milestoneType,
              tag.tagValue.compare("Wedding", options: .caseInsensitive) == .orderedSame else {
            confirmAIAttributeTag(tag)
            return
        }
        for eventId in tag.actionEventIds(displayEventId: event.eventId) {
            database.confirmAIAttributeTag(eventId: eventId, field: tag.category)
        }
        refreshEvent()
        notifyEventUpdated()
    }

    private func applyWeddingSuggestedNameIfAllowed(bride: String, groom: String) {
        guard !userEditedName else { return }
        let template = database.fetchEventNameTemplate(
            tagCategory: EventAttributeField.milestoneType.tagCategory,
            tagValue: "Wedding"
        )
        guard let name = MilestoneEventNaming.suggestCoupleEventName(
            person1: bride,
            person2: groom,
            milestoneType: "Wedding",
            weddingDateISO: weddingDate,
            eventStartDate: event.startDate,
            nameTemplate: template
        ) else {
            return
        }
        eventName = name
        userEditedName = false
        _ = saveEventName()
    }

    private func applyTemplatedSuggestedNameIfAllowed(
        tagValue: String,
        person1: String,
        person2: String?
    ) {
        guard !userEditedName else { return }
        guard let template = database.fetchEventNameTemplate(
            tagCategory: EventAttributeField.milestoneType.tagCategory,
            tagValue: tagValue
        ),
        let name = MilestoneEventNaming.suggestTemplatedEventName(
            nameTemplate: template,
            person1: person1,
            person2: person2
        ) else {
            return
        }
        eventName = name
        userEditedName = false
        _ = saveEventName()
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
        removeAttributeTag(tag)
    }

    /// Removes any event tag (AI or user). Offers `similar_event_tags` alternatives when present.
    func removeAttributeTag(_ tag: EventAttributeTag) {
        for eventId in tag.actionEventIds(displayEventId: event.eventId) {
            database.removeEventAttributeTag(eventId: eventId, tag: tag)
        }
        refreshEvent()
        notifyEventUpdated()
        presentSimilarEventAlternativesIfNeeded(removedTag: tag)
    }

    private func presentSimilarEventAlternativesIfNeeded(removedTag: EventAttributeTag) {
        let alternatives = database.fetchSimilarEventAlternatives(
            tagCategory: removedTag.category.tagCategory,
            tagValue: removedTag.tagValue
        )
        guard !alternatives.isEmpty else { return }
        pendingSimilarEventAlternatives = SimilarEventAlternativesRequest(
            displayEventId: event.eventId,
            event: event,
            rejectedTag: removedTag,
            alternatives: alternatives
        )
    }

    func applySimilarEventAlternative(_ alternative: SimilarEventTagAlternative) {
        pendingSimilarEventAlternatives = nil

        // Write exactly possibleTagCategory + possibleTagValue from similar_event_tags.
        database.applySimilarEventUserTag(
            eventId: event.eventId,
            tagCategory: alternative.possibleTagCategory,
            tagValue: alternative.possibleTagValue
        )

        if alternative.possibleNumberOfEventMainPeople > 0 {
            let people = EventMilestonePersonPickerOrdering.items(
                eventPeople: database.fetchEventPeople(
                    eventId: event.eventId,
                    includeChildEvents: true
                ),
                allPeople: database.fetchAllPeople()
            )
            pendingSimilarEventPeoplePick = SimilarEventPeoplePickRequest(
                displayEventId: event.eventId,
                event: event,
                alternative: alternative,
                people: people
            )
        }

        refreshEvent()
        notifyEventUpdated()
    }

    func completeSimilarEventPeoplePick(
        person1: MilestonePersonPickerItem,
        person2: MilestonePersonPickerItem?
    ) {
        let tagValue = pendingSimilarEventPeoplePick?.alternative.possibleTagValue
            ?? event.resolvedAttributeValue(for: .milestoneType)
            ?? milestoneType
        pendingSimilarEventPeoplePick = nil
        var names = [person1.name]
        if let person2 {
            names.append(person2.name)
        }
        database.replaceUserEventMainPeople(eventId: event.eventId, names: names)
        eventMainPerson = person1.name
        eventMainPerson2 = person2?.name
        if let tagValue {
            applyTemplatedSuggestedNameIfAllowed(
                tagValue: tagValue,
                person1: person1.name,
                person2: person2?.name
            )
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
        eventType = event.resolvedAttributeValue(for: .eventType)
        activityType = event.resolvedAttributeValue(for: .activityType)
        tripType = event.resolvedAttributeValue(for: .tripType)
        milestoneType = event.resolvedAttributeValue(for: .milestoneType)
        holidayType = event.resolvedAttributeValue(for: .holidayType)
        eventMainPerson = event.resolvedAttributeValue(for: .mainPerson)
        eventMainPerson2 = event.resolvedAttributeValue(for: .secondaryMainPerson)
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

        let photoIds = Array(selectedPhotoIds)
        var writes: [(photoId: String, show: Bool)] = []
        var similarGroupPicks: [(groupPhotoIds: [String], pickedPhotoIds: [String])] = []
        var localUpdates: [String: (showOnFrame: Bool, isSimilarGroupPick: Bool?)] = [:]
        var clearCropFocusPhotoIds: [String] = []

        if show {
            for photoId in photoIds {
                writes.append((photoId: photoId, show: true))
                localUpdates[photoId] = (true, nil)
                clearCropFocusPhotoIds.append(photoId)

                if let group = similarGroup(containingPhotoId: photoId), group.isStack {
                    for sibling in group.photos where sibling.id != photoId {
                        writes.append((photoId: sibling.id, show: false))
                        localUpdates[sibling.id] = (false, false)
                    }
                    localUpdates[photoId] = (true, true)
                    similarGroupPicks.append(
                        (
                            groupPhotoIds: group.photos.map(\.id),
                            pickedPhotoIds: [photoId]
                        )
                    )
                }
            }
        } else {
            for photoId in photoIds {
                writes.append((photoId: photoId, show: false))
                localUpdates[photoId] = (false, nil)
            }
        }

        applyLocalOnFrameFlags(localUpdates)
        persistOnFrameChangesInBackground(
            writes: writes,
            similarGroupPicks: similarGroupPicks,
            clearCropFocusPhotoIds: clearCropFocusPhotoIds
        )
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
        gameResult = database.fetchEventGameResult(eventId: event.eventId)
        if notifyList {
            notifyEventUpdated()
        }
    }

    @MainActor
    func findGameScore() async {
        guard !isLookingUpGameScore else { return }
        isLookingUpGameScore = true
        gameLookupStatus = "Looking up games…"
        gameLookupCandidates = []
        defer { isLookingUpGameScore = false }

        var placeName = event.placeName
        var city = event.city
        var state = event.state
        var latitude = event.latitude
        var longitude = event.longitude

        if let locationId = event.locationId,
           let location = database.getLocation(locationId: locationId) {
            if placeName?.isEmpty != false {
                placeName = location.placeName ?? location.nickname
            }
            if city?.isEmpty != false { city = location.city }
            if state?.isEmpty != false { state = location.state }
            if latitude == nil { latitude = location.latitude }
            if longitude == nil { longitude = location.longitude }
        }

        do {
            let result = try await database.lookupSportsGameCandidates(
                eventDateISO: event.startDate,
                placeName: placeName,
                city: city,
                state: state,
                latitude: latitude,
                longitude: longitude
            )
            gameLookupCandidates = result.candidates
            if result.candidates.count == 1, let only = result.candidates.first {
                saveGameCandidate(only)
                gameLookupStatus = "Saved \(only.coverScoreLine)"
            } else {
                showGameLookupCandidates = true
                gameLookupStatus = "\(result.candidates.count) matching games"
            }
        } catch {
            gameLookupStatus = error.localizedDescription
        }
    }

    func saveGameCandidate(_ candidate: SportsGameCandidate) {
        let now = ISO8601DateFormatter().string(from: Date())
        let saved = EventGameResult(
            eventId: event.eventId,
            stadiumId: candidate.stadiumId,
            league: candidate.league,
            espnEventId: candidate.espnEventId,
            homeTeam: candidate.homeTeam,
            awayTeam: candidate.awayTeam,
            homeScore: candidate.homeScore,
            awayScore: candidate.awayScore,
            gameDateISO: candidate.gameDateISO,
            venueName: candidate.venueName,
            summaryLine: candidate.summaryLine,
            source: "espn",
            updatedAt: now
        )
        database.saveEventGameResult(saved)
        gameResult = saved
        showGameLookupCandidates = false
        gameLookupStatus = "Saved \(saved.coverScoreLine)"
        applyGameSuggestedNameIfAllowed(saved.suggestedEventName)
    }

    func clearSavedGameScore() {
        database.clearEventGameResult(eventId: event.eventId)
        gameResult = nil
        gameLookupStatus = "Cleared game score"
    }

    private func applyGameSuggestedNameIfAllowed(_ name: String) {
        guard !userEditedName else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        eventName = trimmed
        userEditedName = false
        _ = saveEventName()
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

        var writes: [(photoId: String, show: Bool)] = [(photoId: photoId, show: show)]
        var similarGroupPicks: [(groupPhotoIds: [String], pickedPhotoIds: [String])] = []
        var localUpdates: [String: (showOnFrame: Bool, isSimilarGroupPick: Bool?)] = [
            photoId: (show, nil)
        ]

        if show, let group, group.isStack {
            for sibling in group.photos where sibling.id != photoId {
                writes.append((photoId: sibling.id, show: false))
                localUpdates[sibling.id] = (false, false)
            }
            localUpdates[photoId] = (true, true)
            similarGroupPicks.append(
                (
                    groupPhotoIds: group.photos.map(\.id),
                    pickedPhotoIds: [photoId]
                )
            )
        }

        applyLocalOnFrameFlags(localUpdates)
        persistOnFrameChangesInBackground(
            writes: writes,
            similarGroupPicks: similarGroupPicks,
            clearCropFocusPhotoIds: show ? [photoId] : []
        )
    }

    private func applyLocalOnFrameFlags(
        _ updates: [String: (showOnFrame: Bool, isSimilarGroupPick: Bool?)]
    ) {
        guard !updates.isEmpty else { return }

        func mapped(_ photo: IndexedPhoto) -> IndexedPhoto {
            guard let update = updates[photo.id] else { return photo }
            return photo.withShowOnFrame(
                update.showOnFrame,
                isSimilarGroupPick: update.isSimilarGroupPick
            )
        }

        photos = photos.map(mapped)
        if event.isTripContainer {
            tripSections = tripSections.map { section in
                TripEventSection(
                    dayNumber: section.dayNumber,
                    childEventName: section.childEventName,
                    subEventId: section.subEventId,
                    photos: section.photos.map(mapped)
                )
            }
        }
        // Preserve visually refined stacks — do not metadata-regroup.
        refreshDisplayItemsPreservingGroups()
    }

    private func persistOnFrameChangesInBackground(
        writes: [(photoId: String, show: Bool)],
        similarGroupPicks: [(groupPhotoIds: [String], pickedPhotoIds: [String])],
        clearCropFocusPhotoIds: [String]
    ) {
        let defaultEventId = event.eventId
        let database = AppDependencies.container.photoDatabase

        Task {
            await Task.detached(priority: .utility) {
                database.persistPhotoOnFrameChanges(
                    defaultEventId: defaultEventId,
                    writes: writes,
                    similarGroupPicks: similarGroupPicks,
                    clearCropFocusPhotoIds: clearCropFocusPhotoIds
                )
            }.value
            notifyEventUpdated()
        }
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

        // Preserve visually refined stacks — do not metadata-regroup.
        refreshDisplayItemsPreservingGroups()
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
