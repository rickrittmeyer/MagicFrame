//
//  PhotoDatabase.swift
//  MagicFrame
//

import Foundation
import CoreLocation
import MapKit

final class PhotoDatabase: @unchecked Sendable {

    static let defaultLocationTypes = ["Stadium", "Beach", "Lake"]
    private static let customLocationTypesKey = "customLocationTypes"
    static let faceMetricsAlgorithmVersionKey = PhotoRepository.faceMetricsAlgorithmVersionKey
    static let cropAlgorithmVersionKey = PhotoRepository.cropAlgorithmVersionKey

    private var eventTuningCache: EventTuningSettings?

    private let container: AppContainer

    static var shared: PhotoDatabase { AppContainer.shared.photoDatabase }

    private var databaseManager: DatabaseManager { container.databaseManager }
    private var appMetadata: AppMetadataStore { container.metadata }
    private var photoRepository: PhotoRepository { container.photos }
    private var peopleRepository: PeopleRepository { container.people }
    private var eventRepository: EventRepository { container.events }
    private var locationRepository: LocationRepository { container.locations }
    private var geocodePendingQueue: LocationGeocodePendingQueue { container.geocodePendingQueue }
    private var eventLocationCoordinator: EventLocationCoordinator { container.eventLocations }
    private var eventClustering: EventClusteringService { container.eventClustering }

    private var dbQueue: DispatchQueue { databaseManager.queue }

    private var dbQueueKey: DispatchSpecificKey<UInt8> { databaseManager.queueKey }

    init(container: AppContainer) {
        self.container = container
    }

    func getEventTuningSettings() -> EventTuningSettings {
        dbQueue.sync {
            eventTuningUnsafe()
        }
    }

    func saveEventTuningSettings(_ settings: EventTuningSettings) {
        dbQueue.sync {
            if let data = try? JSONEncoder().encode(settings),
               let json = String(data: data, encoding: .utf8) {
                appMetadata.set(key: EventTuningSettings.storageKey, value: json)
            }
            eventTuningCache = settings
        }
    }

    func resetEventTuningSettings() {
        dbQueue.sync {
            appMetadata.delete(key: EventTuningSettings.storageKey)
            eventTuningCache = nil
        }
    }

    func eventTuningUnsafe() -> EventTuningSettings {
        if let eventTuningCache {
            return eventTuningCache
        }

        if let json = appMetadata.get(key: EventTuningSettings.storageKey),
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(EventTuningSettings.self, from: data) {
            eventTuningCache = decoded
            return decoded
        }

        return .defaults
    }

    func flushPendingGeocodeEnqueues() {
        geocodePendingQueue.flush()
    }

    func resetDatabaseForDevelopmentOnly() {
        databaseManager.resetDevelopmentDatabase(legacyHooks: LegacyDataMigrationHooks(
            migrateLegacyTripEventType: eventRepository.migrateLegacyTripEventTypeAttribute,
            migrateLegacyHomeLocations: locationRepository.migrateLegacyHomeLocations,
            migrateTripSubEventChildNames: eventRepository.migrateTripSubEventChildNamesIfNeeded,
            repairStaleGeocodeStatuses: locationRepository.repairStaleGeocodeStatuses,
            backfillEventAttributeTagsFromColumns: { [eventTags] in
                eventTags.backfillAttributeTagsFromColumnsIfNeeded()
                eventTags.migrateMisclassifiedMilestoneEventTypesIfNeeded()
            }
        ))
    }

    func upsertPhoto(
        id: String,
        creationDate: String,
        modificationDate: String,
        mediaType: Int,
        mediaSubtype: Int,
        width: Int,
        height: Int,
        isFavorite: Bool,
        isHidden: Bool,
        latitude: Double?,
        longitude: Double?,
        isScreenshot: Bool,
        aspectRatio: Double,
        orientation: String,
        qualityScore: Int,
        duration: Double?
    ) {
        photoRepository.upsertPhoto(
            id: id,
            creationDate: creationDate,
            modificationDate: modificationDate,
            mediaType: mediaType,
            mediaSubtype: mediaSubtype,
            width: width,
            height: height,
            isFavorite: isFavorite,
            isHidden: isHidden,
            latitude: latitude,
            longitude: longitude,
            isScreenshot: isScreenshot,
            aspectRatio: aspectRatio,
            orientation: orientation,
            qualityScore: qualityScore,
            duration: duration
        )
    }

    func markPhotosDeletedIfMissing(currentIds: Set<String>) {
        photoRepository.markPhotosDeletedIfMissing(currentIds: currentIds)
    }

    
    func christmasObjectKeysForVisionDebug() -> [String] {
        ObjectDetectionCategory.christmas.objectKeys
    }

    func getRecentPhotos(limit: Int = 100) -> [IndexedPhoto] {
        photoRepository.getRecentPhotos(limit: limit)
    }

    func fetchUnanalyzedPhotoIdsMatchingMonthDayRange(
        start: String,
        end: String
    ) -> PhotoVisionTagMonthDaySelection {
        photoRepository.fetchUnanalyzedPhotoIdsMatchingMonthDayRange(start: start, end: end)
    }

