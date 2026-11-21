import Combine
import CoreLocation
import Foundation
import Photos
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
    /// Selection order so “first selected” is stable for Adjust Date.
    @Published private(set) var selectedPhotoIdOrder: [String] = []
    @Published private(set) var isAdjustingDates = false
    @Published private(set) var isMovingPhotos = false
    @Published private(set) var isAdjustingLocations = false
    @Published var showHiddenPhotos = false
    @Published var photoSort: EventDetailPhotoSort = .dateCaptured
    @Published var photoFilter: PictureBrowserFilter = .allItems
    private var sortMetadataByPhotoId: [String: EventPhotoSortMetadata] = [:]
    private var locationLabelByLocationId: [Int: String] = [:]
    @Published private(set) var analyzingFaceMetricsPhotoIds: Set<String> = []
    @Published private(set) var objectRecognitionStatus: String?
    @Published private(set) var gameResult: EventGameResult?
    @Published private(set) var gameLookupStatus: String?
    @Published private(set) var isLookingUpGameScore = false
    @Published private(set) var isRunningAIAssist = false
    @Published private(set) var isFindingDuplicates = false
    @Published private(set) var duplicateScanStatus: String?
    @Published private(set) var duplicateMatches: [EventPhotoDuplicateMatch] = []
    @Published var gameLookupCandidates: [SportsGameCandidate] = []
    @Published var showGameLookupCandidates = false
    @Published private(set) var locationGeocodeStatus: String?
    @Published var pendingSimilarEventAlternatives: SimilarEventAlternativesRequest?
    @Published var pendingSimilarEventPeoplePick: SimilarEventPeoplePickRequest?
    @Published var showWeddingCoupleNaming = false
    @Published private(set) var weddingCoupleNamingPhotoId: String?
    @Published private(set) var weddingCoupleNamingFaces: [PhotoFaceAnnotation] = []
    private var faceAnalysisTask: Task<Void, Never>?
    private var similarGroupRefineTask: Task<Void, Never>?
    private var objectRecognitionTask: Task<Void, Never>?
    private var locationGeocodeTask: Task<Void, Never>?
    private var aiAssistTask: Task<Void, Never>?
    private var findDuplicatesTask: Task<Void, Never>?
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
        gridBlocks.reduce(0) { partial, block in
            partial + block.groups.reduce(0) { $0 + $1.items.count }
        }
    }

    var collapsedSimilarPhotoCount: Int {
        max(0, photos.count - visiblePhotoCount)
    }

    var displayRepresentatives: [IndexedPhoto] {
        fullscreenDisplayItems.map(\.representative)
    }

    var fullscreenDisplayItems: [EventPhotoDisplayItem] {
        gridBlocks.flatMap { block in
            block.groups.flatMap(\.items)
        }
    }

    /// Trip day blocks (optional) with sort-grouped photo sections for the sticky grid.
    var gridBlocks: [EventDetailPhotoBlock] {
        if event.isTripContainer, !tripPhotoDisplaySections.isEmpty {
            return tripPhotoDisplaySections.map { trip in
                EventDetailPhotoBlock(
                    id: "trip-\(trip.id)",
                    tripSection: trip,
                    groups: sortGroups(from: filteredItems(trip.displayItems), idPrefix: "trip-\(trip.id)")
                )
            }
            .filter { !$0.groups.isEmpty }
        }

        let groups = sortGroups(from: filteredItems(photoDisplayItems), idPrefix: "photos")
        guard !groups.isEmpty else { return [] }
        return [
            EventDetailPhotoBlock(
                id: "photos",
                tripSection: nil,
                groups: groups
            )
        ]
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

    func loadPhotos(skipHeavyWork: Bool = false) {
        reloadPhotoCollections()
        rebuildDisplayItems()
        reloadSortMetadata()
        selectedPhotoIds = selectedPhotoIds.intersection(Set(photos.map(\.id)))
        selectedPhotoIdOrder = selectedPhotoIdOrder.filter { selectedPhotoIds.contains($0) }
        syncTripChildEventNameDrafts()
        guard !skipHeavyWork else { return }
        // Face metrics wait until visual refine finishes — otherwise mega metadata
        // stacks (shared import timestamps) thrash: refine ↔ face reload ↔ regroup.
        refineSimilarGroupsWithVisualSimilarityIfNeeded()
        runObjectRecognitionIfNeeded()
        enqueueFaceRecognitionIfNeeded()
        ensureLocationGeocodedIfNeeded()
    }

    private func reloadSortMetadata() {
        let ids = photos.map(\.id)
        let payload = database.fetchEventPhotoSortMetadata(photoIds: ids)
        sortMetadataByPhotoId = payload.metadata
        locationLabelByLocationId = payload.locationLabels
        objectWillChange.send()
    }

    private func filteredItems(_ items: [EventPhotoDisplayItem]) -> [EventPhotoDisplayItem] {
        items.filter { passesFilter($0.representative) }
    }

    private func passesFilter(_ photo: IndexedPhoto) -> Bool {
        switch photoFilter {
        case .allItems:
            return true
        case .onFrame:
            return photo.showOnFrame
        case .offFrame:
            return !photo.showOnFrame
        case .favorites:
            return photo.isFavorite
        case .photos:
            return !photo.isVideo
        case .video:
            return photo.isVideo
        }
    }

    private func sortGroups(
        from items: [EventPhotoDisplayItem],
        idPrefix: String
    ) -> [EventDetailPhotoSortGroup] {
        guard !items.isEmpty else { return [] }

        var buckets: [String: (title: String, items: [EventPhotoDisplayItem])] = [:]
        for item in items {
            let group = sortGroup(for: item)
            var bucket = buckets[group.key] ?? (group.title, [])
            bucket.items.append(item)
            buckets[group.key] = bucket
        }

        let orderedKeys = buckets.keys.sorted { lhs, rhs in
            sortGroupSortOrder(lhs) < sortGroupSortOrder(rhs)
        }

        return orderedKeys.map { key in
            let bucket = buckets[key]!
            let sortedItems = bucket.items.sorted { lhs, rhs in
                let leftDate = lhs.representative.creationDate
                let rightDate = rhs.representative.creationDate
                if leftDate != rightDate {
                    return leftDate < rightDate
                }
                return lhs.representative.id < rhs.representative.id
            }
            return EventDetailPhotoSortGroup(
                id: "\(idPrefix)-\(key)",
                title: bucket.title,
                items: sortedItems
            )
        }
    }

    private func sortGroup(for item: EventPhotoDisplayItem) -> (key: String, title: String) {
        let photo = item.representative
        let metadata = sortMetadataByPhotoId[photo.id]

        switch photoSort {
        case .dateCaptured:
            let day = dayKey(from: photo.creationDate)
            return (day, formatDayTitle(dayKey: day, fallbackISO: photo.creationDate))

        case .dateImported:
            let source = metadata?.indexedAt ?? photo.creationDate
            let day = dayKey(from: source)
            return (day, formatDayTitle(dayKey: day, fallbackISO: source))

        case .cameraType:
            let label = metadata?.cameraLabel ?? "Unknown Camera"
            return (label.lowercased(), label)

        case .location:
            if let locationId = metadata?.locationId,
               let label = locationLabelByLocationId[locationId],
               !label.isEmpty,
               label != PhotoPreviewLocationFormatting.noGPSData {
                return ("loc-\(locationId)", label)
            }
            return ("no-location", "No Location")
        }
    }

    private func sortGroupSortOrder(_ key: String) -> String {
        if key == "no-location" || key == "unknown camera" {
            return "\u{FFFF}\(key)"
        }
        return key
    }

    private func dayKey(from iso: String) -> String {
        if let date = EventDateParser.parseDate(iso) {
            return EventDateParser.dateOnlyISO(from: date)
        }
        return String(iso.prefix(10))
    }

    private func formatDayTitle(dayKey: String, fallbackISO: String) -> String {
        if let date = EventDateParser.parseDate(dayKey)
            ?? EventDateParser.parseDate(fallbackISO) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "MMMM d, yyyy"
            return formatter.string(from: date)
        }
        return dayKey
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

            self.reloadSortMetadata()
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
        aiAssistTask?.cancel()
        aiAssistTask = nil
        isRunningAIAssist = false
        objectRecognitionStatus = nil
        cancelFindDuplicates()
        cancelLocationGeocode()
    }

    func cancelFindDuplicates() {
        findDuplicatesTask?.cancel()
        findDuplicatesTask = nil
        isFindingDuplicates = false
        duplicateScanStatus = nil
    }

    /// AI Assist: locations → vision → faces → OCR text → score cards → suggested name → sports confirm.
    func runAIAssist() {
        guard !isRunningAIAssist else { return }
        aiAssistTask?.cancel()
        objectRecognitionTask?.cancel()

        let eventId = event.eventId
        let includeHidden = showHiddenPhotos
        let database = database

        aiAssistTask = Task { [weak self] in
            guard let self else { return }
            await MainActor.run {
                self.isRunningAIAssist = true
                self.objectRecognitionStatus = "AI Assist: assigning locations…"
            }

            let locationUpdated = await database.ensureEventLocationGeocoded(eventId: eventId)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.reloadSortMetadata()
                if locationUpdated {
                    self.refreshEvent(notifyList: true)
                }
                self.objectRecognitionStatus = "AI Assist: tagging photos…"
            }

            let visionReport = await database.scanEventPhotosWithVisionTags(
                eventId: eventId,
                includeHiddenPhotos: includeHidden
            ) { current, total in
                Task { @MainActor [weak self] in
                    guard let self, !Task.isCancelled else { return }
                    self.objectRecognitionStatus =
                        "AI Assist: tagging photos… \(current.formatted())/\(total.formatted())"
                }
            }
            guard !Task.isCancelled else { return }

            await MainActor.run {
                self.objectRecognitionStatus = "AI Assist: detecting faces…"
            }
            _ = await Task.detached(priority: .utility) {
                database.enqueueFaceRecognitionForEvent(
                    eventId: eventId,
                    includeHidden: includeHidden
                )
            }.value
            guard !Task.isCancelled else { return }

            await MainActor.run {
                self.objectRecognitionStatus = "AI Assist: reading text in photos…"
            }
            let textReport = await database.scanEventPhotosForText(
                eventId: eventId,
                includeHiddenPhotos: includeHidden
            ) { current, total in
                Task { @MainActor [weak self] in
                    guard let self, !Task.isCancelled else { return }
                    self.objectRecognitionStatus =
                        "AI Assist: reading text… \(current.formatted())/\(total.formatted())"
                }
            }
            guard !Task.isCancelled else { return }

            let cards = await Task.detached(priority: .utility) {
                database.fetchAllEventScoreCardSettings()
            }.value
            guard !Task.isCancelled else { return }

            var tagsApplied = 0
            for (index, card) in cards.enumerated() {
                await MainActor.run {
                    self.objectRecognitionStatus =
                        "AI Assist: scoring \(card.targetEventType)…"
                        + " \(index + 1)/\(cards.count)"
                }
                let score = await Task.detached(priority: .utility) {
                    database.scoreEventAgainstScoreCard(eventId: eventId, scoreCard: card)
                }.value
                if card.meetsAIThreshold(totalScore: score.totalScore) {
                    tagsApplied += 1
                }
                guard !Task.isCancelled else { return }
            }

            await MainActor.run {
                self.refreshEvent()
                var status =
                    "AI Assist: scored \(cards.count) cards"
                    + (tagsApplied > 0 ? " · \(tagsApplied) above threshold" : "")
                    + (visionReport.photosScanned > 0
                        ? " · \(visionReport.photosScanned) photos tagged"
                        : "")
                if textReport.photosScanned > 0 || textReport.photosWithText > 0 {
                    status += " · \(textReport.photosWithText) with text"
                }
                self.objectRecognitionStatus = status
            }

            // Step 3.5 — tagValue-specific tasks (Wedding couple first).
            let weddingCoupleSummary = await runAIAssistTagValueTasks(eventId: eventId)

            await MainActor.run {
                self.refreshEvent()
                // AI Assist explicitly owns the title for this run (grey / non-user name).
                self.userEditedName = false
                self.applySuggestedName()
                if let weddingCoupleSummary, !weddingCoupleSummary.isEmpty {
                    let base = self.objectRecognitionStatus ?? "AI Assist"
                    self.objectRecognitionStatus = "\(base) · \(weddingCoupleSummary)"
                }
            }

            if shouldOfferSportsScoreConfirm {
                objectRecognitionStatus = "AI Assist: looking up game score…"
                await findGameScoreForConfirm()
            }

            guard !Task.isCancelled else {
                await MainActor.run { self.isRunningAIAssist = false }
                return
            }
            await MainActor.run {
                self.isRunningAIAssist = false
                if self.showGameLookupCandidates {
                    self.objectRecognitionStatus = "AI Assist: confirm game score"
                } else {
                    let base = self.objectRecognitionStatus ?? "AI Assist done."
                    self.objectRecognitionStatus = base.hasPrefix("AI Assist:")
                        ? base.replacingOccurrences(of: "AI Assist:", with: "AI Assist done:")
                        : "AI Assist done."
                }
            }

            try? await Task.sleep(for: .seconds(5))
            await MainActor.run {
                if self.objectRecognitionStatus?.hasPrefix("AI Assist") == true,
                   !self.showGameLookupCandidates {
                    self.objectRecognitionStatus = nil
                }
            }
        }
    }

    /// Scans this event’s photos against the library for near-identical copies.
    func findDuplicates() {
        guard !isFindingDuplicates else { return }
        findDuplicatesTask?.cancel()

        let eventId = event.eventId
        let includeHidden = showHiddenPhotos

        findDuplicatesTask = Task { [weak self] in
            guard let self else { return }
            await MainActor.run {
                self.isFindingDuplicates = true
                self.duplicateMatches = []
                self.duplicateScanStatus = "Finding duplicates…"
            }

            let count = await self.runDuplicateScan(
                eventId: eventId,
                includeHidden: includeHidden
            )
            guard !Task.isCancelled else {
                await MainActor.run {
                    self.isFindingDuplicates = false
                    self.duplicateScanStatus = nil
                }
                return
            }

            await MainActor.run {
                self.isFindingDuplicates = false
                if count == 0 {
                    self.duplicateScanStatus = "No duplicates found"
                } else {
                    self.duplicateScanStatus =
                        "\(count) duplicate\(count == 1 ? "" : "s") found"
                }
            }

            try? await Task.sleep(for: .seconds(4))
            await MainActor.run {
                if self.duplicateScanStatus?.hasPrefix("No duplicates") == true
                    || self.duplicateScanStatus?.hasSuffix("found") == true {
                    self.duplicateScanStatus = nil
                }
            }
        }
    }

    /// Scans event photos against the library for near-identical copies. Returns match count.
    private func runDuplicateScan(eventId: Int, includeHidden: Bool) async -> Int {
        let database = database
        let eventPhotos = await Task.detached(priority: .utility) {
            database.getPhotosForEvent(eventId: eventId, includeHidden: includeHidden)
        }.value
        guard !Task.isCancelled, !eventPhotos.isEmpty else { return 0 }

        let libraryRows = await Task.detached(priority: .utility) {
            database.fetchAllPhotosForBrowser()
        }.value
        guard !Task.isCancelled else { return 0 }

        let libraryPhotos = libraryRows.map(\.photo)
        let rawMatches = await EventLibraryDuplicateDetector.findDuplicates(
            eventPhotos: eventPhotos,
            libraryPhotos: libraryPhotos
        ) { progress in
            Task { @MainActor [weak self] in
                guard let self, !Task.isCancelled else { return }
                self.duplicateScanStatus =
                    "Finding duplicates… \(progress.current.formatted())/\(progress.total.formatted())"
            }
        }
        guard !Task.isCancelled else { return 0 }

        let libraryById = Dictionary(uniqueKeysWithValues: libraryPhotos.map { ($0.id, $0) })
        let eventById = Dictionary(uniqueKeysWithValues: eventPhotos.map { ($0.id, $0) })
        let currentEventTitle = await MainActor.run {
            self.event.listTitleText ?? self.event.name
        }
        var enriched: [EventPhotoDuplicateMatch] = []
        enriched.reserveCapacity(rawMatches.count)

        for raw in rawMatches {
            if Task.isCancelled { break }
            guard let libraryPhoto = libraryById[raw.libraryPhotoId],
                  let eventPhoto = eventById[raw.eventPhotoId] else {
                continue
            }

            let eventLocationLine = await Task.detached(priority: .utility) {
                database.photoPreviewLocationLine(photoId: raw.eventPhotoId)
            }.value
            let libraryLocationLine = await Task.detached(priority: .utility) {
                database.photoPreviewLocationLine(photoId: raw.libraryPhotoId)
            }.value

            let libraryEventId = database.getEventIdForPhoto(photoId: raw.libraryPhotoId)
            let libraryEventTitle: String? = {
                guard let libraryEventId,
                      let indexed = database.getEvent(eventId: libraryEventId) else {
                    return nil
                }
                return indexed.listTitleText ?? indexed.name
            }()

            enriched.append(
                EventPhotoDuplicateMatch(
                    eventSide: EventPhotoDuplicateSideInfo(
                        photoId: raw.eventPhotoId,
                        creationDate: eventPhoto.creationDate,
                        locationLine: eventLocationLine,
                        eventId: eventId,
                        eventTitle: currentEventTitle
                    ),
                    librarySide: EventPhotoDuplicateSideInfo(
                        photoId: raw.libraryPhotoId,
                        creationDate: libraryPhoto.creationDate,
                        locationLine: libraryLocationLine,
                        eventId: libraryEventId,
                        eventTitle: libraryEventTitle
                    ),
                    distance: raw.distance
                )
            )
        }

        await MainActor.run {
            self.duplicateMatches = enriched
        }
        return enriched.count
    }

    /// Hides selected photos in their linked events (this event and/or the duplicate's event).
    func hideDuplicatePhotos(photoIds: [String]) {
        let ids = Array(Set(photoIds))
        guard !ids.isEmpty else { return }
        _ = database.setPhotosHiddenInEvent(photoIds: ids, hidden: true)
        removeDuplicateMatches(involving: ids)
        loadPhotos(skipHeavyWork: true)
        refreshEvent()
    }

    /// Soft-deletes in MagicFrame and removes assets from Apple Photos.
    func deleteDuplicatePhotos(photoIds: [String]) async -> String? {
        let ids = Array(Set(photoIds))
        guard !ids.isEmpty else { return nil }

        let photosError = await deleteAssetsFromPhotoLibrary(photoIds: ids)
        database.softDeletePhotos(photoIds: ids)
        removeDuplicateMatches(involving: ids)
        loadPhotos(skipHeavyWork: true)
        refreshEvent()
        onEventUpdated?(event.eventId)
        return photosError
    }

    private func removeDuplicateMatches(involving photoIds: [String]) {
        let removed = Set(photoIds)
        duplicateMatches.removeAll {
            removed.contains($0.eventPhotoId) || removed.contains($0.libraryPhotoId)
        }
    }

    private func deleteAssetsFromPhotoLibrary(photoIds: [String]) async -> String? {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            return "Photos access is required to delete from Apple Photos. MagicFrame copies were still removed."
        }

        return await withCheckedContinuation { continuation in
            var resumed = false
            let resumeOnce: (String?) -> Void = { message in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: message)
            }

            let result = PHAsset.fetchAssets(withLocalIdentifiers: photoIds, options: nil)
            guard result.count > 0 else {
                resumeOnce(nil)
                return
            }

            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.deleteAssets(result)
            }, completionHandler: { success, error in
                if let error {
                    resumeOnce(error.localizedDescription)
                } else if !success {
                    resumeOnce("Could not delete some photos from Apple Photos.")
                } else {
                    resumeOnce(nil)
                }
            })
        }
    }

    /// TagValue-specific AI Assist work after score cards (Wedding couple resolve, etc.).
    private func runAIAssistTagValueTasks(eventId: Int) async -> String? {
        await MainActor.run {
            refreshEvent()
        }
        let milestone = await MainActor.run { () -> String? in
            (milestoneType ?? event.resolvedAttributeValue(for: .milestoneType))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let milestone,
              milestone.compare("Wedding", options: .caseInsensitive) == .orderedSame else {
            return nil
        }

        await MainActor.run {
            objectRecognitionStatus = "AI Assist: finding bride & groom…"
        }

        let resolution = await Task.detached(priority: .utility) { [database] in
            database.resolveAndApplyWeddingCouple(eventId: eventId)
        }.value

        return resolution.statusSummary
    }

    private var shouldOfferSportsScoreConfirm: Bool {
        if gameResult != nil { return false }
        let type = (eventType ?? event.resolvedAttributeValue(for: .eventType))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if type?.compare("Sporting event", options: .caseInsensitive) == .orderedSame {
            return true
        }
        // Stadium location — place name often includes "Stadium" / venue from library.
        let haystack = [
            event.placeName,
            event.locationTitleLine,
            event.city,
        ]
        .compactMap { $0?.lowercased() }
        .joined(separator: " ")
        return haystack.contains("stadium") || haystack.contains("arena")
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
            selectedPhotoIdOrder = selectedPhotoIdOrder.filter { selectedPhotoIds.contains($0) }
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
            // Bride → eventMainPerson, Groom → eventMainPerson2.
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
            _ = database.upsertMarriedCoupleRelationship(
                bridePersonId: person1.personId,
                groomPersonId: person2.personId,
                weddingDateISO: weddingDateISO,
                sourceEventId: event.eventId
            )
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

    /// Confirm AI Wedding milestone (source → user), then caller presents couple naming UI.
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
        _ = prepareWeddingCoupleNamingSheet()
    }

    /// Loads couple-only photo + faces for naming. Returns false when caller should use people list.
    @discardableResult
    func prepareWeddingCoupleNamingSheet() -> Bool {
        let photoId = database.weddingCouplePhotoId(eventId: event.eventId)
            ?? database.resolveAndApplyWeddingCouple(eventId: event.eventId).couplePhotoId
        guard let photoId, !photoId.isEmpty else {
            showWeddingCoupleNaming = false
            weddingCoupleNamingPhotoId = nil
            weddingCoupleNamingFaces = []
            return false
        }
        let faces = database.fetchFaceAnnotations(forPhotoId: photoId)
        guard faces.count >= 2 else {
            weddingCoupleNamingPhotoId = nil
            weddingCoupleNamingFaces = []
            showWeddingCoupleNaming = false
            return false
        }
        weddingCoupleNamingPhotoId = photoId
        weddingCoupleNamingFaces = Array(faces.prefix(2))
        showWeddingCoupleNaming = true
        return true
    }

    func completeWeddingCoupleNaming(
        brideFaceId: Int,
        brideName: String,
        groomFaceId: Int,
        groomName: String,
        weddingDate selectedDate: Date
    ) {
        let bridePersonId = database.nameFaceInstance(
            faceInstanceId: brideFaceId,
            displayName: brideName,
            firstName: nil,
            lastName: nil,
            maidenName: nil
        )
        let groomPersonId = database.nameFaceInstance(
            faceInstanceId: groomFaceId,
            displayName: groomName,
            firstName: nil,
            lastName: nil,
            maidenName: nil
        )
        guard bridePersonId > 0, groomPersonId > 0 else { return }

        assignCoupleMilestone(
            person1: MilestonePersonPickerItem(
                personId: bridePersonId,
                name: brideName,
                birthDateISO: nil
            ),
            person2: MilestonePersonPickerItem(
                personId: groomPersonId,
                name: groomName,
                birthDateISO: nil
            ),
            weddingDate: selectedDate
        )
        showWeddingCoupleNaming = false
        weddingCoupleNamingPhotoId = nil
        weddingCoupleNamingFaces = []
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
        selectedPhotoIdOrder.removeAll()
    }

    func cancelPhotoSelection() {
        isSelectingPhotos = false
        selectedPhotoIds.removeAll()
        selectedPhotoIdOrder.removeAll()
    }

    func togglePhotoSelection(photoId: String) {
        if selectedPhotoIds.contains(photoId) {
            selectedPhotoIds.remove(photoId)
            selectedPhotoIdOrder.removeAll { $0 == photoId }
        } else {
            selectedPhotoIds.insert(photoId)
            selectedPhotoIdOrder.append(photoId)
        }
    }

    private var selectedRepresentativePhotos: [IndexedPhoto] {
        photos.filter { selectedPhotoIds.contains($0.id) }
    }

    var adjustDateAnchorDate: Date? {
        guard let anchorId = selectedPhotoIdOrder.first,
              let photo = photos.first(where: { $0.id == anchorId })
                ?? selectedRepresentativePhotos.first,
              let date = EventDateParser.parseDate(photo.creationDate) else {
            return nil
        }
        return date
    }

    func makeDateAdjustPreview(adjustedAnchor: Date) -> PhotoDateAdjustPreview? {
        guard let originalAnchor = adjustDateAnchorDate else { return nil }
        let delta = adjustedAnchor.timeIntervalSince(originalAnchor)
        let orderedIds = selectedPhotoIdOrder.isEmpty
            ? Array(selectedPhotoIds)
            : selectedPhotoIdOrder
        guard !orderedIds.isEmpty else { return nil }

        var updates: [(photoId: String, originalDate: Date, newDate: Date)] = []
        for photoId in orderedIds {
            guard let photo = photos.first(where: { $0.id == photoId }),
                  let original = EventDateParser.parseDate(photo.creationDate) else {
                continue
            }
            updates.append(
                (
                    photoId: photoId,
                    originalDate: original,
                    newDate: original.addingTimeInterval(delta)
                )
            )
        }
        guard !updates.isEmpty else { return nil }

        let rangeStart = updates.map(\.newDate).min() ?? adjustedAnchor
        let rangeEnd = updates.map(\.newDate).max() ?? adjustedAnchor
        let leaves = datesLeaveCurrentEvent(updates.map(\.newDate))
        return PhotoDateAdjustPreview(
            updates: updates,
            rangeStart: rangeStart,
            rangeEnd: rangeEnd,
            leavesCurrentEvent: leaves
        )
    }

    private func datesLeaveCurrentEvent(_ dates: [Date]) -> Bool {
        guard let eventStart = EventDateParser.parseDate(event.startDate),
              let eventEnd = EventDateParser.parseDate(event.endDate) else {
            return false
        }
        let start = min(eventStart, eventEnd)
        let end = max(eventStart, eventEnd)
        return dates.contains { $0 < start || $0 > end }
    }

    func candidateEventsForDateAdjust(preview: PhotoDateAdjustPreview) -> [IndexedEvent] {
        database.findEventsContainingDateRange(
            rangeStart: preview.rangeStart,
            rangeEnd: preview.rangeEnd,
            excludingEventId: event.eventId
        )
        .filter { !$0.isEverydayPhotos }
    }

    func selectedPhotoDateMap() -> [String: Date] {
        var dates: [String: Date] = [:]
        for photo in photos where selectedPhotoIds.contains(photo.id) {
            if let date = EventDateParser.parseDate(photo.creationDate) {
                dates[photo.id] = date
            }
        }
        return dates
    }

    func eventsForPhotoMove() -> [IndexedEvent] {
        database.getEvents(includeHidden: false)
            .filter { candidate in
                candidate.eventId != event.eventId
                    && !candidate.isEverydayPhotos
                    && candidate.parentEventId == nil
            }
            .sorted { $0.startDate > $1.startDate }
    }

    func moveWindow(for destination: IndexedEvent, dates: [String: Date]) -> PhotoMoveWindow? {
        guard let start = EventDateParser.parseDate(destination.startDate),
              let end = EventDateParser.parseDate(destination.endDate) else {
            return nil
        }
        return PhotoMoveWindow.evaluate(dates: dates, windowStart: start, windowEnd: end)
    }

    /// True when moving the current selection to Everyday would empty this event
    /// and `cleanupEmptyEvents` would soft-delete it (non-trip events only).
    var willSoftDeleteEventIfMovingSelectedToEveryday: Bool {
        guard !event.isTripEvent else { return false }
        guard !selectedPhotoIds.isEmpty else { return false }

        let loadedIds = Set(photos.map(\.id))
        guard !loadedIds.isEmpty else { return false }

        // Hidden photos not currently loaded would keep the event alive.
        if !showHiddenPhotos, event.photoCount > loadedIds.count {
            return false
        }

        return loadedIds.isSubset(of: selectedPhotoIds)
    }

    /// Moves the selection into Everyday Photos months.
    /// Returns `true` when the source event was soft-deleted because it became empty.
    @discardableResult
    func moveSelectedPhotosToEveryday() async -> Bool {
        let dates = selectedPhotoDateMap()
        guard !dates.isEmpty else { return false }
        isMovingPhotos = true
        defer { isMovingPhotos = false }

        // Let the "Moving photos…" overlay paint before the DB queue blocks.
        await Task.yield()

        let photoIds = Array(dates.keys)
        let fromEventId = event.eventId
        await Task.detached(priority: .userInitiated) {
            AppDependencies.database.movePhotosIntoEveryday(
                photoIds: photoIds,
                fromEventId: fromEventId,
                photoDates: dates
            )
        }.value

        finishPhotoMove()
        return database.getEvent(eventId: fromEventId) == nil
    }

    func moveSelectedPhotos(
        to destinationId: Int,
        dates: [String: Date],
        expandDestinationDates: Bool
    ) {
        guard !dates.isEmpty else { return }
        isMovingPhotos = true
        defer { isMovingPhotos = false }
        database.movePhotosOntoEvent(
            photoIds: Array(dates.keys),
            fromEventId: event.eventId,
            toEventId: destinationId,
            photoDates: dates,
            expandDestinationDates: expandDestinationDates
        )
        finishPhotoMove()
    }

    func applyInsideDatesThenMove(
        updates: [(photoId: String, newCreationDate: Date)],
        destinationId: Int,
        dates: [String: Date]
    ) {
        database.shiftPhotoCaptureDates(updates: updates)
        var merged = dates
        for update in updates {
            merged[update.photoId] = update.newCreationDate
        }
        moveSelectedPhotos(
            to: destinationId,
            dates: merged,
            expandDestinationDates: false
        )
    }

    private func finishPhotoMove() {
        cancelPhotoSelection()
        loadPhotos(skipHeavyWork: true)
        refreshEvent()
        onEventUpdated?(event.eventId)
    }

    @discardableResult
    func commitDateAdjust(
        preview: PhotoDateAdjustPreview,
        destination: PhotoDateAdjustDestination?
    ) async -> PhotoDateAdjustResult {
        isAdjustingDates = true
        defer { isAdjustingDates = false }
        // Let the progress overlay paint before heavy work.
        await Task.yield()

        let photoIds = preview.photoIds
        // MagicFrame DB + event membership first so UI unblocks; Photos library can lag on iCloud.
        database.shiftPhotoCaptureDates(
            updates: preview.updates.map { ($0.photoId, $0.newDate) }
        )

        let iso8601 = ISO8601DateFormatter()
        photos = photos.map { photo in
            guard let update = preview.updates.first(where: { $0.photoId == photo.id }) else {
                return photo
            }
            return photo.withCreationDate(iso8601.string(from: update.newDate))
        }

        guard preview.leavesCurrentEvent else {
            refreshDisplayItemsPreservingGroups()
            cancelPhotoSelection()
            return PhotoDateAdjustResult(
                kind: .datesOnly,
                updatedCount: photoIds.count,
                errorMessage: nil
            )
        }

        guard let destination else {
            refreshDisplayItemsPreservingGroups()
            cancelPhotoSelection()
            return PhotoDateAdjustResult(
                kind: .datesOnly,
                updatedCount: photoIds.count,
                errorMessage: "Choose where to move these photos."
            )
        }

        let locationId = selectedRepresentativePhotos.compactMap(\.locationId).first
            ?? event.locationId
        let latitude = selectedRepresentativePhotos.compactMap(\.latitude).first
            ?? event.latitude
        let longitude = selectedRepresentativePhotos.compactMap(\.longitude).first
            ?? event.longitude

        let destinationEvent: IndexedEvent?
        switch destination {
        case .createNew:
            destinationEvent = database.createEventForShiftedPhotos(
                photoIds: photoIds,
                fromEventId: event.eventId,
                rangeStart: preview.rangeStart,
                rangeEnd: preview.rangeEnd,
                locationId: locationId,
                latitude: latitude,
                longitude: longitude
            )
        case let .existing(eventId):
            database.movePhotosToEvent(
                photoIds: photoIds,
                fromEventId: event.eventId,
                toEventId: eventId,
                photoDates: preview.photoDates
            )
            destinationEvent = database.getEvent(eventId: eventId)
        }

        cancelPhotoSelection()
        // Skip vision/face/geocode — those were the multi-minute hang after a successful move.
        loadPhotos(skipHeavyWork: true)
        refreshEvent()

        let sourceGone = database.getEvent(eventId: event.eventId) == nil
            || (!showHiddenPhotos && photos.isEmpty)

        guard let destinationEvent else {
            return PhotoDateAdjustResult(
                kind: .datesOnly,
                updatedCount: photoIds.count,
                errorMessage: "Could not move photos to another event."
            )
        }

        onEventUpdated?(event.eventId)
        onEventUpdated?(destinationEvent.eventId)

        return PhotoDateAdjustResult(
            kind: .movedToEvent(destinationEvent, sourceEmptied: sourceGone),
            updatedCount: photoIds.count,
            errorMessage: nil
        )
    }

    /// Writes adjusted dates to Apple Photos, then promotes overrides into library `creationDate`.
    func syncAdjustedDatesToApplePhotos(
        _ updates: [(photoId: String, newDate: Date)]
    ) async -> String? {
        let error = await PhotosAssetMetadataWriter.updateCreationDates(
            updates.map { ($0.photoId, $0.newDate) }
        )
        guard error == nil else { return error }
        database.promoteCaptureDatesAfterPhotosSync(
            updates: updates.map { ($0.photoId, $0.newDate) }
        )
        return nil
    }

    private var locationAdjustAnchorPhoto: IndexedPhoto? {
        guard let anchorId = selectedPhotoIdOrder.first else {
            return selectedRepresentativePhotos.first
        }
        return photos.first(where: { $0.id == anchorId })
            ?? selectedRepresentativePhotos.first
    }

    var adjustLocationAnchorCoordinate: (latitude: Double, longitude: Double)? {
        guard let photo = locationAdjustAnchorPhoto,
              let latitude = photo.latitude,
              let longitude = photo.longitude else {
            return nil
        }
        return (latitude, longitude)
    }

    var adjustLocationAnchorLabel: String {
        guard let photo = locationAdjustAnchorPhoto else {
            return PhotoPreviewLocationFormatting.noGPSData
        }
        if let locationId = photo.locationId,
           let location = database.getLocation(locationId: locationId) {
            return location.displayTitle
        }
        return PhotoPreviewLocationFormatting.line(
            nickname: nil,
            placeName: nil,
            city: nil,
            state: nil,
            latitude: photo.latitude,
            longitude: photo.longitude
        )
    }

    func locationsForAdjust() -> [ManagedLocation] {
        database.getLocationsRankedByEventCount()
            .filter { $0.latitude != nil && $0.longitude != nil }
    }

    func makeLocationAdjustPreview(location: ManagedLocation) -> PhotoLocationAdjustPreview? {
        guard let latitude = location.latitude,
              let longitude = location.longitude else {
            return nil
        }
        let orderedIds = selectedPhotoIdOrder.isEmpty
            ? Array(selectedPhotoIds)
            : selectedPhotoIdOrder
        guard !orderedIds.isEmpty else { return nil }
        return PhotoLocationAdjustPreview(
            photoIds: orderedIds,
            latitude: latitude,
            longitude: longitude,
            locationId: location.locationId,
            locationLabel: location.displayTitle
        )
    }

    @discardableResult
    func commitLocationAdjust(
        preview: PhotoLocationAdjustPreview
    ) async -> PhotoLocationAdjustResult {
        isAdjustingLocations = true
        defer { isAdjustingLocations = false }
        await Task.yield()

        let photoIds = preview.photoIds
        database.shiftPhotoLocations(
            updates: photoIds.map {
                (
                    photoId: $0,
                    latitude: preview.latitude,
                    longitude: preview.longitude,
                    locationId: preview.locationId
                )
            }
        )

        photos = photos.map { photo in
            guard photoIds.contains(photo.id) else { return photo }
            return photo.withLocation(
                latitude: preview.latitude,
                longitude: preview.longitude,
                locationId: preview.locationId
            )
        }
        database.refreshEventPlacesForPhotos(photoIds: photoIds)
        refreshDisplayItemsPreservingGroups()
        cancelPhotoSelection()

        return PhotoLocationAdjustResult(
            updatedCount: photoIds.count,
            errorMessage: nil
        )
    }

    /// Writes adjusted locations to Apple Photos, then promotes overrides into library GPS.
    func syncAdjustedLocationsToApplePhotos(
        _ updates: [(photoId: String, latitude: Double, longitude: Double)]
    ) async -> String? {
        let error = await PhotosAssetMetadataWriter.updateLocations(
            updates.map {
                (
                    photoId: $0.photoId,
                    location: CLLocation(latitude: $0.latitude, longitude: $0.longitude)
                )
            }
        )
        guard error == nil else { return error }
        database.promoteLocationsAfterPhotosSync(updates: updates)
        return nil
    }

    var selectedAllOnFrame: Bool {
        let selected = selectedRepresentativePhotos
        return !selected.isEmpty && selected.allSatisfy(\.showOnFrame)
    }

    var selectedAllFavorite: Bool {
        let selected = selectedRepresentativePhotos
        return !selected.isEmpty && selected.allSatisfy(\.isFavorite)
    }

    var selectedAllHidden: Bool {
        let selected = selectedRepresentativePhotos
        return !selected.isEmpty && selected.allSatisfy(\.isHiddenInEvent)
    }

    func toggleSelectedPhotosOnFrame() {
        setSelectedPhotosOnFrame(!selectedAllOnFrame)
    }

    func toggleSelectedPhotosFavorite() {
        setSelectedPhotosFavorite(!selectedAllFavorite)
    }

    @discardableResult
    func toggleSelectedPhotosHidden() -> Bool {
        setSelectedPhotosHidden(!selectedAllHidden)
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

    func setSelectedPhotosFavorite(_ favorite: Bool) {
        guard !selectedPhotoIds.isEmpty else { return }
        let photoIds = Array(selectedPhotoIds)
        photos = photos.map { photo in
            selectedPhotoIds.contains(photo.id) ? photo.withFavorite(favorite) : photo
        }
        refreshDisplayItemsPreservingGroups()
        cancelPhotoSelection()

        Task {
            await setFavoriteInPhotoLibrary(photoIds: photoIds, isFavorite: favorite)
            database.setPhotosFavorite(photoIds: photoIds, isFavorite: favorite)
        }
    }

    private func setFavoriteInPhotoLibrary(photoIds: [String], isFavorite: Bool) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            PHPhotoLibrary.shared().performChanges({
                let result = PHAsset.fetchAssets(withLocalIdentifiers: photoIds, options: nil)
                result.enumerateObjects { asset, _, _ in
                    let request = PHAssetChangeRequest(for: asset)
                    request.isFavorite = isFavorite
                }
            }, completionHandler: { _, error in
                if let error {
                    print("EventDetail favorite update failed: \(error.localizedDescription)")
                }
                continuation.resume()
            })
        }
    }

    @discardableResult
    func setSelectedPhotosHidden(_ hidden: Bool) -> Bool {
        guard !selectedPhotoIds.isEmpty else { return false }

        database.setPhotosHiddenInEvent(
            photoIds: Array(selectedPhotoIds),
            hidden: hidden
        )

        cancelPhotoSelection()
        loadPhotos()
        refreshEvent()

        if showHiddenPhotos {
            return false
        }

        return photos.isEmpty
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
        setSelectedPhotosHidden(true)
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
        userEditedName = updated.userEditedName
        // Keep the name field in sync with DB when the user hasn't taken ownership.
        if !userEditedName {
            let trimmed = updated.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                eventName = trimmed
            }
        }
        gameResult = database.fetchEventGameResult(eventId: event.eventId)
        if notifyList {
            notifyEventUpdated()
        }
    }

    @MainActor
    func findGameScore() async {
        await lookupGameCandidates(autoSaveSingleMatch: true)
    }

    /// AI Assist path — always ask the user to confirm, even for a single match.
    @MainActor
    func findGameScoreForConfirm() async {
        await lookupGameCandidates(autoSaveSingleMatch: false)
    }

    func dismissGameLookupCandidates() {
        showGameLookupCandidates = false
        if objectRecognitionStatus?.hasPrefix("AI Assist") == true {
            objectRecognitionStatus = nil
        }
    }

    @MainActor
    private func lookupGameCandidates(autoSaveSingleMatch: Bool) async {
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
            // Stadium match without sporting tag still warrants confirm when AI Assist ran.
            if result.candidates.isEmpty, result.stadiums.isEmpty {
                gameLookupStatus = "No matching games"
                return
            }
            gameLookupCandidates = result.candidates
            if autoSaveSingleMatch,
               result.candidates.count == 1,
               let only = result.candidates.first {
                saveGameCandidate(only)
                gameLookupStatus = "Saved \(only.coverScoreLine)"
            } else if result.candidates.isEmpty {
                gameLookupStatus = "Stadium matched · no games found"
            } else {
                showGameLookupCandidates = true
                gameLookupStatus = "\(result.candidates.count) matching games — confirm"
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
        guard let name = suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            return
        }
        guard !userEditedName else { return }

        eventName = name
        userEditedName = false
        guard saveEventName() else { return }
        // Reload so list/detail share the saved AI name + tags.
        refreshEvent(notifyList: true)
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
}
