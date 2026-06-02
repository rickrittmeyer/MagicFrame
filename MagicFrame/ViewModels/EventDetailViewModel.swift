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

    private var faceAnalysisTask: Task<Void, Never>?

    init(
        event: IndexedEvent,
        onEventUpdated: ((Int) -> Void)? = nil,
        onEventHidden: ((Int) -> Void)? = nil,
        onEventUnhidden: ((Int) -> Void)? = nil
    ) {
        let freshEvent = PhotoDatabase.shared.getEvent(eventId: event.eventId) ?? event
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
        EventNameSuggester.suggest(
            locationDisplayText: event.locationDisplayText,
            startDate: event.startDate,
            endDate: event.endDate,
            people: event.people
        )
    }

    var showSuggestion: Bool {
        guard !userEditedName else { return false }

        guard let name = suggestedName,
              !name.isEmpty else {
            return false
        }

        return eventName.trimmingCharacters(in: .whitespacesAndNewlines) != name
    }

    func toggleShowHiddenPhotos() {
        showHiddenPhotos.toggle()
        loadPhotos()
    }

    func loadPhotos() {
        if event.isTripContainer {
            tripSections = PhotoDatabase.shared.getTripSections(
                for: event.eventId,
                includeHidden: showHiddenPhotos
            )
            photos = tripSections.flatMap(\.photos)
        } else {
            tripSections = []
            photos = PhotoDatabase.shared.getPhotosForEvent(
                eventId: event.eventId,
                includeHidden: showHiddenPhotos
            )
        }

        rebuildDisplayItems()
        selectedPhotoIds = selectedPhotoIds.intersection(Set(photos.map(\.id)))
        syncTripChildEventNameDrafts()
        analyzeFaceMetricsForStacksIfNeeded()
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

        let saved = PhotoDatabase.shared.updateChildEventName(
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

    private func analyzeFaceMetricsForStacksIfNeeded() {
        faceAnalysisTask?.cancel()

        if PhotoDatabase.shared.faceMetricsAlgorithmVersion()
            != PhotoFaceAnalyzer.algorithmVersion {
            let stackPhotoIds = allDisplayItems
                .filter(\.isStack)
                .flatMap { $0.group.photos.map(\.id) }
            PhotoDatabase.shared.clearFaceMetrics(forPhotoIds: stackPhotoIds)
            PhotoDatabase.shared.setFaceMetricsAlgorithmVersion(PhotoFaceAnalyzer.algorithmVersion)
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
                    PhotoDatabase.shared.updateFaceMetrics(
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
            tripSections = PhotoDatabase.shared.getTripSections(
                for: event.eventId,
                includeHidden: showHiddenPhotos
            )
            photos = tripSections.flatMap(\.photos)
        } else {
            tripSections = []
            photos = PhotoDatabase.shared.getPhotosForEvent(
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

        PhotoDatabase.shared.setSimilarGroupPicks(
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
        PhotoDatabase.shared.setPhotosHiddenInEvent(
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
        eventTypeOptions = PhotoDatabase.shared.getEventAttributeOptions(for: .eventType)
        activityTypeOptions = PhotoDatabase.shared.getEventAttributeOptions(for: .activityType)
        tripTypeOptions = PhotoDatabase.shared.getEventAttributeOptions(for: .tripType)
        milestoneTypeOptions = PhotoDatabase.shared.getEventAttributeOptions(for: .milestoneType)
        holidayTypeOptions = PhotoDatabase.shared.getEventAttributeOptions(for: .holidayType)

        var people = Set(PhotoDatabase.shared.getAllPersonNames())
        people.formUnion(event.people)
        personOptions = people.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
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
        }
    }

    func options(for field: EventAttributeField) -> [String] {
        switch field {
        case .eventType: return eventTypeOptions
        case .activityType: return activityTypeOptions
        case .tripType: return tripTypeOptions
        case .milestoneType: return milestoneTypeOptions
        case .holidayType: return holidayTypeOptions
        case .mainPerson: return personOptions
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

        PhotoDatabase.shared.addCustomEventAttributeOption(trimmed, for: field)
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
        PhotoDatabase.shared.updateEventAttribute(
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
        }

        refreshEvent()
    }

    private func syncClassification(from event: IndexedEvent) {
        eventType = event.eventType
        activityType = event.activityType
        tripType = event.tripType
        milestoneType = event.milestoneType
        holidayType = event.holidayType
        eventMainPerson = event.eventMainPerson
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
            PhotoDatabase.shared.setPhotosShowOnFrame(
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

        PhotoDatabase.shared.setPhotosHiddenInEvent(photoIds: [photoId], hidden: true)
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

        PhotoDatabase.shared.setPhotosHiddenInEvent(
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
        PhotoDatabase.shared.setEventUserHidden(eventId: event.eventId, hidden: true)
        onEventHidden?(event.eventId)
    }

    func unhideEvent() {
        PhotoDatabase.shared.setEventUserHidden(eventId: event.eventId, hidden: false)
        refreshEvent()
        onEventUnhidden?(event.eventId)
    }

    var isUserHidden: Bool {
        event.isUserHidden
    }

    func refreshEvent() {
        guard let updated = PhotoDatabase.shared.getEvent(eventId: event.eventId) else {
            return
        }

        event = updated
        syncClassification(from: updated)
        notifyEventUpdated()
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

        let saved = PhotoDatabase.shared.updateEventName(
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

        let owningEventId = PhotoDatabase.shared.getEventIdForPhoto(photoId: photoId) ?? event.eventId

        if show, let group, group.isStack {
            for sibling in group.photos where sibling.id != photoId {
                let siblingEventId = PhotoDatabase.shared.getEventIdForPhoto(photoId: sibling.id) ?? owningEventId
                PhotoDatabase.shared.setPhotoShowOnFrame(
                    photoId: sibling.id,
                    eventId: siblingEventId,
                    show: false
                )
            }

            PhotoDatabase.shared.setSimilarGroupPicks(
                groupPhotoIds: group.photos.map(\.id),
                pickedPhotoIds: [photoId]
            )
        }

        PhotoDatabase.shared.setPhotoShowOnFrame(
            photoId: photoId,
            eventId: owningEventId,
            show: show
        )

        PhotoDatabase.shared.clearCropFocus(photoId: photoId)

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
}