    func scanPhotosWithVisionTags(
        photoIds: [String],
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> PhotoVisionTagScanReport {
        let service = PhotoVisionTagScanService(
            database: databaseManager,
            photos: photoRepository,
            objectTags: container.objectTags
        )
        return await service.scan(photoIds: photoIds, progress: progress)
    }

    /// Full `VNClassifyImageRequest` for unanalyzed event photos (incl. trip children).
    /// Skips `visionAnalyzed = 1`, upserts `photo_object_tags`, then rebuilds `event_object_tags`.
    func scanEventPhotosWithVisionTags(
        eventId: Int,
        includeHiddenPhotos: Bool,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> PhotoVisionTagScanReport {
        let allPhotoIds = getPhotosForEvent(
            eventId: eventId,
            includeHidden: includeHiddenPhotos
        ).map(\.id)

        let unanalyzedPhotoIds = dbQueue.sync {
            allPhotoIds.filter { !photoRepository.isVisionAnalyzedUnsafe(photoId: $0) }
        }

        let report: PhotoVisionTagScanReport
        if unanalyzedPhotoIds.isEmpty {
            report = PhotoVisionTagScanReport(
                photoCount: allPhotoIds.count,
                photosScanned: 0,
                photosSkippedAnalyzed: allPhotoIds.count,
                photosFailed: 0,
                tagsWritten: 0,
                stoppedEarly: false
            )
        } else {
            report = await scanPhotosWithVisionTags(
                photoIds: unanalyzedPhotoIds,
                progress: progress
            )
        }

        // Refresh event-level aggregates for holiday/milestone scoring even when nothing new scanned.
        if !report.stoppedEarly {
            let completedAt = ISO8601DateFormatter().string(from: Date())
            dbQueue.sync {
                container.objectTags.rebuildEventObjectTagsUnsafe(
                    eventId: eventId,
                    updatedAt: completedAt
                )
                // Only mark complete when every photo was analyzed or skipped (no pending retries).
                if report.photosFailed == 0 {
                    container.eventTags.markObjectRecognitionCompletedUnsafe(
                        eventId: eventId,
                        completedAt: completedAt,
                        algorithmVersion: PhotoObjectVisionAnalyzer.algorithmVersion
                    )
                }
            }
        }

        return report
    }

    func searchPhotos(matching query: MediaSearchQuery) -> MediaPhotoSearchReport {
        MediaPhotoSearchService(database: databaseManager).search(query)
    }

    func mediaSearchSuggestionValues(
        field: MediaSearchField,
        query: String,
        limit: Int = 30
    ) -> [String] {
        MediaPhotoSearchService(database: databaseManager)
            .suggestionValues(field: field, query: query, limit: limit)
    }

    func fetchAllMediaSavedSearches(enabledOnly: Bool = false) -> [MediaSavedSearch] {
        container.mediaSavedSearches.fetchAll(enabledOnly: enabledOnly)
    }

    func fetchMediaSavedSearch(id: Int) -> MediaSavedSearch? {
        container.mediaSavedSearches.fetch(id: id)
    }

    @discardableResult
    func saveMediaSavedSearch(_ search: MediaSavedSearch) -> Int {
        container.mediaSavedSearches.save(search)
    }

    func deleteMediaSavedSearch(id: Int) {
        container.mediaSavedSearches.delete(id: id)
    }

    /// Upserts a Media Saved Search from a Picture Search definition and links legacy id.
    @discardableResult
    func upsertMediaSavedSearch(from definition: PictureSearchDefinition) -> MediaSavedSearch {
        var saved = MediaSearchQueryBuilder.mediaSavedSearch(from: definition)
        if let existing = container.mediaSavedSearches.fetch(named: definition.name) {
            saved.mediaSavedSearchId = existing.mediaSavedSearchId
            saved.legacyPictureSearchId = definition.pictureSearchId ?? existing.legacyPictureSearchId
            // Keep user-edited query JSON; only refresh metadata / legacy link.
            saved.query = existing.query
        } else {
            saved.legacyPictureSearchId = definition.pictureSearchId
        }
        let id = container.mediaSavedSearches.save(saved)
        return container.mediaSavedSearches.fetch(id: id) ?? saved
    }

    /// One-time-ish: create Media Saved Searches for any Picture Search rows that lack a counterpart.
    func migratePictureSearchesToMediaSavedSearchesIfNeeded() {
        let existingNames = Set(
            container.mediaSavedSearches.fetchAll(enabledOnly: false).map { $0.name.lowercased() }
        )
        for definition in container.pictureSearches.fetchAllPictureSearches() {
            let key = definition.name.lowercased()
            guard !existingNames.contains(key) else { continue }
            _ = upsertMediaSavedSearch(from: definition)
        }
    }

    func runMediaSavedSearch(_ search: MediaSavedSearch) -> PictureSearchRunReport {
        let report = SavedMediaSearchRunner(database: databaseManager).run(search)
        if search.performFaceDetect {
            maybeEnqueueFaceDetectAfterMediaSavedSearch(search: search, report: report)
        }
        return report
    }

    private func maybeEnqueueFaceDetectAfterMediaSavedSearch(
        search: MediaSavedSearch,
        report: PictureSearchRunReport
    ) {
        guard search.performFaceDetect, !report.photoMatches.isEmpty else { return }
        // Reuse picture-search face enqueue when a linked definition exists.
        if let legacyId = search.legacyPictureSearchId,
           let definition = container.pictureSearches.fetchPictureSearch(pictureSearchId: legacyId) {
            maybeEnqueueFaceDetectAfterPictureSearch(definition: definition, report: report)
        }
    }

    /// Vision OCR for event photos (incl. trip children). Skips current `textRecognitionVersion`,
    /// writes `photo_ocr_text`, marks `photos.textRecognitionVersion`.
    func scanEventPhotosForText(
        eventId: Int,
        includeHiddenPhotos: Bool,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> PhotoTextRecognitionScanReport {
        let allPhotoIds = getPhotosForEvent(
            eventId: eventId,
            includeHidden: includeHiddenPhotos
        ).map(\.id)

        let algorithmVersion = PhotoTextRecognitionAnalyzer.algorithmVersion
        let unanalyzedPhotoIds = dbQueue.sync {
            allPhotoIds.filter {
                photoRepository.textRecognitionVersionUnsafe(photoId: $0) < algorithmVersion
            }
        }

        if unanalyzedPhotoIds.isEmpty {
            return PhotoTextRecognitionScanReport(
                photoCount: allPhotoIds.count,
                photosScanned: 0,
                photosSkippedAnalyzed: allPhotoIds.count,
                photosFailed: 0,
                observationsWritten: 0,
                photosWithText: 0,
                stoppedEarly: false
            )
        }

        let service = PhotoTextRecognitionScanService(
            database: databaseManager,
            photos: photoRepository,
            ocrText: PhotoOCRTextRepository(database: databaseManager)
        )
        return await service.scan(photoIds: unanalyzedPhotoIds, progress: progress)
    }

    func searchPhotosByVisionTag(_ query: String, limit: Int = 500) -> [VisionTagPhotoMatch] {
        dbQueue.sync {
            container.objectTags.searchPhotosByVisionTagUnsafe(query: query, limit: limit)
        }
    }

    func searchPhotosByExactVisionTag(_ objectKey: String, limit: Int = 500) -> [VisionTagPhotoMatch] {
        dbQueue.sync {
            container.objectTags.searchPhotosByExactVisionTagUnsafe(objectKey: objectKey, limit: limit)
        }
    }

    func fetchDistinctVisionTagNames() -> [VisionTagName] {
        dbQueue.sync {
            container.objectTags.fetchDistinctVisionTagNamesUnsafe()
        }
    }

    func savePictureSearch(_ definition: PictureSearchDefinition) -> Int {
        container.pictureSearches.savePictureSearch(definition)
    }

    func fetchPictureSearch(pictureSearchId: Int) -> PictureSearchDefinition? {
        container.pictureSearches.fetchPictureSearch(pictureSearchId: pictureSearchId)
    }

    func fetchAllPictureSearches() -> [PictureSearchDefinition] {
        container.pictureSearches.fetchAllPictureSearches()
    }

    func fetchFloatingHolidays() -> [FloatingHolidayDefinition] {
        container.holidays.fetchFloatingHolidays()
    }

    func upsertFloatingHoliday(_ holiday: FloatingHolidayDefinition) -> Int {
        container.holidays.upsertFloatingHoliday(holiday)
    }

    func fetchAllEnabledHolidays() -> [HolidayDefinition] {
        container.holidays.fetchAllEnabledHolidays()
    }

    func upsertHoliday(_ holiday: HolidayDefinition) -> Int {
        container.holidays.upsertHoliday(holiday)
    }

    func runPictureSearch(_ definition: PictureSearchDefinition) -> PictureSearchRunReport {
        // Persist/refresh legacy picture search row for score-card + run linkage, then query via Media Search.
        let savedDefinitionId = container.pictureSearches.savePictureSearch(definition)
        var definition = definition
        definition.pictureSearchId = savedDefinitionId
        let mediaSearch = upsertMediaSavedSearch(from: definition)
        let report = SavedMediaSearchRunner(database: databaseManager).run(mediaSearch)
        maybeEnqueueFaceDetectAfterPictureSearch(definition: definition, report: report)
        return report
    }

    func runPictureSearch(pictureSearchId: Int) -> PictureSearchRunReport? {
        guard let definition = container.pictureSearches.fetchPictureSearch(pictureSearchId: pictureSearchId) else {
            return nil
        }
        return runPictureSearch(definition)
    }

    func fetchLatestPictureSearchRun(pictureSearchId: Int) -> PictureSearchRunReport? {
        container.pictureSearches.fetchLatestRunMatches(pictureSearchId: pictureSearchId)
    }

    func ensureWeddingPictureSearch() -> PictureSearchDefinition {
        let definition = container.pictureSearches.ensureWeddingPictureSearch()
        _ = upsertMediaSavedSearch(from: definition)
        return definition
    }

    func runWeddingPictureSearch() -> (definition: PictureSearchDefinition, report: PictureSearchRunReport) {
        let definition = ensureWeddingPictureSearch()
        let report = runPictureSearch(definition)
        return (definition, report)
    }

    func ensureChristmasPictureSearch() -> PictureSearchDefinition {
        let definition = container.pictureSearches.ensureChristmasPictureSearch()
        _ = upsertMediaSavedSearch(from: definition)
        return definition
    }

    func runChristmasPictureSearch() -> (definition: PictureSearchDefinition, report: PictureSearchRunReport) {
        let definition = ensureChristmasPictureSearch()
        let report = runPictureSearch(definition)
        return (definition, report)
    }

    func ensureHolidayPictureSearch(tagValue: String) -> PictureSearchDefinition? {
        guard let definition = container.pictureSearches.ensureHolidayPictureSearch(tagValue: tagValue) else {
            return nil
        }
        _ = upsertMediaSavedSearch(from: definition)
        return definition
    }

    func runHolidayPictureSearch(
        tagValue: String
    ) -> (definition: PictureSearchDefinition, report: PictureSearchRunReport)? {
        guard let definition = ensureHolidayPictureSearch(tagValue: tagValue) else { return nil }
        let report = runPictureSearch(definition)
        return (definition, report)
    }

    func ensureMilestonePictureSearch(topicId: String) -> PictureSearchDefinition? {
        guard let definition = container.pictureSearches.ensureMilestonePictureSearch(topicId: topicId) else {
            return nil
        }
        _ = upsertMediaSavedSearch(from: definition)
        return definition
    }

    func runMilestonePictureSearch(
        topicId: String
    ) -> (definition: PictureSearchDefinition, report: PictureSearchRunReport)? {
        guard let definition = ensureMilestonePictureSearch(topicId: topicId) else { return nil }
        let report = runPictureSearch(definition)
        return (definition, report)
    }

    func ensureOutingPictureSearch(topicId: String) -> PictureSearchDefinition? {
        guard let definition = container.pictureSearches.ensureOutingPictureSearch(topicId: topicId) else {
            return nil
        }
        _ = upsertMediaSavedSearch(from: definition)
        return definition
    }

    func runOutingPictureSearch(
        topicId: String
    ) -> (definition: PictureSearchDefinition, report: PictureSearchRunReport)? {
        guard let definition = ensureOutingPictureSearch(topicId: topicId) else { return nil }
        let report = runPictureSearch(definition)
        return (definition, report)
    }

    func ensurePersonBirthdayPictureSearch(
        person: PeopleRepository.PersonBirthdayRecord
    ) -> PictureSearchDefinition? {
        guard let definition = container.pictureSearches.ensurePersonBirthdayPictureSearch(person: person) else {
            return nil
        }
        _ = upsertMediaSavedSearch(from: definition)
        return definition
    }

    func runPersonBirthdayPictureSearch(
        person: PeopleRepository.PersonBirthdayRecord
    ) -> (definition: PictureSearchDefinition, report: PictureSearchRunReport)? {
        guard let definition = ensurePersonBirthdayPictureSearch(person: person) else { return nil }
        let report = runPictureSearch(definition)
        return (definition, report)
    }

    func fetchPersonBirthdayRecord(personId: Int) -> PeopleRepository.PersonBirthdayRecord? {
        peopleRepository.fetchPersonBirthdayRecord(personId: personId)
    }

    /// Saves birth date and ensures `{Name}'s Birthday` Picture Search + scorecard exist.
    @discardableResult
    func setPersonBirthDate(personId: Int, birthDateISO: String) -> PictureSearchDefinition? {
        let trimmed = birthDateISO.trimmingCharacters(in: .whitespacesAndNewlines)
        guard personId > 0, !trimmed.isEmpty else { return nil }
        peopleRepository.setBirthDate(personId: personId, birthDateISO: trimmed)
        return ensurePersonBirthdaySearchAndScoreCard(personId: personId)
    }

    /// Creates/updates Picture Search + Milestone scorecard for `{Name}'s Birthday`.
    @discardableResult
    func ensurePersonBirthdaySearchAndScoreCard(personId: Int) -> PictureSearchDefinition? {
        guard let person = peopleRepository.fetchPersonBirthdayRecord(personId: personId),
              let definition = ensurePersonBirthdayPictureSearch(person: person) else {
            return nil
        }
        let tagValue = definition.targetEventType.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tagValue.isEmpty {
            addCustomEventAttributeOption(tagValue, for: .milestoneType)
        }
        let names = Dictionary(
            uniqueKeysWithValues: fetchAllPeople().map { ($0.personId, $0.name) }
        )
        _ = ensureEventScoreCardSettings(for: definition, personNamesById: names)
        // Guarantee lookup by Milestone + tag value (browser / AI Assist).
        _ = ensureEventScoreCardSettings(
            tagCategory: definition.targetTagCategory,
            tagValue: tagValue,
            personNamesById: names
        )
        return definition
    }

    /// Sets profile avatar from a face of this person on `photoId`. Returns false if no face found.
    @discardableResult
    func setPersonProfilePicture(personId: Int, photoId: String) -> Bool {
        guard let faceId = peopleRepository.bestFaceInstanceIdForPersonOnPhoto(
            personId: personId,
            photoId: photoId
        ) else {
            return false
        }
        peopleRepository.setProfileFaceInstanceId(personId: personId, faceInstanceId: faceId)
        return true
    }

    func updatePersonProfile(
        personId: Int,
        displayName: String,
        firstName: String?,
        lastName: String?,
        maidenName: String?
    ) {
        peopleRepository.updatePersonNames(
            personId: personId,
            displayName: displayName,
            firstName: firstName,
            lastName: lastName,
            maidenName: maidenName
        )
        // If they already have a birth date, keep birthday search/scorecard name in sync.
        _ = ensurePersonBirthdaySearchAndScoreCard(personId: personId)
    }

    func fetchPeopleLandingItems() -> [PeopleRepository.PeopleLandingItem] {
        peopleRepository.fetchPeopleLandingItems()
    }

    func fetchPersonDetail(personId: Int) -> PeopleRepository.PeopleLandingItem? {
        peopleRepository.fetchPersonDetail(personId: personId)
    }

    func fetchRelationships(involvingPersonId personId: Int) -> [PeopleRelationship] {
        container.peopleRelationships.fetchRelationships(involvingPersonId: personId)
    }

    @discardableResult
    func upsertParentChildRelationship(
        parentPersonId: Int,
        childPersonId: Int,
        parentRole: PeopleRelationshipRole
    ) -> PeopleRelationship? {
        container.peopleRelationships.upsertParentChild(
            parentPersonId: parentPersonId,
            childPersonId: childPersonId,
            parentRole: parentRole
        )
    }

    @discardableResult
    func upsertSiblingRelationship(
        personIdA: Int,
        personIdB: Int
    ) -> PeopleRelationship? {
        container.peopleRelationships.upsertSibling(personIdA: personIdA, personIdB: personIdB)
    }

    @discardableResult
    func upsertRomanticRelationship(
        personIdA: Int,
        personIdB: Int,
        relationshipType: PeopleRelationshipType,
        roleA: PeopleRelationshipRole,
        roleB: PeopleRelationshipRole
    ) -> PeopleRelationship? {
        container.peopleRelationships.upsertRomanticPair(
            personIdA: personIdA,
            personIdB: personIdB,
            relationshipType: relationshipType,
            roleA: roleA,
            roleB: roleB
        )
    }

    func deletePeopleRelationship(relationshipId: Int) {
        container.peopleRelationships.deleteRelationship(relationshipId: relationshipId)
    }

    func fetchUnanalyzedPhotoIdsMatchingDateSearch(
        dateSearch: DateSearchDefinition,
        floatingHoliday: FloatingHolidayDefinition?,
        catalogHoliday: HolidayDefinition? = nil
    ) -> PhotoVisionTagMonthDaySelection {
        photoRepository.fetchUnanalyzedPhotoIdsMatchingDateSearch(
            dateSearch: dateSearch,
            floatingHoliday: floatingHoliday,
            catalogHoliday: catalogHoliday
        )
    }

    func prepareHolidayVisionTagsIfNeeded(
        definition: PictureSearchDefinition,
        /// Prefer catalog holiday date window (anchor ± weekends) over a legacy wide range
        /// saved on an older Picture Search (e.g. Christmas Dec 1–31).
        visionDateSearch: DateSearchDefinition? = nil,
        catalogHoliday: HolidayDefinition? = nil,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> PhotoVisionTagScanReport? {
        guard definition.hasUsableVisionTags else { return nil }

        let resolvedCatalog = catalogHoliday ?? {
            if let holidayId = (visionDateSearch ?? definition.dateSearch).holidayId {
                return container.holidays.fetchHoliday(holidayId: holidayId)
            }
            return nil
        }()

        let dateSearch = visionDateSearch ?? definition.dateSearch

        let floating: FloatingHolidayDefinition?
        if resolvedCatalog == nil, let floatingId = dateSearch.floatingHolidayId {
            floating = container.pictureSearches.fetchFloatingHolidays()
                .first { $0.floatingHolidayId == floatingId }
        } else {
            floating = nil
        }

        let selection = fetchUnanalyzedPhotoIdsMatchingDateSearch(
            dateSearch: dateSearch,
            floatingHoliday: floating,
            catalogHoliday: resolvedCatalog
        )
        print(
            "Holiday vision selection: \(selection.summaryLine) · "
                + "\(dateSearch.dateSearchType.rawValue)"
        )
        guard !selection.photoIds.isEmpty else {
            return PhotoVisionTagScanReport(
                photoCount: 0,
                photosScanned: 0,
                photosSkippedAnalyzed: selection.alreadyAnalyzed,
                photosFailed: 0,
                tagsWritten: 0,
                stoppedEarly: false
            )
        }
        return await scanPhotosWithVisionTags(photoIds: selection.photoIds, progress: progress)
    }

    /// Photos path: Vision prep (if needed) → always Picture Search. No event scoring.
    func runHolidayPhotosPipeline(
        tagValue: String,
        status: (@Sendable (String) -> Void)? = nil
    ) async -> HolidayPhotosPipelineResult? {
        guard let definition = ensureHolidayPictureSearch(tagValue: tagValue) else {
            return nil
        }

        let catalogHoliday = container.holidays.fetchHoliday(named: tagValue)
        let visionDateSearch = catalogHoliday.map {
            HolidayPictureSearchDefaults.dateSearch(for: $0)
        }

        var visionReport: PhotoVisionTagScanReport?
        if definition.hasUsableVisionTags {
            status?("Tagging \(tagValue) photos…")
            visionReport = await prepareHolidayVisionTagsIfNeeded(
                definition: definition,
                visionDateSearch: visionDateSearch,
                catalogHoliday: catalogHoliday
            ) { current, total in
                status?("Tagging \(tagValue) photos… \(current.formatted())/\(total.formatted())")
            }
            if let visionReport {
                print("\(tagValue) vision prep: \(visionReport.summaryLine)")
            }
        }

        status?("Searching \(tagValue) pictures…")
        guard let result = runHolidayPictureSearch(tagValue: tagValue) else {
            return nil
        }
        return HolidayPhotosPipelineResult(
            definition: result.definition,
            report: result.report,
            visionReport: visionReport
        )
    }

    /// Events path: reuse latest Picture Search when present, then score candidates.
    func runHolidayEventsPipeline(
        tagValue: String,
        status: (@Sendable (String) -> Void)? = nil
    ) async -> HolidayEventsPipelineResult? {
        guard let definition = ensureHolidayPictureSearch(tagValue: tagValue) else {
            return nil
        }

        let catalogHoliday = container.holidays.fetchHoliday(named: tagValue)
        let visionDateSearch = catalogHoliday.map {
            HolidayPictureSearchDefaults.dateSearch(for: $0)
        }

        if definition.hasUsableVisionTags {
            status?("Tagging \(tagValue) photos…")
            _ = await prepareHolidayVisionTagsIfNeeded(
                definition: definition,
                visionDateSearch: visionDateSearch,
                catalogHoliday: catalogHoliday
            ) { current, total in
                status?("Tagging \(tagValue) photos… \(current.formatted())/\(total.formatted())")
            }
        }

        status?("Finding \(tagValue) pictures…")
        let report: PictureSearchRunReport
        let resolvedDefinition: PictureSearchDefinition
        if let pictureSearchId = definition.pictureSearchId,
           let latest = fetchLatestPictureSearchRun(pictureSearchId: pictureSearchId),
           !latest.photoMatches.isEmpty {
            report = latest
            resolvedDefinition = definition
        } else if let result = runHolidayPictureSearch(tagValue: tagValue) {
            report = result.report
            resolvedDefinition = result.definition
        } else {
            return nil
        }

        let candidateCount = report.candidateEventIds.count
        guard candidateCount > 0 else {
            return HolidayEventsPipelineResult(
                definition: resolvedDefinition,
                report: report,
                checkReport: nil,
                summaryLine: "No candidate events from \(tagValue) pictures."
            )
        }

        status?(
            "Scoring \(candidateCount) possible \(tagValue) event"
                + (candidateCount == 1 ? "…" : "s…")
        )
        let scoreCard = ensureEventScoreCardSettings(for: resolvedDefinition)
        let checkReport = checkPictureSearchEventTypes(
            runReport: report,
            definition: resolvedDefinition,
            scoreCard: scoreCard,
            progress: nil
        )
        return HolidayEventsPipelineResult(
            definition: resolvedDefinition,
            report: report,
            checkReport: checkReport,
            summaryLine: checkReport.summaryLine
        )
    }

    /// Photos path for a milestone topic: Vision prep (if date-scoped) → Picture Search.
    func runMilestonePhotosPipeline(
        topicId: String,
        status: (@Sendable (String) -> Void)? = nil
    ) async -> HolidayPhotosPipelineResult? {
        guard let topic = MilestoneTopicCatalog.topic(id: topicId),
              let definition = ensureMilestonePictureSearch(topicId: topicId) else {
            return nil
        }

        var visionReport: PhotoVisionTagScanReport?
        if definition.hasUsableVisionTags {
            status?("Tagging \(topic.title) photos…")
            visionReport = await prepareHolidayVisionTagsIfNeeded(definition: definition) {
                current,
                total in
                status?(
                    "Tagging \(topic.title) photos… \(current.formatted())/\(total.formatted())"
                )
            }
            if let visionReport {
                print("\(topic.title) vision prep: \(visionReport.summaryLine)")
            }
        }

        status?("Searching \(topic.title) pictures…")
        guard let result = runMilestonePictureSearch(topicId: topicId) else {
            return nil
        }
        return HolidayPhotosPipelineResult(
            definition: result.definition,
            report: result.report,
            visionReport: visionReport
        )
    }

    /// Events path: reuse latest Picture Search when present, then score candidates.
    func runMilestoneEventsPipeline(
        topicId: String,
        status: (@Sendable (String) -> Void)? = nil
    ) async -> HolidayEventsPipelineResult? {
        guard let topic = MilestoneTopicCatalog.topic(id: topicId),
              let definition = ensureMilestonePictureSearch(topicId: topicId) else {
            return nil
        }

        if definition.hasUsableVisionTags {
            status?("Tagging \(topic.title) photos…")
            _ = await prepareHolidayVisionTagsIfNeeded(definition: definition) {
                current,
                total in
                status?(
                    "Tagging \(topic.title) photos… \(current.formatted())/\(total.formatted())"
                )
            }
        }

        status?("Finding \(topic.title) pictures…")
        let report: PictureSearchRunReport
        let resolvedDefinition: PictureSearchDefinition
        if let pictureSearchId = definition.pictureSearchId,
           let latest = fetchLatestPictureSearchRun(pictureSearchId: pictureSearchId),
           !latest.photoMatches.isEmpty {
            report = latest
            resolvedDefinition = definition
        } else if let result = runMilestonePictureSearch(topicId: topicId) {
            report = result.report
            resolvedDefinition = result.definition
        } else {
            return nil
        }

        let candidateCount = report.candidateEventIds.count
        guard candidateCount > 0 else {
            return HolidayEventsPipelineResult(
                definition: resolvedDefinition,
                report: report,
                checkReport: nil,
                summaryLine: "No candidate events from \(topic.title) pictures."
            )
        }

        status?(
            "Scoring \(candidateCount) possible \(topic.title) event"
                + (candidateCount == 1 ? "…" : "s…")
        )
        let scoreCard = ensureEventScoreCardSettings(for: resolvedDefinition)
        let checkReport = checkPictureSearchEventTypes(
            runReport: report,
            definition: resolvedDefinition,
            scoreCard: scoreCard,
            progress: nil
        )
        return HolidayEventsPipelineResult(
            definition: resolvedDefinition,
            report: report,
            checkReport: checkReport,
            summaryLine: checkReport.summaryLine
        )
    }

    /// Photos path for an outing topic: Vision prep (if needed) → Picture Search.
    func runOutingPhotosPipeline(
        topicId: String,
        status: (@Sendable (String) -> Void)? = nil
    ) async -> HolidayPhotosPipelineResult? {
        guard let topic = OutingTopicCatalog.topic(id: topicId),
              let definition = ensureOutingPictureSearch(topicId: topicId) else {
            return nil
        }

        var visionReport: PhotoVisionTagScanReport?
        if definition.hasUsableVisionTags {
            status?("Tagging \(topic.title) photos…")
            visionReport = await prepareHolidayVisionTagsIfNeeded(definition: definition) {
                current,
                total in
                status?(
                    "Tagging \(topic.title) photos… \(current.formatted())/\(total.formatted())"
                )
            }
            if let visionReport {
                print("\(topic.title) vision prep: \(visionReport.summaryLine)")
            }
        }

        status?("Searching \(topic.title) pictures…")
        guard let result = runOutingPictureSearch(topicId: topicId) else {
            return nil
        }
        return HolidayPhotosPipelineResult(
            definition: result.definition,
            report: result.report,
            visionReport: visionReport
        )
    }

    /// Events path for outings: reuse latest Picture Search when present, then score candidates.
    func runOutingEventsPipeline(
        topicId: String,
        status: (@Sendable (String) -> Void)? = nil
    ) async -> HolidayEventsPipelineResult? {
        guard let topic = OutingTopicCatalog.topic(id: topicId),
              let definition = ensureOutingPictureSearch(topicId: topicId) else {
            return nil
        }

        if definition.hasUsableVisionTags {
            status?("Tagging \(topic.title) photos…")
            _ = await prepareHolidayVisionTagsIfNeeded(definition: definition) {
                current,
                total in
                status?(
                    "Tagging \(topic.title) photos… \(current.formatted())/\(total.formatted())"
                )
            }
        }

        status?("Finding \(topic.title) pictures…")
        let report: PictureSearchRunReport
        let resolvedDefinition: PictureSearchDefinition
        if let pictureSearchId = definition.pictureSearchId,
           let latest = fetchLatestPictureSearchRun(pictureSearchId: pictureSearchId),
           !latest.photoMatches.isEmpty {
            report = latest
            resolvedDefinition = definition
        } else if let result = runOutingPictureSearch(topicId: topicId) {
            report = result.report
            resolvedDefinition = result.definition
        } else {
            return nil
        }

        let candidateCount = report.candidateEventIds.count
        guard candidateCount > 0 else {
            return HolidayEventsPipelineResult(
                definition: resolvedDefinition,
                report: report,
                checkReport: nil,
                summaryLine: "No candidate events from \(topic.title) pictures."
            )
        }

        status?(
            "Scoring \(candidateCount) possible \(topic.title) event"
                + (candidateCount == 1 ? "…" : "s…")
        )
        let scoreCard = ensureEventScoreCardSettings(for: resolvedDefinition)
        let checkReport = checkPictureSearchEventTypes(
            runReport: report,
            definition: resolvedDefinition,
            scoreCard: scoreCard,
            progress: nil
        )
        return HolidayEventsPipelineResult(
            definition: resolvedDefinition,
            report: report,
            checkReport: checkReport,
            summaryLine: checkReport.summaryLine
        )
    }

    /// Photos path for one person's birthday: Vision prep around birth month/day → Picture Search.
    func runPersonBirthdayPhotosPipeline(
        personId: Int,
        status: (@Sendable (String) -> Void)? = nil
    ) async -> HolidayPhotosPipelineResult? {
        guard let person = fetchPersonBirthdayRecord(personId: personId),
              let definition = ensurePersonBirthdayPictureSearch(person: person) else {
            return nil
        }
        let title = MilestonePictureSearchDefaults.personBirthdayTagValue(displayName: person.name)

        var visionReport: PhotoVisionTagScanReport?
        if definition.hasUsableVisionTags {
            status?("Tagging \(title) photos…")
            visionReport = await prepareHolidayVisionTagsIfNeeded(definition: definition) {
                current,
                total in
                status?("Tagging \(title) photos… \(current.formatted())/\(total.formatted())")
            }
            if let visionReport {
                print("\(title) vision prep: \(visionReport.summaryLine)")
            }
        }

        status?("Searching \(title) pictures…")
        guard let result = runPersonBirthdayPictureSearch(person: person) else {
            return nil
        }
        return HolidayPhotosPipelineResult(
            definition: result.definition,
            report: result.report,
            visionReport: visionReport
        )
    }

    /// Events path for one person's birthday: ensure scorecard → Picture Search → score candidates.
    func runPersonBirthdayEventsPipeline(
        personId: Int,
        status: (@Sendable (String) -> Void)? = nil
    ) async -> HolidayEventsPipelineResult? {
        guard let person = fetchPersonBirthdayRecord(personId: personId),
              let definition = ensurePersonBirthdaySearchAndScoreCard(personId: personId) else {
            return nil
        }
        let title = MilestonePictureSearchDefaults.personBirthdayTagValue(displayName: person.name)

        if definition.hasUsableVisionTags {
            status?("Tagging \(title) photos…")
            _ = await prepareHolidayVisionTagsIfNeeded(definition: definition) {
                current,
                total in
                status?("Tagging \(title) photos… \(current.formatted())/\(total.formatted())")
            }
        }

        status?("Finding \(title) pictures…")
        let report: PictureSearchRunReport
        let resolvedDefinition: PictureSearchDefinition
        if let pictureSearchId = definition.pictureSearchId,
           let latest = fetchLatestPictureSearchRun(pictureSearchId: pictureSearchId),
           !latest.photoMatches.isEmpty {
            report = latest
            resolvedDefinition = definition
        } else if let result = runPersonBirthdayPictureSearch(person: person) {
            report = result.report
            resolvedDefinition = result.definition
        } else {
            return nil
        }

        let candidateCount = report.candidateEventIds.count
        guard candidateCount > 0 else {
            return HolidayEventsPipelineResult(
                definition: resolvedDefinition,
                report: report,
                checkReport: nil,
                summaryLine: "No candidate events from \(title) pictures."
            )
        }

        status?(
            "Scoring \(candidateCount) possible \(title) event"
                + (candidateCount == 1 ? "…" : "s…")
        )
        let scoreCard = ensureEventScoreCardSettings(for: resolvedDefinition)
        let checkReport = checkPictureSearchEventTypes(
            runReport: report,
            definition: resolvedDefinition,
            scoreCard: scoreCard,
            progress: nil
        )
        return HolidayEventsPipelineResult(
            definition: resolvedDefinition,
            report: report,
            checkReport: checkReport,
            summaryLine: checkReport.summaryLine
        )
    }

    func ensureEventScoreCardSettings(
        for definition: PictureSearchDefinition,
        personNamesById: [Int: String] = [:]
    ) -> PictureSearchEventScoreCardSettings {
        let names = personNamesById.isEmpty
            ? Dictionary(uniqueKeysWithValues: fetchAllPeople().map { ($0.personId, $0.name) })
            : personNamesById
        return container.pictureSearches.ensureEventScoreCardSettings(
            for: definition,
            personNamesById: names
        )
    }

    func ensureEventScoreCardSettings(
        tagCategory: String,
        tagValue: String,
        personNamesById: [Int: String] = [:]
    ) -> PictureSearchEventScoreCardSettings {
        let names = personNamesById.isEmpty
            ? Dictionary(uniqueKeysWithValues: fetchAllPeople().map { ($0.personId, $0.name) })
            : personNamesById
        return container.pictureSearches.ensureEventScoreCardSettings(
            tagCategory: tagCategory,
            tagValue: tagValue,
            personNamesById: names
        )
    }

    func fetchEventScoreCardSettings(
        tagCategory: String,
        tagValue: String
    ) -> PictureSearchEventScoreCardSettings? {
        container.pictureSearches.fetchEventScoreCardSettings(
            tagCategory: tagCategory,
            tagValue: tagValue
        )
    }

    func fetchAllEventScoreCardSettings() -> [PictureSearchEventScoreCardSettings] {
        container.pictureSearches.fetchAllEventScoreCardSettings()
    }

    @discardableResult
    func saveEventScoreCardSettings(
        _ settings: PictureSearchEventScoreCardSettings
    ) -> PictureSearchEventScoreCardSettings {
        container.pictureSearches.saveEventScoreCardSettings(settings)
    }

    func checkPictureSearchEventTypes(
        runReport: PictureSearchRunReport,
        definition: PictureSearchDefinition,
        scoreCard: PictureSearchEventScoreCardSettings,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) -> PictureSearchEventTypeCheckReport {
        let floatingHoliday: FloatingHolidayDefinition? = {
            guard let floatingId = scoreCard.dateSearch.floatingHolidayId else { return nil }
            return container.pictureSearches.fetchFloatingHolidays()
                .first { $0.floatingHolidayId == floatingId }
        }()
        let service = PictureSearchEventTypeCheckService(
            database: databaseManager,
            eventTags: container.eventTags
        )
        return service.checkEventTypes(
            runReport: runReport,
            definition: definition,
            scoreCard: scoreCard,
            floatingHoliday: floatingHoliday,
            progress: progress
        )
    }

    @discardableResult
    func scoreEventAgainstScoreCard(
        eventId: Int,
        scoreCard: PictureSearchEventScoreCardSettings
    ) -> PictureSearchEventTypeScore {
        let floatingHoliday: FloatingHolidayDefinition? = {
            guard let floatingId = scoreCard.dateSearch.floatingHolidayId else { return nil }
            return container.pictureSearches.fetchFloatingHolidays()
                .first { $0.floatingHolidayId == floatingId }
        }()
        let service = PictureSearchEventTypeCheckService(
            database: databaseManager,
            eventTags: container.eventTags
        )
        return service.scoreEvent(
            eventId: eventId,
            scoreCard: scoreCard,
            floatingHoliday: floatingHoliday
        )
    }

    @discardableResult
    func resolveAndApplyWeddingCouple(eventId: Int) -> WeddingCoupleResolution {
        WeddingCoupleResolutionService(
            database: databaseManager,
            eventTags: container.eventTags
        ).resolveAndApply(eventId: eventId)
    }

    func weddingCouplePhotoId(eventId: Int) -> String? {
        WeddingCoupleResolutionService(
            database: databaseManager,
            eventTags: container.eventTags
        ).weddingCouplePhotoId(eventId: eventId)
    }

    func upsertPerson(name: String) -> Int {
        peopleRepository.upsertPerson(name: name)
    }

    func linkPhotoToPerson(photoId: String, personId: Int, source: String) {
        peopleRepository.linkPhotoToPerson(photoId: photoId, personId: personId, source: source)
    }

    func getAllPersonNames() -> [String] {
        peopleRepository.getAllPersonNames()
    }

    // MARK: - Location repository forwards

    func countPendingGeocodeLocations() -> Int {
        locationRepository.countPendingGeocodeLocations()
    }

    func fetchPendingGeocodeLocations(limit: Int? = nil) -> [PendingLocation] {
        locationRepository.fetchPendingGeocodeLocations(limit: limit)
    }

    func fetchEventLocationsNeedingGeocode(limit: Int? = nil) -> [PendingLocation] {
        locationRepository.fetchEventLocationsNeedingGeocode(limit: limit)
    }

    func tryCopyNearbyGeocode(locationId: Int, latitude: Double, longitude: Double) -> Bool {
        locationRepository.tryCopyNearbyGeocode(locationId: locationId, latitude: latitude, longitude: longitude)
    }

    func startGeocodingAllPending() {
        locationRepository.startGeocodingAllPending()
    }

    func resumeGeocodingIfNeeded() {
        repairHomeLocations()
        restoreDeletedTripContainersOnQueue()
        if #available(iOS 26.0, *) {
            LocationGeocodeCoordinator.shared.resumeIfNeeded()
        }
    }

    func stopGeocoding() {
        if #available(iOS 26.0, *) {
            LocationGeocodeCoordinator.shared.stopAll()
        }
    }

    func repairHomeLocations() {
        dbQueue.sync {
            locationRepository.mergeNearbyLocationsIntoCurrentHome()
            eventLocationCoordinator.snapEventsNearDesignatedHomesUnsafe()
            locationRepository.backfillCurrentHomeAddressIfNeeded()
        }
        flushPendingGeocodeEnqueues()
    }

    func restoreDeletedTripContainersOnQueue() {
        dbQueue.sync {
            eventRepository.restoreDeletedTripContainers()
        }
    }

    func startGeocodingEventLocations(limit: Int? = nil) {
        locationRepository.startGeocodingEventLocations(limit: limit)
    }

    /// On event open: create/link a location if needed, then reverse-geocode when incomplete.
    /// Also assign-only snaps member photos to `photos.locationId` (no per-photo Apple geocode).
    /// Returns `true` when place/city/state were newly written (UI should refresh).
    func ensureEventLocationGeocoded(eventId: Int) async -> Bool {
        enum Prep {
            case alreadyUpToDate
            case refreshedFromExistingLocation
            case needsReverseGeocode(PendingLocation)
        }

        let prep: Prep = dbQueue.sync {
            let existing = eventRepository.getEvent(eventId: eventId)
            if existing?.locationId == nil {
                eventLocationCoordinator.updateEventLocationFromRepresentativePoint(
                    eventId: eventId
                )
            }

            guard let event = eventRepository.getEvent(eventId: eventId),
                  let locationId = event.locationId,
                  let location = locationRepository.getLocation(locationId: locationId),
                  let latitude = location.latitude ?? event.latitude,
                  let longitude = location.longitude ?? event.longitude else {
                return .alreadyUpToDate
            }

            if locationRepository.isLocationGeocodeComplete(locationId: locationId) {
                let needsEventFill =
                    (event.placeName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ?? true)
                    && (event.city?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                if needsEventFill {
                    eventRepository.updateEventsFromLocation(locationId: locationId)
                    return .refreshedFromExistingLocation
                }
                return .alreadyUpToDate
            }

            return .needsReverseGeocode(
                PendingLocation(
                    locationId: locationId,
                    latitude: latitude,
                    longitude: longitude
                )
            )
        }

        let didUpdate: Bool
        switch prep {
        case .alreadyUpToDate:
            didUpdate = false
        case .refreshedFromExistingLocation:
            didUpdate = true
        case .needsReverseGeocode(let target):
            if tryCopyNearbyGeocode(
                locationId: target.locationId,
                latitude: target.latitude,
                longitude: target.longitude
            ) {
                didUpdate = true
            } else if locationRepository.isLocationGeocodeComplete(locationId: target.locationId) {
                eventRepository.updateEventsFromLocation(locationId: target.locationId)
                didUpdate = true
            } else {
                didUpdate = await reverseGeocodeAndComplete(
                    eventId: eventId,
                    locationId: target.locationId,
                    latitude: target.latitude,
                    longitude: target.longitude
                )
            }
        }

        dbQueue.sync {
            assignPhotoLocationsForEventUnsafe(eventId: eventId)
        }
        return didUpdate
    }

    /// Preview header location line; may assign `photos.locationId` from GPS (local only).
    func photoPreviewLocationLine(photoId: String) -> String {
        dbQueue.sync {
            photoPreviewLocationLineUnsafe(photoId: photoId)
        }
    }

    func fetchPhotoInfoDetail(photoId: String) -> PhotoInfoDetail? {
        PhotoInfoRepository(database: databaseManager).fetchDetail(photoId: photoId)
    }

    /// Prefer the event's location within `photoEventLocationSnapMiles`, else findOrCreate.
    private func assignPhotoLocationsForEventUnsafe(eventId: Int) {
        let rows = photoRepository.photosWithGPSForEventUnsafe(eventId: eventId)
        for row in rows {
            let locationId: Int
            if let eventLocationId = eventLocationIdIfWithinPhotoSnap(
                eventId: eventId,
                latitude: row.latitude,
                longitude: row.longitude
            ) {
                locationId = eventLocationId
            } else if row.locationId != nil {
                continue
            } else {
                let created = locationRepository.findOrCreateLocation(
                    latitude: row.latitude,
                    longitude: row.longitude,
                    at: row.captureDate
                )
                guard created > 0 else { continue }
                locationId = created
            }
            if row.locationId != locationId {
                photoRepository.setPhotoLocationIdUnsafe(photoId: row.photoId, locationId: locationId)
            }
        }
    }

    private func ensurePhotoLocationAssignedUnsafe(photoId: String) -> Int? {
        guard let row = photoRepository.photoLocationAssignRowUnsafe(photoId: photoId) else {
            return nil
        }
        guard let latitude = row.latitude, let longitude = row.longitude else {
            return row.locationId
        }

        if let eventId = eventRepository.getEventIdForPhotoUnsafe(photoId: photoId),
           let eventLocationId = eventLocationIdIfWithinPhotoSnap(
               eventId: eventId,
               latitude: latitude,
               longitude: longitude
           ) {
            if row.locationId != eventLocationId {
                photoRepository.setPhotoLocationIdUnsafe(photoId: photoId, locationId: eventLocationId)
            }
            return eventLocationId
        }

        if let locationId = row.locationId {
            return locationId
        }

        let locationId = locationRepository.findOrCreateLocation(
            latitude: latitude,
            longitude: longitude,
            at: row.captureDate ?? Date()
        )
        guard locationId > 0 else { return nil }
        photoRepository.setPhotoLocationIdUnsafe(photoId: photoId, locationId: locationId)
        return locationId
    }

    private func eventLocationIdIfWithinPhotoSnap(
        eventId: Int,
        latitude: Double,
        longitude: Double
    ) -> Int? {
        guard let event = eventRepository.getEvent(eventId: eventId),
              let locationId = event.locationId else {
            return nil
        }
        let location = locationRepository.getLocation(locationId: locationId)
        guard let locLat = location?.latitude ?? event.latitude,
              let locLon = location?.longitude ?? event.longitude else {
            return nil
        }
        let distance = locationRepository.distanceInMiles(
            lat1: latitude,
            lon1: longitude,
            lat2: locLat,
            lon2: locLon
        )
        guard distance <= eventTuningUnsafe().photoEventLocationSnapMiles else {
            return nil
        }
        return locationId
    }

    private func photoPreviewLocationLineUnsafe(photoId: String) -> String {
        guard let row = photoRepository.photoLocationAssignRowUnsafe(photoId: photoId),
              let latitude = row.latitude,
              let longitude = row.longitude else {
            // Never fall back to the parent event location for GPS-less photos.
            return PhotoPreviewLocationFormatting.noGPSData
        }

        let assignedLocationId = ensurePhotoLocationAssignedUnsafe(photoId: photoId)
        if let locationId = assignedLocationId,
           let location = locationRepository.getLocation(locationId: locationId) {
            return PhotoPreviewLocationFormatting.line(
                nickname: location.nickname,
                placeName: location.placeName,
                city: location.city,
                state: location.state,
                latitude: location.latitude ?? latitude,
                longitude: location.longitude ?? longitude
            )
        }

        return PhotoPreviewLocationFormatting.line(
            nickname: nil,
            placeName: nil,
            city: nil,
            state: nil,
            latitude: latitude,
            longitude: longitude
        )
    }

    private func reverseGeocodeAndComplete(
        eventId: Int,
        locationId: Int,
        latitude: Double,
        longitude: Double
    ) async -> Bool {
        let clLocation = CLLocation(latitude: latitude, longitude: longitude)

        if #available(iOS 26.0, *) {
            guard let request = MKReverseGeocodingRequest(location: clLocation) else {
                markLocationGeocodeFailed(locationId: locationId)
                return false
            }
            do {
                let mapItems = try await request.mapItems
                guard let mapItem = mapItems.first else {
                    markLocationGeocodeFailed(locationId: locationId)
                    return false
                }
                let city = ReverseGeocodeParser.geocodedCity(from: mapItem)
                let state = ReverseGeocodeParser.administrativeArea(from: mapItem)
                let placeName = ReverseGeocodeParser.placeLabel(from: mapItem)
                completeLocationGeocode(
                    locationId: locationId,
                    city: city,
                    state: state,
                    placeName: placeName
                )
                print(
                    "Event \(eventId) geocoded location \(locationId):"
                        + " \(placeName ?? "nil"), \(city ?? "nil"), \(state ?? "nil")"
                )
                return true
            } catch {
                print(
                    "Event \(eventId) geocode failed for location \(locationId):"
                        + " \(error.localizedDescription)"
                )
                markLocationGeocodeFailed(locationId: locationId)
                return false
            }
        }

        // Pre-iOS 26 fallback.
        do {
            let placemarks = try await CLGeocoder().reverseGeocodeLocation(clLocation)
            guard let placemark = placemarks.first else {
                markLocationGeocodeFailed(locationId: locationId)
                return false
            }
            let city = placemark.locality
            let state = placemark.administrativeArea
            let placeName = placemark.name
                ?? placemark.areasOfInterest?.first
                ?? placemark.thoroughfare
            completeLocationGeocode(
                locationId: locationId,
                city: city,
                state: state,
                placeName: placeName
            )
            print(
                "Event \(eventId) geocoded location \(locationId):"
                    + " \(placeName ?? "nil"), \(city ?? "nil"), \(state ?? "nil")"
            )
            return true
        } catch {
            print(
                "Event \(eventId) geocode failed for location \(locationId):"
                    + " \(error.localizedDescription)"
            )
            markLocationGeocodeFailed(locationId: locationId)
            return false
        }
    }

    func completeLocationGeocode(
        locationId: Int,
        city: String?,
        state: String?,
        placeName: String?
    ) {
        dbQueue.sync {
            locationRepository.completeLocationGeocode(
                locationId: locationId,
                city: city,
                state: state,
                placeName: placeName
            )
        }
    }

    func markLocationGeocodeFailed(locationId: Int) {
        locationRepository.markLocationGeocodeFailed(locationId: locationId)
    }

    func resetLocationGeocodeToPending(locationId: Int) {
        locationRepository.resetLocationGeocodeToPending(locationId: locationId)
    }

    func debugLocationCounts() {
        locationRepository.debugLocationCounts()
    }

    func rebuildLocationsForExistingEventsOnce() {
        locationRepository.rebuildLocationsForExistingEventsOnce()
    }

    func getLocationTypeOptions() -> [String] {
        locationRepository.getLocationTypeOptions()
    }

    func addCustomLocationType(_ type: String) {
        locationRepository.addCustomLocationType(type)
    }

    func geocodeLocationsUsedByEvents(limit: Int = 25) {
        startGeocodingEventLocations(limit: limit)
    }

    func getLocationsRankedByEventCount() -> [ManagedLocation] {
        locationRepository.getLocationsRankedByEventCount()
    }

    func getLocation(locationId: Int) -> ManagedLocation? {
        locationRepository.getLocation(locationId: locationId)
    }

    func locationsNeedingGeocodeCount() -> Int {
        locationRepository.locationsNeedingGeocodeCount()
    }

    func updateLocationNickname(locationId: Int, nickname: String?) {
        locationRepository.updateLocationNickname(locationId: locationId, nickname: nickname)
    }

    func updateLocationType(locationId: Int, locationType: String?) {
        locationRepository.updateLocationType(locationId: locationId, locationType: locationType)
    }

    func setLocationFavorite(locationId: Int, isFavorite: Bool) {
        locationRepository.setLocationFavorite(locationId: locationId, isFavorite: isFavorite)
    }

    func getCurrentHomeLocation() -> ManagedLocation? {
        locationRepository.getCurrentHomeLocation()
    }

    func hasCurrentHome() -> Bool {
        locationRepository.hasCurrentHome()
    }

    func createDesignatedCurrentHome(
        latitude: Double,
        longitude: Double,
        nickname: String?,
        homeStartDate: Date?
    ) -> Int {
        let locationId = locationRepository.createDesignatedCurrentHome(
            latitude: latitude,
            longitude: longitude,
            nickname: nickname,
            homeStartDate: homeStartDate
        )
        guard locationId > 0 else { return locationId }
        geocodePendingQueue.requestFreshGeocode(
            locationId: locationId,
            latitude: latitude,
            longitude: longitude
        )
        flushPendingGeocodeEnqueues()
        return locationId
    }

    func updateLocationHomeDesignation(
        locationId: Int,
        role: LocationHomeRole,
        homeStartDate: Date?,
        homeEndDate: Date?
    ) {
        locationRepository.updateLocationHomeDesignation(
            locationId: locationId,
            role: role,
            homeStartDate: homeStartDate,
            homeEndDate: homeEndDate
        )
    }

    func deduplicateLocationsByAddress(maxDistanceMiles: Double? = nil) -> Int {
        locationRepository.deduplicateLocationsByAddress(maxDistanceMiles: maxDistanceMiles)
    }

    func deduplicateLocationsByAddressUnsafe(maxDistanceMiles: Double) -> Int {
        locationRepository.deduplicateLocationsByAddressUnsafe(maxDistanceMiles: maxDistanceMiles)
    }

    @discardableResult
    func mergeDuplicateLocations(
        proximityMiles: Double? = nil,
        samePlaceNameMiles: Double? = nil,
        frequentPlaceMiles: Double? = nil,
        frequentPlaceMinEvents: Int? = nil
    ) -> Int {
        locationRepository.mergeDuplicateLocations(
            proximityMiles: proximityMiles,
            samePlaceNameMiles: samePlaceNameMiles,
            frequentPlaceMiles: frequentPlaceMiles,
            frequentPlaceMinEvents: frequentPlaceMinEvents
        )
    }

    func mergeNearbyLocationsIntoCurrentHome() {
        locationRepository.mergeNearbyLocationsIntoCurrentHome()
    }

    func findOrCreateLocation(
        latitude: Double,
        longitude: Double,
        at date: Date = Date()
    ) -> Int {
        locationRepository.findOrCreateLocation(latitude: latitude, longitude: longitude, at: date)
    }

    func updateLocationGeocode(
        locationId: Int,
        city: String?,
        state: String?,
        placeName: String?,
        status: String = "complete"
    ) {
        locationRepository.updateLocationGeocode(
            locationId: locationId,
            city: city,
            state: state,
            placeName: placeName,
            status: status
        )
    }

    func distanceInMiles(
        lat1: Double,
        lon1: Double,
        lat2: Double,
        lon2: Double
    ) -> Double {
        locationRepository.distanceInMiles(lat1: lat1, lon1: lon1, lat2: lat2, lon2: lon2)
    }

    static func geocodedCity(from mapItem: MKMapItem) -> String? {
        ReverseGeocodeParser.geocodedCity(from: mapItem)
    }

    static func geocodedCityWithContext(from mapItem: MKMapItem) -> String? {
        ReverseGeocodeParser.geocodedCityWithContext(from: mapItem)
    }

    static func administrativeArea(from mapItem: MKMapItem) -> String? {
        ReverseGeocodeParser.administrativeArea(from: mapItem)
    }

    static func coordinate(from mapItem: MKMapItem) -> CLLocationCoordinate2D? {
        ReverseGeocodeParser.coordinate(from: mapItem)
    }

    static func placeLabel(from mapItem: MKMapItem) -> String? {
        ReverseGeocodeParser.placeLabel(from: mapItem)
    }

    static func geocodedFormattedAddress(from mapItem: MKMapItem) -> String {
        ReverseGeocodeParser.geocodedFormattedAddress(from: mapItem)
    }

    func runPostIndexMetadataEnrichment() {
        container.metadataEnrichment.runPostIndexPhase()
    }

    func importMissingPhotoExif(onProgress: @escaping @Sendable (String) -> Void) async {
        await container.photoExifImport.importMissingExif(onProgress: onProgress)
    }

    func runPostIndexMetadataEnrichmentIfNeeded() {
        guard container.albums.countAlbums() == 0,
              photoRepository.countActivePhotos() > 0 else {
            return
        }
        runPostIndexMetadataEnrichment()
    }

    func metadataEnrichmentCounts() -> MetadataEnrichmentCounts {
        DevDatabaseTools.metadataEnrichmentCounts(database: databaseManager)
    }

    func eventDateDiagnosticCounts() -> EventDateDiagnosticCounts {
        dbQueue.sync {
            eventRepository.eventDateDiagnosticCounts()
        }
    }

    @discardableResult
    func repairEventDateSummaries() -> EventDateRepairResult {
        dbQueue.sync {
            eventRepository.repairEventDateSummaries()
        }
    }

    // MARK: - Event clustering forwards

    func clusterEventsByTime() {
        eventClustering.clusterEventsByTime()
    }

    func syncEventsIncrementally() {
        eventClustering.syncEventsIncrementally()
    }

    @discardableResult
    func syncEventsAssignmentBatch() -> Bool {
        let hasMore = eventClustering.syncEventsAssignmentBatch()
        if !hasMore {
        }
        return hasMore
    }

    func countUnassignedPhotosForEvents() -> Int {
        eventClustering.countUnassignedPhotosForEvents()
    }

    func countUnassignedMetadataPhotosForEvents() -> Int {
        dbQueue.sync {
            eventRepository.countUnassignedMetadataPhotosForEvents()
        }
    }

    func metadataAssignmentCounts() -> MetadataAssignmentCounts {
        dbQueue.sync {
            MetadataAssignmentCounts(
                unassignedNoGPS: eventRepository.countUnassignedMetadataPhotosForEvents(),
                attachedViaMetadata: eventRepository.countMetadataAttachedPhotos(),
                attachedNeedingReview: eventRepository.countMetadataAttachedPhotosNeedingReview()
            )
        }
    }

    @discardableResult
    func syncMetadataAssignmentBatch() -> Bool {
        dbQueue.sync {
            container.photoEventAssignment.syncMetadataAssignmentBatch()
        }
    }

    /// Metadata attach, then time-only clustering for remaining no-GPS photos (used by Sync Events).
    func syncMetadataAssignmentUntilComplete() {
        eventClustering.syncSecondaryPhotoAssignmentPasses()
    }

    func rebuildAllEvents() {
        eventClustering.rebuildAllEvents()
    }

    @discardableResult
    func prepareEventRebuild() -> Int {
        eventClustering.prepareEventRebuild()
    }

    func finishEventRebuild() {
        eventClustering.finishEventRebuild()
    }

    func relinkEventLocationsFromPhotos() {
        eventClustering.relinkEventLocationsFromPhotos()
    }

    func finishEventSyncMaintenance() {
        eventClustering.finishEventSyncMaintenance()
    }

    func joinTimeOnlyEventsToSameDayLocatedEvents() {
        eventClustering.joinTimeOnlyEventsToSameDayLocatedEvents()
    }

    func clearAllEventDataPreservingLocations() {
        eventClustering.clearAllEventDataPreservingLocations()
    }
    func debugSchema() {
        DevDatabaseTools.debugSchema(database: databaseManager)
    }

    func countPhotosMissingLocation() -> Int {
        photoRepository.countPhotosMissingLocation()
    }

    func countActivePhotos() -> Int {
        photoRepository.countActivePhotos()
    }

    func getLikelyUploadBatches(
        gapSeconds: TimeInterval = 6 * 60 * 60,
        minPhotos: Int = 1
    ) -> [PhotoUploadBatch] {
        photoRepository.getLikelyUploadBatches(
            gapSeconds: gapSeconds,
            minPhotos: minPhotos,
            locationMatchMiles: eventTuningUnsafe().locationMatchMiles
        )
    }

    func applyArchiveBatchMetadata(
        photoIds: [String],
        captureDate: Date,
        latitude: Double,
        longitude: Double
    ) {
        photoRepository.applyArchiveBatchMetadata(
            photoIds: photoIds,
            captureDate: captureDate,
            latitude: latitude,
            longitude: longitude
        )
    }

    func updateFaceMetrics(
        photoId: String,
        eyesOpenScore: Double,
        smileScore: Double
    ) {
        photoRepository.updateFaceMetrics(
            photoId: photoId,
            eyesOpenScore: eyesOpenScore,
            smileScore: smileScore
        )
    }

    func faceMetricsAlgorithmVersion() -> Int {
        photoRepository.faceMetricsAlgorithmVersion()
    }

    func setFaceMetricsAlgorithmVersion(_ version: Int) {
        photoRepository.setFaceMetricsAlgorithmVersion(version)
    }

    func clearFaceMetrics(forPhotoIds photoIds: [String]) {
        photoRepository.clearFaceMetrics(forPhotoIds: photoIds)
    }

    func getPhotoCropData(photoId: String) -> PhotoCropFocusRecord? {
        photoRepository.getPhotoCropData(photoId: photoId)
    }

    func updateCropFocuses(
        photoId: String,
        list: PhotoCropFocus?,
        frame: PhotoCropFocus?
    ) {
        photoRepository.updateCropFocuses(photoId: photoId, list: list, frame: frame)
    }

    func cropAlgorithmVersion() -> Int {
        photoRepository.cropAlgorithmVersion()
    }

    func setCropAlgorithmVersion(_ version: Int) {
        photoRepository.setCropAlgorithmVersion(version)
    }

    func ensureCropAlgorithmVersionCurrent() {
        dbQueue.sync {
            guard photoRepository.cropAlgorithmVersion() < PhotoFaceCropAnalyzer.algorithmVersion else {
                return
            }
            photoRepository.clearAllCropFocuses()
            photoRepository.setCropAlgorithmVersion(PhotoFaceCropAnalyzer.algorithmVersion)
        }
    }

    func clearAllCropFocuses() {
        photoRepository.clearAllCropFocuses()
    }

    func clearCropFocus(photoId: String) {
        photoRepository.clearCropFocus(photoId: photoId)
    }


    // MARK: - Event repository forwards

    func updateCoverPhotoForEvent(eventId: Int) {
        eventRepository.updateCoverPhotoForEvent(eventId: eventId)
    }

    func updateWeddingCoverPhotoForEvent(eventId: Int) {
        eventRepository.updateWeddingCoverPhotoForEvent(eventId: eventId)
    }

    func replaceUserEventMainPeople(eventId: Int, names: [String]) {
        eventTags.replaceUserEventMainPeople(eventId: eventId, names: names)
        eventRepository.updateEventAttribute(eventId: eventId, field: .mainPerson, value: names.first)
    }

    func updateAllEventCoverPhotos() {
        eventRepository.updateAllEventCoverPhotos()
    }

    func backfillEventAssignedAt() {
        eventRepository.backfillEventAssignedAt()
    }


    func setEventShowOnFrame(eventId: Int, show: Bool) {
        eventRepository.setEventShowOnFrame(eventId: eventId, show: show)
    }

    func setEventFavorite(eventId: Int, isFavorite: Bool) {
        eventRepository.setEventFavorite(eventId: eventId, isFavorite: isFavorite)
    }

    func listEventIdsWithOnFramePhotos(among eventIds: [Int]) -> Set<Int> {
        eventRepository.listEventIdsWithOnFramePhotos(among: eventIds)
    }

    func setEventUserHidden(eventId: Int, hidden: Bool) {
        eventRepository.setEventUserHidden(eventId: eventId, hidden: hidden)
    }

    func getEventAttributeOptions(for field: EventAttributeField) -> [String] {
        eventRepository.getEventAttributeOptions(for: field)
    }

    func addCustomEventAttributeOption(_ value: String, for field: EventAttributeField) {
        eventRepository.addCustomEventAttributeOption(value, for: field)
    }

    func updateEventAttribute(eventId: Int, field: EventAttributeField, value: String?) {
        eventRepository.updateEventAttribute(eventId: eventId, field: field, value: value)
        eventTags.syncUserAttributeTag(eventId: eventId, field: field, tagValue: value)
    }

    func updateWeddingDate(eventId: Int, weddingDate: String?) {
        eventRepository.updateWeddingDate(eventId: eventId, weddingDate: weddingDate)
    }

    @discardableResult
    func upsertMarriedCoupleRelationship(
        bridePersonId: Int,
        groomPersonId: Int,
        weddingDateISO: String,
        sourceEventId: Int?
    ) -> PeopleRelationship? {
        container.peopleRelationships.upsertMarriedCouple(
            bridePersonId: bridePersonId,
            groomPersonId: groomPersonId,
            weddingDateISO: weddingDateISO,
            sourceEventId: sourceEventId,
            source: "user"
        )
    }

    func propagateAnniversaryTagsFromWedding(
        sourceEventId: Int,
        person1: String,
        person2: String,
        weddingDateISO: String
    ) -> Int {
        dbQueue.sync {
            AnniversaryTagPropagationService(
                events: eventRepository,
                eventTags: eventTags
            )
            .propagateUnsafe(
                sourceEventId: sourceEventId,
                person1: person1,
                person2: person2,
                weddingDateISO: weddingDateISO
            )
        }
    }


    func runEventObjectRecognitionIfNeeded(
        eventId: Int,
        includeHiddenPhotos: Bool,
        progress: (@Sendable (EventObjectRecognitionProgress) -> Void)? = nil
    ) async -> EventObjectRecognitionResult {
        let result = await container.eventObjectRecognition.runIfNeeded(
            eventId: eventId,
            includeHiddenPhotos: includeHiddenPhotos,
            progress: progress
        )
        return result
    }

    func enqueueEventObjectRecognitionJobs(
        eventId: Int,
        includeHiddenPhotos: Bool,
        forceRescan: Bool = false,
        forcedOccasionKey: String? = nil,
        priority: Int = 100,
        scopeKey: String? = nil
    ) -> VisionJobEnqueueSummary {
        let summary = container.visionJobEnqueue.enqueueEventObjectRecognition(
            eventId: eventId,
            includeHiddenPhotos: includeHiddenPhotos,
            forceRescan: forceRescan,
            forcedOccasionKey: forcedOccasionKey,
            priority: priority,
            scopeKey: scopeKey
        )
        Task { @MainActor in
            container.visionJobCoordinator.startIfNeeded()
        }
        return summary
    }

    func enqueueHolidayYearObjectRecognitionJobs(
        config: HolidayVisionLandingConfig,
        year: Int,
        eventIds: [Int],
        includeHiddenPhotos: Bool = false,
        priority: Int = 50
    ) -> VisionJobEnqueueSummary {
        let summary = container.visionJobEnqueue.enqueueHolidayYearObjectRecognition(
            config: config,
            year: year,
            eventIds: eventIds,
            includeHiddenPhotos: includeHiddenPhotos,
            priority: priority
        )
        Task { @MainActor in
            container.visionJobCoordinator.startIfNeeded()
        }
        return summary
    }

    func visionJobPendingCount(scopeKey: String? = nil, eventId: Int? = nil) -> Int {
        dbQueue.sync {
            container.visionJobs.countPendingUnsafe(
                scopeKey: scopeKey,
                eventId: eventId,
                algorithmVersion: PhotoObjectVisionAnalyzer.algorithmVersion
            )
        }
    }

    private func holidayScanEventLabel(eventId: Int) -> String {
        dbQueue.sync {
            guard let event = eventRepository.getEvent(eventId: eventId) else {
                return "Event \(eventId)"
            }
            let title = event.listTitleText ?? event.name
            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let namePart = trimmedTitle.isEmpty ? "Untitled" : trimmedTitle
            let datePart = event.displayDateText ?? "—"
            return "\(namePart) · \(datePart)"
        }
    }

    func holidayVisionLandingConfig(tagValue: String) -> HolidayVisionLandingConfig? {
        HolidayVisionLandingConfig.matching(tagValue: tagValue)
    }

    func fetchAllHolidayVisionLandingConfigs() -> [HolidayVisionLandingConfig] {
        HolidayVisionLandingConfig.allWithObjectKeys
    }

    func holidayYearNeedsVisionScan(
        config: HolidayVisionLandingConfig,
        eventIds: [Int],
        includeHiddenPhotos: Bool
    ) -> Bool {
        dbQueue.sync {
            eventTags.anyAITaggedHolidayEventsNeedObjectRecognitionUnsafe(
                eventIds: eventIds,
                tagValue: config.tagValue,
                includeHidden: includeHiddenPhotos,
                algorithmVersion: PhotoObjectVisionAnalyzer.algorithmVersion
            )
        }
    }

    /// Scans AI-tagged holiday events in one expanded year section (list events intersected with scan candidates).
    func runHolidayObjectRecognitionForYear(
        config: HolidayVisionLandingConfig,
        year: Int,
        eventIds: [Int],
        eventLabels: [Int: String] = [:],
        includeHiddenPhotos: Bool = false,
        progress: (@Sendable (String) -> Void)? = nil
    ) async -> ChristmasLandingVisionScanReport {
        if Task.isCancelled {
            return emptyHolidayVisionScanReport()
        }

        guard !eventIds.isEmpty else {
            return emptyHolidayVisionScanReport()
        }

        let queueWaitStart = CFAbsoluteTimeGetCurrent()
        let yearEventIds = dbQueue.sync {
            eventTags.fetchAITaggedHolidayEventIdsNeedingObjectRecognitionUnsafe(
                eventIds: eventIds,
                tagValue: config.tagValue,
                includeHidden: includeHiddenPhotos,
                algorithmVersion: PhotoObjectVisionAnalyzer.algorithmVersion
            )
        }
        logHolidayVisionQueueWait(config: config, queueWaitStart: queueWaitStart)

        return await runHolidayObjectRecognitionLoop(
            config: config,
            eventIds: yearEventIds,
            eventLabels: eventLabels,
            scopeLabel: "\(year)",
            includeHiddenPhotos: includeHiddenPhotos,
            progress: progress
        )
    }

    /// Runs incremental Vision scans for AI-tagged Christmas events that have not finished object recognition.
    func runChristmasLandingObjectRecognitionIfNeeded(
        includeHiddenPhotos: Bool = false,
        progress: (@Sendable (String) -> Void)? = nil
    ) async -> ChristmasLandingVisionScanReport {
        guard let config = holidayVisionLandingConfig(tagValue: "Christmas") else {
            return emptyHolidayVisionScanReport()
        }
        if Task.isCancelled {
            return emptyHolidayVisionScanReport()
        }

        let queueWaitStart = CFAbsoluteTimeGetCurrent()
        let eventIds = dbQueue.sync {
            eventTags.fetchAITaggedHolidayEventIdsNeedingObjectRecognitionUnsafe(
                tagValue: config.tagValue,
                includeHidden: includeHiddenPhotos,
                algorithmVersion: PhotoObjectVisionAnalyzer.algorithmVersion
            )
        }
        logHolidayVisionQueueWait(config: config, queueWaitStart: queueWaitStart)

        return await runHolidayObjectRecognitionLoop(
            config: config,
            eventIds: eventIds,
            eventLabels: [:],
            scopeLabel: config.logLabel,
            includeHiddenPhotos: includeHiddenPhotos,
            progress: progress
        )
    }

    func christmasYearNeedsVisionScan(
        eventIds: [Int],
        includeHiddenPhotos: Bool
    ) -> Bool {
        guard let config = holidayVisionLandingConfig(tagValue: "Christmas") else { return false }
        return holidayYearNeedsVisionScan(
            config: config,
            eventIds: eventIds,
            includeHiddenPhotos: includeHiddenPhotos
        )
    }

    func runChristmasObjectRecognitionForYear(
        year: Int,
        eventIds: [Int],
        eventLabels: [Int: String] = [:],
        includeHiddenPhotos: Bool = false,
        progress: (@Sendable (String) -> Void)? = nil
    ) async -> ChristmasLandingVisionScanReport {
        guard let config = holidayVisionLandingConfig(tagValue: "Christmas") else {
            return emptyHolidayVisionScanReport()
        }
        return await runHolidayObjectRecognitionForYear(
            config: config,
            year: year,
            eventIds: eventIds,
            eventLabels: eventLabels,
            includeHiddenPhotos: includeHiddenPhotos,
            progress: progress
        )
    }

    private func emptyHolidayVisionScanReport() -> ChristmasLandingVisionScanReport {
        ChristmasLandingVisionScanReport(
            candidateEventCount: 0,
            eventsScanned: 0,
            eventsSkipped: 0,
            photosScanned: 0,
            detectionsWritten: 0,
            earlyExits: 0,
            elapsedSeconds: 0
        )
    }

    private func logHolidayVisionQueueWait(
        config: HolidayVisionLandingConfig,
        queueWaitStart: CFAbsoluteTime
    ) {
        let queueWaitSeconds = CFAbsoluteTimeGetCurrent() - queueWaitStart
        if queueWaitSeconds > 0.5 {
            print(
                String(
                    format: "%@ vision scan: waited %.1fs for database queue before loading candidates",
                    config.logLabel,
                    queueWaitSeconds
                )
            )
        }
    }

    private func runHolidayObjectRecognitionLoop(
        config: HolidayVisionLandingConfig,
        eventIds: [Int],
        eventLabels: [Int: String],
        scopeLabel: String,
        includeHiddenPhotos: Bool,
        progress: (@Sendable (String) -> Void)?
    ) async -> ChristmasLandingVisionScanReport {
        let start = CFAbsoluteTimeGetCurrent()

        let startMessage =
            "\(config.logLabel) vision scan (\(scopeLabel)) starting · \(eventIds.count) AI-tagged event(s) need scanning"
        print(startMessage)
        progress?(startMessage)

        guard !eventIds.isEmpty else {
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            let doneMessage = String(
                format: "%@ vision scan (\(scopeLabel)) finished · 0/0 events · 0 photos · %.1fs",
                config.logLabel,
                elapsed
            )
            print(doneMessage)
            return ChristmasLandingVisionScanReport(
                candidateEventCount: 0,
                eventsScanned: 0,
                eventsSkipped: 0,
                photosScanned: 0,
                detectionsWritten: 0,
                earlyExits: 0,
                elapsedSeconds: elapsed
            )
        }

        var eventsScanned = 0
        var eventsSkipped = 0
        var photosScanned = 0
        var detectionsWritten = 0
        var earlyExits = 0

        for (index, eventId) in eventIds.enumerated() {
            if Task.isCancelled {
                print(
                    "\(config.logLabel) vision scan (\(scopeLabel)) cancelled before event \(index + 1)/\(eventIds.count)"
                )
                break
            }

            let eventLabel = eventLabels[eventId] ?? holidayScanEventLabel(eventId: eventId)
            progress?("Scanning \(scopeLabel) \(index + 1)/\(eventIds.count): \(eventLabel)")

            let result = await container.eventObjectRecognition.runIfNeeded(
                eventId: eventId,
                includeHiddenPhotos: includeHiddenPhotos,
                forcedOccasionKey: config.occasionKey,
                progress: { scanProgress in
                    if let status = scanProgress.statusText {
                        print("\(scopeLabel) \(index + 1)/\(eventIds.count): \(eventLabel) · \(status)")
                    }
                }
            )

            if let skippedReason = result.skippedReason {
                eventsSkipped += 1
                let message = "Skipped \(scopeLabel) \(index + 1)/\(eventIds.count): \(eventLabel)"
                print(message + " — \(skippedReason)")
                progress?(message)
            } else {
                eventsScanned += 1
                photosScanned += result.photosScanned
                detectionsWritten += result.detectionsWritten
                if result.stoppedEarly {
                    earlyExits += 1
                }

                var message =
                    "Scanned \(scopeLabel) \(index + 1)/\(eventIds.count): \(eventLabel)"
                    + " · \(result.photosScanned) photo\(result.photosScanned == 1 ? "" : "s")"
                if result.detectionsWritten > 0 {
                    message += " · \(result.detectionsWritten) detection\(result.detectionsWritten == 1 ? "" : "s")"
                }
                if result.stoppedEarly {
                    message += " · stopped early"
                }
                print(message)
                progress?(message)
            }

            await Task.yield()
            try? await Task.sleep(for: .milliseconds(120))
        }

        if !eventIds.isEmpty {
            dbQueue.sync {
                for eventId in eventIds {
                }
            }
        }

        let doneMessage = String(
            format: "%@ vision scan (\(scopeLabel)) finished · %d/%d events · %d photos · %.1fs",
            config.logLabel,
            eventsScanned,
            eventIds.count,
            photosScanned,
            CFAbsoluteTimeGetCurrent() - start
        )
        print(doneMessage)
        progress?(doneMessage)

        return ChristmasLandingVisionScanReport(
            candidateEventCount: eventIds.count,
            eventsScanned: eventsScanned,
            eventsSkipped: eventsSkipped,
            photosScanned: photosScanned,
            detectionsWritten: detectionsWritten,
            earlyExits: earlyExits,
            elapsedSeconds: CFAbsoluteTimeGetCurrent() - start
        )
    }

    struct ChristmasObjectRecognitionResetReport: Sendable {
        let taggedEventCount: Int
        let candidatesNeedingScan: Int
    }

    func resetHolidayObjectRecognitionState(
        config: HolidayVisionLandingConfig,
        includeHiddenPhotos: Bool = true
    ) -> ChristmasObjectRecognitionResetReport {
        dbQueue.sync {
            let eventIds = holidayTaggedListEventIdsUnsafe(
                tagValue: config.tagValue,
                includeHiddenPhotos: includeHiddenPhotos
            )
            guard !eventIds.isEmpty else {
                return ChristmasObjectRecognitionResetReport(
                    taggedEventCount: 0,
                    candidatesNeedingScan: 0
                )
            }

            eventTags.clearObjectRecognitionForEventsUnsafe(eventIds: eventIds)
            container.objectTags.clearPhotoVisionScansForEventsUnsafe(eventIds: eventIds)
            container.objectTags.clearObjectDetectionsForEventsUnsafe(eventIds: eventIds)
            container.visionJobs.purgeJobsForEventsUnsafe(eventIds: eventIds)

            for eventId in eventIds {
            }

            let candidates = eventTags.fetchAITaggedHolidayEventIdsNeedingObjectRecognitionUnsafe(
                tagValue: config.tagValue,
                includeHidden: includeHiddenPhotos,
                algorithmVersion: PhotoObjectVisionAnalyzer.algorithmVersion
            )

            return ChristmasObjectRecognitionResetReport(
                taggedEventCount: eventIds.count,
                candidatesNeedingScan: candidates.count
            )
        }
    }

    /// Clears Vision scan state for Christmas-tagged events without running a new scan.
    func resetChristmasObjectRecognitionState(
        includeHiddenPhotos: Bool = true
    ) -> ChristmasObjectRecognitionResetReport {
        guard let config = holidayVisionLandingConfig(tagValue: "Christmas") else {
            return ChristmasObjectRecognitionResetReport(taggedEventCount: 0, candidatesNeedingScan: 0)
        }
        return resetHolidayObjectRecognitionState(
            config: config,
            includeHiddenPhotos: includeHiddenPhotos
        )
    }

    private func holidayTaggedListEventIdsUnsafe(
        tagValue: String,
        includeHiddenPhotos: Bool
    ) -> [Int] {
        let filter = EventListFilter.holidayTag(value: tagValue)
        let visible = eventRepository.fetchListEventIdsForFilterUnsafe(
            filter: filter,
            includeHidden: false
        )
        guard includeHiddenPhotos else {
            return visible
        }
        let hidden = eventRepository.fetchListEventIdsForFilterUnsafe(
            filter: filter,
            includeHidden: true
        )
        return Array(Set(visible + hidden))
    }

    /// Clears object-scan state for holiday-tagged list events and enqueues a full Vision rescan.
    func enqueueHolidayTaggedObjectRescan(
        tagValue: String,
        includeHiddenPhotos: Bool = true,
        priority: Int = 10
    ) -> VisionJobRescanEnqueueResult {
        guard let config = holidayVisionLandingConfig(tagValue: tagValue) else {
            return VisionJobRescanEnqueueResult(
                taggedEventCount: 0,
                enqueuedCount: 0,
                scopeKey: "devRescan:\(tagValue)"
            )
        }

        let eventIds = dbQueue.sync {
            holidayTaggedListEventIdsUnsafe(
                tagValue: tagValue,
                includeHiddenPhotos: includeHiddenPhotos
            )
        }

        guard !eventIds.isEmpty else {
            return VisionJobRescanEnqueueResult(
                taggedEventCount: 0,
                enqueuedCount: 0,
                scopeKey: "devRescan:\(tagValue)"
            )
        }

        _ = resetHolidayObjectRecognitionState(
            config: config,
            includeHiddenPhotos: includeHiddenPhotos
        )

        let result = container.visionJobEnqueue.enqueueHolidayTaggedRescan(
            config: config,
            eventIds: eventIds,
            includeHiddenPhotos: includeHiddenPhotos,
            priority: priority
        )

        Task { @MainActor in
            container.visionJobCoordinator.startIfNeeded()
        }

        return result
    }

    /// Clears and re-queues Vision for every Christmas-tagged list event (developer tool).
    func enqueueChristmasTaggedObjectRescan(
        includeHiddenPhotos: Bool = true,
        priority: Int = 10
    ) -> VisionJobRescanEnqueueResult {
        enqueueHolidayTaggedObjectRescan(
            tagValue: "Christmas",
            includeHiddenPhotos: includeHiddenPhotos,
            priority: priority
        )
    }

    func confirmAIAttributeTag(eventId: Int, field: EventAttributeField) {
        eventTags.confirmAIAttributeTag(eventId: eventId, field: field)
    }

    func rejectAIAttributeTag(eventId: Int, field: EventAttributeField) {
        eventTags.rejectAIAttributeTag(eventId: eventId, field: field)
    }

    func removeEventAttributeTag(eventId: Int, tag: EventAttributeTag) {
        eventTags.removeEventAttributeTag(eventId: eventId, tag: tag)
    }

    @discardableResult
    func purgeEventAttributeTag(eventId: Int, category: String, tagValue: String) -> Int {
        eventTags.purgeEventAttributeTag(
            eventId: eventId,
            category: category,
            tagValue: tagValue
        )
    }

    @discardableResult
    func purgeRejectedAttributeTags(eventId: Int) -> Int {
        eventTags.purgeRejectedAttributeTags(eventId: eventId)
    }

    func fetchAllAttributeTagRowsForEvent(eventId: Int) -> [(
        category: String,
        tagValue: String,
        source: String,
        isRejected: Bool
    )] {
        eventTags.fetchAllAttributeTagRowsForEvent(eventId: eventId)
    }

    func fetchSimilarEventAlternatives(
        tagCategory: String,
        tagValue: String
    ) -> [SimilarEventTagAlternative] {
        eventTags.fetchSimilarEventAlternatives(
            tagCategory: tagCategory,
            tagValue: tagValue
        )
    }

    func applySimilarEventUserTag(
        eventId: Int,
        tagCategory: String,
        tagValue: String
    ) {
        eventTags.applySimilarEventUserTag(
            eventId: eventId,
            tagCategory: tagCategory,
            tagValue: tagValue
        )
        eventRepository.updateEventAttribute(
            eventId: eventId,
            field: EventAttributeField.fromTagCategory(tagCategory) ?? .milestoneType,
            value: tagValue
        )
    }

    func fetchEventNameTemplate(
        tagCategory: String,
        tagValue: String
    ) -> EventNameTemplate? {
        eventTags.fetchEventNameTemplate(tagCategory: tagCategory, tagValue: tagValue)
    }

    func fetchAllEventNameTemplates() -> [EventNameTemplate] {
        eventTags.fetchAllEventNameTemplates()
    }

    func upsertEventNameTemplate(
        tagCategory: String,
        tagValue: String,
        nameTemplate: String,
        personCount: Int
    ) -> EventNameTemplate? {
        eventTags.upsertEventNameTemplate(
            tagCategory: tagCategory,
            tagValue: tagValue,
            nameTemplate: nameTemplate,
            personCount: personCount
        )
    }

    func fetchAllSimilarEventTags() -> [SimilarEventTagAlternative] {
        eventTags.fetchAllSimilarEventTags()
    }

    @discardableResult
    func insertSimilarEventTag(
        tagCategory: String,
        tagValue: String,
        possibleTagCategory: String,
        possibleTagValue: String,
        possibleNumberOfEventMainPeople: Int
    ) -> SimilarEventTagAlternative? {
        eventTags.insertSimilarEventTag(
            tagCategory: tagCategory,
            tagValue: tagValue,
            possibleTagCategory: possibleTagCategory,
            possibleTagValue: possibleTagValue,
            possibleNumberOfEventMainPeople: possibleNumberOfEventMainPeople
        )
    }

    func confirmAIHolidayTag(eventId: Int) {
        confirmAIAttributeTag(eventId: eventId, field: .holidayType)
    }

    func rejectAIHolidayTag(eventId: Int) {
        rejectAIAttributeTag(eventId: eventId, field: .holidayType)
    }

    func getEventsForLocation(locationId: Int) -> [IndexedEvent] {
        eventTags.attachAttributeTags(
            to: eventRepository.getEventsForLocation(locationId: locationId)
        )
    }

    @discardableResult
    func updateEventName(eventId: Int, name: String, userEdited: Bool) -> Bool {
        eventRepository.updateEventName(eventId: eventId, name: name, userEdited: userEdited)
    }

    @discardableResult
    func updateChildEventName(eventId: Int, name: String, userEdited: Bool) -> Bool {
        eventRepository.updateChildEventName(eventId: eventId, name: name, userEdited: userEdited)
    }

    func syncDefaultChildEventName(forSubEventId eventId: Int) {
        eventRepository.syncDefaultChildEventName(forSubEventId: eventId)
    }

    func countListEvents(
        includeHidden: Bool = false,
        filter: EventListFilter = .allEvents
    ) -> Int {
        eventRepository.countListEvents(includeHidden: includeHidden, filter: filter)
    }

    func fetchAllStadiums() -> [Stadium] {
        container.stadiums.fetchAllStadiums()
    }

    func fetchStadium(stadiumId: Int) -> Stadium? {
        container.stadiums.fetchStadium(stadiumId: stadiumId)
    }

    @discardableResult
    func upsertStadium(
        stadiumId: Int?,
        name: String,
        city: String?,
        state: String?,
        latitude: Double?,
        longitude: Double?
    ) -> Int? {
        container.stadiums.upsertStadium(
            stadiumId: stadiumId,
            name: name,
            city: city,
            state: state,
            latitude: latitude,
            longitude: longitude
        )
    }

    func deleteStadium(stadiumId: Int) {
        container.stadiums.deleteStadium(stadiumId: stadiumId)
    }

    func addStadiumAlias(stadiumId: Int, alias: String) {
        container.stadiums.addStadiumAlias(stadiumId: stadiumId, alias: alias)
    }

    func deleteStadiumAlias(stadiumId: Int, alias: String) {
        container.stadiums.deleteStadiumAlias(stadiumId: stadiumId, alias: alias)
    }

    @discardableResult
    func upsertStadiumTeam(
        stadiumTeamId: Int?,
        stadiumId: Int,
        league: SportsLeague,
        teamName: String,
        displayName: String?,
        teamAbbreviation: String?,
        isPrimaryHome: Bool
    ) -> Int? {
        container.stadiums.upsertStadiumTeam(
            stadiumTeamId: stadiumTeamId,
            stadiumId: stadiumId,
            league: league,
            teamName: teamName,
            displayName: displayName,
            teamAbbreviation: teamAbbreviation,
            isPrimaryHome: isPrimaryHome
        )
    }

    func deleteStadiumTeam(stadiumTeamId: Int) {
        container.stadiums.deleteStadiumTeam(stadiumTeamId: stadiumTeamId)
    }

    func fetchEventGameResult(eventId: Int) -> EventGameResult? {
        container.stadiums.fetchGameResult(eventId: eventId)
    }

    func fetchEventGameResults(eventIds: [Int]) -> [Int: EventGameResult] {
        container.stadiums.fetchGameResults(eventIds: eventIds)
    }

    func saveEventGameResult(_ result: EventGameResult) {
        container.stadiums.saveGameResult(result)
    }

    func clearEventGameResult(eventId: Int) {
        container.stadiums.clearGameResult(eventId: eventId)
    }

    func lookupSportsGameCandidates(
        eventDateISO: String,
        placeName: String?,
        city: String?,
        state: String?,
        latitude: Double?,
        longitude: Double?
    ) async throws -> (stadiums: [Stadium], candidates: [SportsGameCandidate]) {
        try await container.sportsGameLookup.lookupCandidates(
            eventDateISO: eventDateISO,
            placeName: placeName,
            city: city,
            state: state,
            latitude: latitude,
            longitude: longitude
        )
    }

    func countLocations() -> Int {
        locationRepository.countRows("locations")
    }

    func getEvents(includeHidden: Bool = false) -> [IndexedEvent] {
        eventTags.attachAttributeTags(
            to: eventRepository.getEvents(includeHidden: includeHidden)
        )
    }

    func getEventsForList(
        includeHidden: Bool = false,
        limit: Int? = nil,
        filter: EventListFilter = .allEvents
    ) -> [IndexedEvent] {
        dbQueue.sync {
            var events = eventTags.attachAttributeTagsUnsafe(
                to: eventRepository.getEventsUnsafe(
                    includeHidden: includeHidden,
                    limit: limit,
                    filter: filter
                )
            )
            if case .milestoneTag(let tagValue) = filter {
                events.sort {
                    IndexedEvent.compareMilestoneTaggedListOrder(
                        $0,
                        $1,
                        tagValue: tagValue
                    )
                }
            } else if case .eventTypeTag(let tagValue) = filter {
                events.sort {
                    IndexedEvent.compareEventTypeTaggedListOrder(
                        $0,
                        $1,
                        tagValue: tagValue
                    )
                }
            } else if case .holidayTag(let tagValue) = filter, tagValue == "Christmas" {
                events.sort {
                    IndexedEvent.compareHolidayTaggedListOrder(
                        $0,
                        $1,
                        tagValue: tagValue
                    )
                }
            }
            return events
        }
    }

    func getEvent(eventId: Int) -> IndexedEvent? {
        guard let event = eventRepository.getEvent(eventId: eventId) else { return nil }
        return eventTags.attachHolidayTags(to: [event]).first
    }

    func eventMatchesListFilter(eventId: Int, filter: EventListFilter) -> Bool {
        dbQueue.sync {
            eventRepository.eventMatchesListFilterUnsafe(eventId: eventId, filter: filter)
        }
    }

    private var eventTags: EventTagRepository { container.eventTags }

    func getSlideshowPhotoIds(for events: [IndexedEvent]) -> [Int: [String]] {
        eventRepository.getSlideshowPhotoIds(for: events)
    }

    func getOnFrameVideoIds(for events: [IndexedEvent]) -> [Int: String] {
        eventRepository.getOnFrameVideoIds(for: events)
    }

    func setPhotoShowOnFrame(photoId: String, eventId: Int, show: Bool) {
        persistPhotoOnFrameChanges(
            defaultEventId: eventId,
            writes: [(photoId: photoId, show: show)],
            similarGroupPicks: [],
            clearCropFocusPhotoIds: []
        )
    }

    func removePhotoFromEvent(photoId: String, eventId: Int) {
        eventRepository.removePhotoFromEvent(photoId: photoId, eventId: eventId)
    }

    func getPhotosForEvent(eventId: Int, includeHidden: Bool = false) -> [IndexedPhoto] {
        eventRepository.getPhotosForEvent(eventId: eventId, includeHidden: includeHidden)
    }

    func fetchEventPhotoSortMetadata(photoIds: [String]) -> (
        metadata: [String: EventPhotoSortMetadata],
        locationLabels: [Int: String]
    ) {
        dbQueue.sync {
            let uniqueIds = Array(Set(photoIds))
            guard !uniqueIds.isEmpty else {
                return ([:], [:])
            }

            let sortFields = photoRepository.fetchSortFieldsUnsafe(photoIds: uniqueIds)
            let cameras = container.photoExif.fetchCameraLabelsUnsafe(photoIds: uniqueIds)

            var metadata: [String: EventPhotoSortMetadata] = [:]
            metadata.reserveCapacity(uniqueIds.count)
            var locationIds = Set<Int>()

            for photoId in uniqueIds {
                let fields = sortFields[photoId]
                let camera = cameras[photoId]
                if let locationId = fields?.locationId {
                    locationIds.insert(locationId)
                }
                metadata[photoId] = EventPhotoSortMetadata(
                    indexedAt: fields?.indexedAt,
                    cameraMake: camera?.make,
                    cameraModel: camera?.model,
                    locationId: fields?.locationId
                )
            }

            var locationLabels: [Int: String] = [:]
            for locationId in locationIds {
                guard let location = locationRepository.getLocation(locationId: locationId) else {
                    continue
                }
                locationLabels[locationId] = PhotoPreviewLocationFormatting.line(
                    nickname: location.nickname,
                    placeName: location.placeName,
                    city: location.city,
                    state: location.state,
                    latitude: location.latitude,
                    longitude: location.longitude
                )
            }

            return (metadata, locationLabels)
        }
    }

    func setSimilarGroupPicks(groupPhotoIds: [String], pickedPhotoIds: Set<String>) {
        eventRepository.setSimilarGroupPicks(groupPhotoIds: groupPhotoIds, pickedPhotoIds: pickedPhotoIds)
    }

    func setPhotosShowOnFrame(photoIds: [String], show: Bool) {
        persistPhotoOnFrameChanges(
            defaultEventId: 0,
            writes: photoIds.map { (photoId: $0, show: show) },
            similarGroupPicks: [],
            clearCropFocusPhotoIds: []
        )
    }

    func persistPhotoOnFrameChanges(
        defaultEventId: Int,
        writes: [(photoId: String, show: Bool)],
        similarGroupPicks: [(groupPhotoIds: [String], pickedPhotoIds: [String])],
        clearCropFocusPhotoIds: [String]
    ) {
        guard !writes.isEmpty || !similarGroupPicks.isEmpty || !clearCropFocusPhotoIds.isEmpty else {
            return
        }

        dbQueue.sync {
            for pick in similarGroupPicks {
                eventRepository.setSimilarGroupPicks(
                    groupPhotoIds: pick.groupPhotoIds,
                    pickedPhotoIds: Set(pick.pickedPhotoIds)
                )
            }

            var touchedEventIds = Set<Int>()
            var lastWriteByPhotoId: [String: Bool] = [:]
            for write in writes {
                lastWriteByPhotoId[write.photoId] = write.show
            }

            for (photoId, show) in lastWriteByPhotoId {
                let eventId = eventRepository.getEventIdForPhotoUnsafe(photoId: photoId)
                    ?? (defaultEventId > 0 ? defaultEventId : nil)
                guard let eventId else { continue }

                eventRepository.setPhotoShowOnFrameUnsafe(
                    photoId: photoId,
                    eventId: eventId,
                    show: show
                )
                touchedEventIds.insert(eventId)
            }

            for photoId in clearCropFocusPhotoIds {
                photoRepository.clearCropFocus(photoId: photoId)
            }

            if !touchedEventIds.isEmpty {
                eventRepository.refreshSummariesAndCovers(for: touchedEventIds)
            }
        }
    }

    @discardableResult
    func setPhotosHiddenInEvent(photoIds: [String], hidden: Bool) -> [String] {
        eventRepository.setPhotosHiddenInEvent(photoIds: photoIds, hidden: hidden)
    }

    func fetchPhotosForBrowser(photoIds: [String]) -> [(photo: IndexedPhoto, mediaType: Int)] {
        photoRepository.fetchPhotosForBrowser(photoIds: photoIds)
    }

    func fetchPhotosForBrowser(
        photoIds: [String],
        year: Int,
        useImportDate: Bool
    ) -> [(photo: IndexedPhoto, mediaType: Int, indexedAt: String)] {
        photoRepository.fetchPhotosForBrowser(
            photoIds: photoIds,
            year: year,
            useImportDate: useImportDate
        )
    }

    func fetchAllPhotosForBrowser() -> [(photo: IndexedPhoto, mediaType: Int, indexedAt: String)] {
        photoRepository.fetchAllPhotosForBrowser()
    }

    func fetchPhotosForBrowserYear(_ year: Int) -> [(photo: IndexedPhoto, mediaType: Int, indexedAt: String)] {
        photoRepository.fetchPhotosForBrowserYear(year)
    }

    func fetchDistinctPhotoYearsForBrowser() -> [Int] {
        photoRepository.fetchDistinctPhotoYearsForBrowser()
    }

    func countActivePhotosForBrowser() -> Int {
        photoRepository.countActivePhotosForBrowser()
    }

    func setPhotosFavorite(photoIds: [String], isFavorite: Bool) {
        photoRepository.setPhotosFavorite(photoIds: photoIds, isFavorite: isFavorite)
    }

    func softDeletePhotos(photoIds: [String]) {
        photoRepository.softDeletePhotos(photoIds: photoIds)
    }

    func shiftPhotoCaptureDates(updates: [(photoId: String, newCreationDate: Date)]) {
        photoRepository.shiftPhotoCaptureDates(updates: updates)
    }

    func promoteCaptureDatesAfterPhotosSync(updates: [(photoId: String, newCreationDate: Date)]) {
        photoRepository.promoteCaptureDatesAfterPhotosSync(updates: updates)
    }

    func shiftPhotoLocations(
        updates: [(photoId: String, latitude: Double, longitude: Double, locationId: Int?)]
    ) {
        photoRepository.shiftPhotoLocations(updates: updates)
    }

    func promoteLocationsAfterPhotosSync(
        updates: [(photoId: String, latitude: Double, longitude: Double)]
    ) {
        photoRepository.promoteLocationsAfterPhotosSync(updates: updates)
    }

    func findEventsContainingDateRange(
        rangeStart: Date,
        rangeEnd: Date,
        excludingEventId: Int?
    ) -> [IndexedEvent] {
        eventTags.attachAttributeTags(
            to: eventRepository.findEventsContainingDateRange(
                rangeStart: rangeStart,
                rangeEnd: rangeEnd,
                excludingEventId: excludingEventId
            )
        )
    }

    func createEventForShiftedPhotos(
        photoIds: [String],
        fromEventId: Int?,
        rangeStart: Date,
        rangeEnd: Date,
        locationId: Int?,
        latitude: Double?,
        longitude: Double?
    ) -> IndexedEvent? {
        guard let event = eventRepository.createEventForShiftedPhotos(
            photoIds: photoIds,
            fromEventId: fromEventId,
            rangeStart: rangeStart,
            rangeEnd: rangeEnd,
            locationId: locationId,
            latitude: latitude,
            longitude: longitude
        ) else {
            return nil
        }
        return eventTags.attachAttributeTags(to: [event]).first
    }

    func movePhotosToEvent(
        photoIds: [String],
        fromEventId: Int?,
        toEventId: Int,
        photoDates: [String: Date]
    ) {
        eventRepository.movePhotosToEvent(
            photoIds: photoIds,
            fromEventId: fromEventId,
            toEventId: toEventId,
            photoDates: photoDates
        )
        refreshPlacesAfterMembershipChange(eventIds: [fromEventId, toEventId].compactMap { $0 })
        rescoreTagsAfterMembershipChange(eventIds: [fromEventId, toEventId].compactMap { $0 })
    }

    /// Sends each photo to the Everyday Photos month for its own date. Creates that month when needed.
    func movePhotosIntoEveryday(
        photoIds: [String],
        fromEventId: Int?,
        photoDates: [String: Date]
    ) {
        let grouped = Dictionary(grouping: photoIds) { photoId -> Date in
            let date = photoDates[photoId] ?? Date()
            return EverydayPhotos.monthBounds(containing: date).start
        }
        var destinationIds: [Int] = []
        for (monthStart, ids) in grouped {
            let eventId = eventRepository.findOrCreateEverydayEvent(containing: monthStart)
            guard eventId != fromEventId else { continue }
            updateEventAttribute(
                eventId: eventId,
                field: .eventType,
                value: EverydayPhotos.tagValue
            )
            eventRepository.movePhotosToEvent(
                photoIds: ids,
                fromEventId: fromEventId,
                toEventId: eventId,
                photoDates: photoDates,
                expandDestinationDates: false
            )
            eventRepository.restoreEverydayMonthShell(eventId: eventId, containing: monthStart)
            destinationIds.append(eventId)
        }
        var touched = destinationIds
        if let fromEventId {
            touched.append(fromEventId)
        }
        refreshPlacesAfterMembershipChange(eventIds: touched)
        rescoreTagsAfterMembershipChange(eventIds: touched)
    }

    func movePhotosOntoEvent(
        photoIds: [String],
        fromEventId: Int?,
        toEventId: Int,
        photoDates: [String: Date],
        expandDestinationDates: Bool
    ) {
        eventRepository.movePhotosToEvent(
            photoIds: photoIds,
            fromEventId: fromEventId,
            toEventId: toEventId,
            photoDates: photoDates,
            expandDestinationDates: expandDestinationDates
        )
        var touched = [toEventId]
        if let fromEventId {
            touched.append(fromEventId)
        }
        refreshPlacesAfterMembershipChange(eventIds: touched)
        rescoreTagsAfterMembershipChange(eventIds: touched)
    }

    func refreshEventPlacesForPhotos(photoIds: [String]) {
        let eventIds = Array(Set(photoIds.compactMap { getEventIdForPhoto(photoId: $0) }))
        refreshPlacesAfterMembershipChange(eventIds: eventIds)
    }

    private func refreshPlacesAfterMembershipChange(eventIds: [Int]) {
        for eventId in Set(eventIds) {
            guard let event = eventRepository.getEvent(eventId: eventId) else { continue }
            if EverydayPhotos.isEverydayName(event.name) { continue }
            eventLocationCoordinator.assignEventLocationKeepingCompletedPlace(eventId: eventId)
            if let parentId = event.parentEventId {
                eventRepository.updateTripParentSummary(parentEventId: parentId)
            }
        }
    }

    private func rescoreTagsAfterMembershipChange(eventIds: [Int]) {
        let cards = fetchAllEventScoreCardSettings()
        guard !cards.isEmpty else { return }
        for eventId in Set(eventIds) {
            guard let event = getEvent(eventId: eventId) else { continue }
            if event.isEverydayPhotos { continue }
            if event.isTripContainer {
                rescore(eventId: event.eventId, cards: cards, tripsOnly: true)
                for child in getSubEvents(parentEventId: event.eventId) {
                    rescore(eventId: child.eventId, cards: cards, tripsOnly: false)
                }
            } else if event.isTripSubEvent {
                rescore(eventId: event.eventId, cards: cards, tripsOnly: false)
                if let parentId = event.parentEventId {
                    rescore(eventId: parentId, cards: cards, tripsOnly: true)
                }
            } else {
                rescore(eventId: event.eventId, cards: cards, tripsOnly: nil)
            }
        }
    }

    private func rescore(
        eventId: Int,
        cards: [PictureSearchEventScoreCardSettings],
        tripsOnly: Bool?
    ) {
        for card in cards {
            let isTrips = card.targetTagCategory.localizedCaseInsensitiveCompare("Trips") == .orderedSame
            if let tripsOnly {
                if tripsOnly != isTrips { continue }
            }
            let score = scoreEventAgainstScoreCard(eventId: eventId, scoreCard: card)
            let keepsExactDate = card.targetTagCategory.localizedCaseInsensitiveCompare("holiday") == .orderedSame
                || card.targetEventType.localizedCaseInsensitiveCompare("Birthday") == .orderedSame
            if !card.meetsAIThreshold(totalScore: score.totalScore), !keepsExactDate {
                container.eventTags.deleteAIAttributeTag(
                    eventId: eventId,
                    category: card.targetTagCategory,
                    tagValue: card.targetEventType
                )
            }
        }
    }

    func getEventIdForPhoto(photoId: String) -> Int? {
        eventRepository.getEventIdForPhoto(photoId: photoId)
    }

    func getSubEvents(parentEventId: Int) -> [IndexedEvent] {
        eventTags.attachAttributeTags(
            to: eventRepository.getSubEvents(parentEventId: parentEventId)
        )
    }

    func getTripSections(for parentEventId: Int, includeHidden: Bool = false) -> [TripEventSection] {
        eventRepository.getTripSections(for: parentEventId, includeHidden: includeHidden)
    }

    func updateEventsFromLocation(locationId: Int) {
        eventRepository.updateEventsFromLocation(locationId: locationId)
    }
    func geocodePendingLocations(limit: Int = 10) {
        if limit > 0 {
            let pending = locationRepository.fetchPendingGeocodeLocations(limit: limit)
            if #available(iOS 26.0, *) {
                LocationGeocodeCoordinator.shared.enqueue(pending)
            }
        } else {
            startGeocodingAllPending()
        }
    }
    
    func debugCounts() {
        DevDatabaseTools.debugCounts(database: databaseManager)
    }

    func debugMetadataCounts() {
        DevDatabaseTools.debugMetadataCounts(database: databaseManager)
    }

    func debugPrintFirstEvents() {
        DevDatabaseTools.debugPrintFirstEvents(database: databaseManager)
    }

    func debugPrintAlbumNames() {
        DevDatabaseTools.debugPrintAlbumNames()
    }

    func countRows(_ tableOrQuery: String) -> Int {
        locationRepository.countRows(tableOrQuery)
    }

    func updateEventLocationFromRepresentativePoint(eventId: Int) {
        eventLocationCoordinator.updateEventLocationFromRepresentativePoint(eventId: eventId)
    }

    func snapEventsNearDesignatedHomes() {
        dbQueue.sync {
            eventLocationCoordinator.snapEventsNearDesignatedHomesUnsafe()
        }
    }

    func snapEventsNearDesignatedHomesUnsafe() {
        eventLocationCoordinator.snapEventsNearDesignatedHomesUnsafe()
    }

    func debugEventPipeline() {
        DevDatabaseTools.debugEventPipeline(database: databaseManager)
    }


    func fetchHolidayLandingCatalogItems() -> [HolidayLandingItem] {
        let holidays = container.holidays.fetchAllEnabledHolidays()
        let birthdays = fetchPeopleWithBirthDates()
        return HolidayLandingCatalog.build(
            holidays: holidays,
            nextOccurrenceForHoliday: { holiday in
                container.holidays.nextOccurrence(for: holiday)
            },
            peopleWithBirthDates: birthdays
        )
    }

    func fetchAllPeople() -> [PeopleRepository.PersonRecord] {
        peopleRepository.fetchAllPeople()
    }

    func fetchPeopleWithBirthDates() -> [PeopleRepository.PersonBirthdayRecord] {
        peopleRepository.fetchPeopleWithBirthDates()
    }

    func enqueueFaceRecognitionScan(forceRescan: Bool = false, limit: Int = 2_000) -> VisionJobEnqueueSummary {
        let summary = container.visionJobEnqueue.enqueueFaceRecognitionScan(
            forceRescan: forceRescan,
            limit: limit
        )
        if summary.enqueuedCount > 0 {
            container.visionJobCoordinator.startIfNeeded()
        }
        return summary
    }

    /// Seeds face detect+embed for specific photos (Picture Search results / event open).
    @discardableResult
    func enqueueFaceRecognitionForPhotoIds(_ photoIds: [String]) -> VisionJobEnqueueSummary {
        let summary = container.visionJobEnqueue.enqueueFaceRecognitionForPhotoIds(photoIds)
        if summary.enqueuedCount > 0 {
            container.visionJobCoordinator.startIfNeeded()
        }
        return summary
    }

    /// Seeds face detect for photos in an event that still need a scan.
    @discardableResult
    func enqueueFaceRecognitionForEvent(
        eventId: Int,
        includeHidden: Bool = false
    ) -> VisionJobEnqueueSummary {
        let photoIds = getPhotosForEvent(eventId: eventId, includeHidden: includeHidden).map(\.id)
        return enqueueFaceRecognitionForPhotoIds(photoIds)
    }

    private func maybeEnqueueFaceDetectAfterPictureSearch(
        definition: PictureSearchDefinition,
        report: PictureSearchRunReport
    ) {
        guard definition.performFaceDetect else { return }
        let photoIds = report.photoMatches.map(\.photoId)
        guard !photoIds.isEmpty else { return }
        _ = enqueueFaceRecognitionForPhotoIds(photoIds)
    }

    /// Cancels queued face jobs and re-stamps photos that already have face rows (undo accidental force-rescan).
    @discardableResult
    func cancelFaceRecognitionScan(restoreScannedVersions: Bool = true) -> Int {
        container.visionJobCoordinator.cancelScope("faceRecognition:library")
        guard restoreScannedVersions else { return 0 }
        return restoreFaceRecognitionVersionsForScannedPhotos()
    }

    /// Fixes progress after force-rescan cleared version stamps while face rows still exist.
    @discardableResult
    func restoreFaceRecognitionVersionsForScannedPhotos() -> Int {
        databaseManager.sync {
            container.faceRecognition.restoreFaceRecognitionVersionsForPhotosWithFacesUnsafe(
                algorithmVersion: FaceRecognitionAnalyzer.algorithmVersion
            )
        }
    }

    /// Cancels/purges face jobs and deletes all face recognition + face-named people data.
    func resetAllFaceRecognitionData() {
        container.visionJobCoordinator.cancelScope("faceRecognition:library")
        databaseManager.sync {
            container.visionJobs.purgeJobsOfTypeUnsafe(jobType: .faceRecognitionScan)
        }
        container.faceRecognitionService.resetAllFaceRecognitionData()
    }

    func fetchUnnamedFaceClusters() -> [PersonClusterRecord] {
        container.faceRecognitionService.fetchUnnamedClusters()
    }

    func fetchFaceAnnotations(
        forPhotoId photoId: String,
        suggestionEventId: Int?
    ) -> [PhotoFaceAnnotation] {
        container.faceRecognitionService.fetchFaceAnnotations(
            forPhotoId: photoId,
            suggestionEventId: suggestionEventId
        )
    }

    func ensurePhotoFaceScanned(
        photoId: String,
        suggestionEventId: Int?,
        upgradeToPreviewScan: Bool
    ) async -> [PhotoFaceAnnotation] {
        await container.faceRecognitionService.ensurePhotoFaceScanned(
            photoId: photoId,
            suggestionEventId: suggestionEventId,
            upgradeToPreviewScan: upgradeToPreviewScan
        )
    }

    @discardableResult
    func nameFaceInstance(
        faceInstanceId: Int,
        displayName: String,
        firstName: String?,
        lastName: String?,
        maidenName: String?
    ) -> Int {
        container.faceRecognitionService.nameFaceInstance(
            faceInstanceId: faceInstanceId,
            displayName: displayName,
            firstName: firstName,
            lastName: lastName,
            maidenName: maidenName
        )
    }

    @discardableResult
    func propagateNamedFaceToSimilarPhotos(
        sourceFaceInstanceId: Int,
        siblingPhotoIds: [String]
    ) async -> Int {
        await container.faceRecognitionService.propagateNamedFaceToSimilarPhotos(
            sourceFaceInstanceId: sourceFaceInstanceId,
            siblingPhotoIds: siblingPhotoIds
        )
    }

    func nameFaceCluster(
        clusterId: Int,
        displayName: String,
        firstName: String?,
        lastName: String?,
        maidenName: String?
    ) -> Int {
        container.faceRecognitionService.nameCluster(
            clusterId: clusterId,
            displayName: displayName,
            firstName: firstName,
            lastName: lastName,
            maidenName: maidenName
        )
    }

    func mergeFaceCluster(clusterId: Int, intoPersonId personId: Int) {
        container.faceRecognitionService.mergeClusterIntoPerson(
            clusterId: clusterId,
            personId: personId
        )
    }

    func ignoreFaceCluster(clusterId: Int) {
        container.faceRecognitionService.ignoreCluster(clusterId: clusterId)
    }

    @discardableResult
    func consolidateUnnamedFaceClusters() -> Int {
        container.faceRecognitionService.consolidateUnnamedClusters()
    }

    @discardableResult
    func rebuildUnnamedFaceClusters() -> Int {
        container.faceRecognitionService.rebuildUnnamedClusters()
    }

    func fetchPhotoIdsForPerson(personId: Int) -> [String] {
        container.faceRecognitionService.fetchPhotoIds(forPersonId: personId)
    }

    func fetchPhotoIdsForFaceCluster(clusterId: Int) -> [String] {
        container.faceRecognitionService.fetchPhotoIds(forClusterId: clusterId)
    }

    func countPhotosNeedingFaceRecognition() -> Int {
        databaseManager.sync {
            container.faceRecognition.countPhotosNeedingFaceRecognitionUnsafe(
                algorithmVersion: FaceRecognitionAnalyzer.algorithmVersion
            )
        }
    }

    func faceRecognitionProgress() -> FaceRecognitionProgress {
        databaseManager.sync {
            container.faceRecognition.faceRecognitionProgressUnsafe(
                algorithmVersion: FaceRecognitionAnalyzer.algorithmVersion
            )
        }
    }

    func pendingFaceRecognitionJobCount() -> Int {
        container.visionJobCoordinator.pendingCount(scopeKey: "faceRecognition:library")
    }

    func fetchEventPeople(
        eventId: Int,
        includeChildEvents: Bool
    ) -> [EventRepository.EventPersonRecord] {
        eventRepository.fetchEventPeople(
            eventId: eventId,
            includeChildEvents: includeChildEvents
        )
    }
}
