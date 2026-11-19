import CoreLocation
import SwiftUI

/// Reusable photo grid for picture (non-event) surfaces: select → frame / hide / favorite, tap → detail.
struct PictureBrowserView: View {

    let title: String
    private let sortOptions: [PictureBrowserSort]
    private let usesNavigationTitle: Bool
    private let enablesVideoFilter: Bool
    /// Shown in the grid context menu when non-nil (People photo grid → profile picture).
    private let onUseAsProfilePicture: ((String) -> Void)?
    @StateObject private var vm: PictureBrowserViewModel
    @EnvironmentObject private var libraryVM: LibraryViewModel
    @State private var selectedDetailIndex: Int?
    @State private var displayItems: [EventPhotoDisplayItem] = []
    @State private var isShowingAdjustDateSheet = false
    @State private var isShowingAdjustLocationSheet = false
    @State private var pendingDateAdjustPreview: PhotoDateAdjustPreview?
    @State private var pendingLocationAdjustPreview: PhotoLocationAdjustPreview?
    @State private var isShowingLeaveEventPrompt = false
    @State private var isShowingExistingEventPicker = false
    @State private var candidateEventsForDateAdjust: [IndexedEvent] = []
    @State private var isShowingNoMatchingEventAlert = false
    @State private var dateAdjustSuccessEvent: IndexedEvent?
    @State private var isShowingDateAdjustSuccess = false
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
    @State private var isShowingMediaSearchSheet = false

    init(
        title: String,
        photoIds: [String] = [],
        confidenceByPhotoId: [String: Double] = [:],
        loadsAllPhotos: Bool = false,
        sortOptions: [PictureBrowserSort]? = nil,
        usesNavigationTitle: Bool = false,
        enablesVideoFilter: Bool = false,
        browseMonthScope: BrowseMonthScope? = nil,
        onUseAsProfilePicture: ((String) -> Void)? = nil
    ) {
        self.title = title
        self.sortOptions = sortOptions ?? (loadsAllPhotos ? [.dateTaken, .dateImported] : [.dateTaken, .confidence])
        self.usesNavigationTitle = usesNavigationTitle
        self.enablesVideoFilter = enablesVideoFilter || usesNavigationTitle
        self.onUseAsProfilePicture = onUseAsProfilePicture
        let resolvedScope = browseMonthScope ?? (loadsAllPhotos ? .allLibrary : nil)
        _vm = StateObject(
            wrappedValue: PictureBrowserViewModel(
                photoIds: photoIds,
                confidenceByPhotoId: confidenceByPhotoId,
                loadsAllPhotos: loadsAllPhotos,
                enablesYearNavigation: usesNavigationTitle,
                browseMonthScope: resolvedScope
            )
        )
    }

    var body: some View {
            VStack(spacing: 0) {
            if usesNavigationTitle {
                iconBar
                if vm.activeMediaSearchQuery != nil {
                    mediaSearchChipBar
                }
                if showsMonthSections, vm.usesYearNavigation, !vm.availableYears.isEmpty {
                    yearJumpBar
                }
            } else {
                headerBar
            }

            ScrollViewReader { proxy in
                ScrollView {
                    if let statusMessage = vm.statusMessage {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if (vm.isLoading && vm.items.isEmpty) || (!vm.visibleItems.isEmpty && displayItems.isEmpty) {
                        ProgressView("Loading pictures…")
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    } else if vm.visibleItems.isEmpty {
                        ContentUnavailableView(
                            "No Pictures",
                            systemImage: "photo.on.rectangle.angled",
                            description: Text(emptyDescription)
                        )
                        .padding(.top, 24)
                    } else {
                        PhotoGrid(
                            sections: photoGridSections,
                            isSelecting: vm.isSelecting,
                            selectedPhotoIds: vm.selectedPhotoIds,
                            onTap: { item in
                                if vm.isSelecting {
                                    vm.toggleSelection(photoId: item.representative.id)
                                } else if let index = displayItems.firstIndex(where: { $0.id == item.id }) {
                                    selectedDetailIndex = index
                                }
                            },
                            sectionHeader: { section in
                                if showsMonthSections {
                                    monthSectionHeader(sectionId: section.id)
                                }
                            },
                            contextMenu: { item in
                                let photo = item.representative
                                if let onUseAsProfilePicture {
                                    Button {
                                        onUseAsProfilePicture(photo.id)
                                    } label: {
                                        Label("Use as Profile Picture", systemImage: "person.crop.circle")
                                    }
                                }
                                Button(photo.showOnFrame ? "Remove from Frame" : "Add to Frame") {
                                    vm.togglePhotoOnFrame(photoId: photo.id)
                                }
                                Button(photo.isHiddenInEvent ? "Unhide" : "Hide") {
                                    vm.togglePhotoHidden(photoId: photo.id)
                                }
                                Button(photo.isFavorite ? "Unfavorite" : "Favorite") {
                                    vm.togglePhotoFavorite(photoId: photo.id)
                                }
                            }
                        )
                    }
                }
                .coordinateSpace(name: "pictureBrowserScroll")
                .onPreferenceChange(PictureBrowserVisibleYearKey.self) { frames in
                    guard showsMonthSections, vm.usesYearNavigation else { return }
                    guard vm.pendingScrollYear == nil, vm.pendingScrollMonthSectionId == nil else { return }
                    guard let visible = Self.focusedVisibleMonth(from: frames) else { return }
                    if vm.focusedYear != visible.year {
                        vm.focusedYear = visible.year
                    }
                    vm.rememberVisibleMonth(sectionId: visible.sectionId, libraryVM: libraryVM)
                }
                .onChange(of: vm.pendingScrollYear) { _, year in
                    guard let year else { return }
                    scrollToYear(year, using: proxy)
                }
                .onChange(of: vm.pendingScrollMonthSectionId) { _, sectionId in
                    guard let sectionId else { return }
                    scrollToMonth(sectionId, using: proxy)
                }
                .onChange(of: displayItems.count) { _, _ in
                    if let sectionId = vm.pendingScrollMonthSectionId {
                        scrollToMonth(sectionId, using: proxy)
                    } else if let year = vm.pendingScrollYear {
                        scrollToYear(year, using: proxy)
                    }
                }
            }
        }
        .background(Color(.systemBackground))
        .modifier(PictureBrowserNavigationTitle(isEnabled: usesNavigationTitle, title: headingTitle))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if vm.isSelecting {
                selectionBar
            }
        }
        .navigationDestination(isPresented: $isNavigatingToDestinationEvent) {
            if let destinationEventToOpen {
                EventDetailView(event: destinationEventToOpen)
            }
        }
        .sheet(isPresented: $isShowingMediaSearchSheet) {
            MediaPhotoSearchSheet(
                initialQuery: vm.activeMediaSearchQuery ?? .empty()
            ) { query, report in
                vm.applyMediaSearch(query: query, report: report)
            }
        }
        .onChange(of: libraryVM.mediaPhotoSearchRequestID) { _, requestID in
            guard requestID != nil, vm.supportsMediaSearch else { return }
            libraryVM.consumeMediaPhotoSearchRequest()
            isShowingMediaSearchSheet = true
        }
        .sheet(isPresented: $isShowingAdjustDateSheet) {
            if let originalDate = vm.adjustDateAnchorDate {
                PhotoAdjustDateTimeSheet(
                    originalDate: originalDate,
                    selectedCount: vm.selectedCount,
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
        .sheet(isPresented: $isShowingAdjustLocationSheet) {
            PhotoAdjustLocationSheet(
                originalLabel: vm.adjustLocationAnchorLabel,
                originalCoordinate: vm.adjustLocationAnchorCoordinate.map {
                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                },
                selectedCount: vm.selectedCount,
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
        .overlay {
            if vm.isAdjustingDates || vm.isAdjustingLocations
                || isSyncingApplePhotosDates || isSyncingApplePhotosLocations {
                ZStack {
                    Color.black.opacity(0.25).ignoresSafeArea()
                    ProgressView(browserProgressOverlayTitle)
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
            Button("Stay Here", role: .cancel) {}
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
        .onAppear {
            libraryVM.setMainTabChromeMode(.full)
        }
        .task {
            await vm.load()
            vm.applyRestoredMonthAnchorIfNeeded(libraryVM: libraryVM)
        }
        .task(id: gridTaskKey) {
            await reloadDisplayItems()
        }
        .fullScreenCover(isPresented: isDetailPresented) {
            if let detailIndex = selectedDetailIndex {
                PhotoPreviewView(
                    items: displayItems,
                    resolvingPhotos: vm.visiblePhotos,
                    initialIndex: detailIndex,
                    onDismiss: { selectedDetailIndex = nil },
                    header: { context in
                        PhotoPreviewStandardHeader(
                            photo: context.photo,
                            index: context.displayIndex + 1,
                            count: context.displayCount,
                            showsCounter: !context.isZoomed,
                            onClose: { selectedDetailIndex = nil }
                        )
                    },
                    actions: { context in
                        picturePreviewActions(for: context.photo)
                    }
                )
            }
        }
    }

    private var showsMonthSections: Bool { usesNavigationTitle }

    private var photoGridSections: [PhotoGridSection] {
        guard showsMonthSections else {
            return [PhotoGridSection(id: "photos", items: displayItems)]
        }
        return Self.monthSections(
            from: displayItems,
            sort: vm.sort,
            indexedAt: { [vm] photoId in vm.indexedAt(for: photoId) }
        )
    }

    private var iconBar: some View {
        HStack(spacing: 12) {
            if vm.isSelecting {
                selectionStatus
            } else {
                if usesNavigationTitle, !vm.isLoading || !vm.items.isEmpty {
                    Text(mediaCountText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if vm.supportsMediaSearch {
                    Button {
                        isShowingMediaSearchSheet = true
                    } label: {
                        Image(systemName: vm.activeMediaSearchQuery == nil
                              ? "magnifyingglass"
                              : "magnifyingglass.circle.fill")
                            .font(.body.weight(.semibold))
                            .frame(width: 32, height: 32)
                    }
                    .accessibilityLabel("Search pictures")
                }
                sortMenu
                filterMenu
                selectButton
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var mediaSearchChipBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                .foregroundStyle(Color.accentColor)
            Text("\(vm.mediaSearchMatchCount.formatted()) match\(vm.mediaSearchMatchCount == 1 ? "" : "es")")
                .font(.subheadline.weight(.semibold))
            Spacer(minLength: 8)
            Button("Edit") {
                isShowingMediaSearchSheet = true
            }
            .font(.subheadline.weight(.semibold))
            Button("Clear") {
                vm.clearMediaSearch()
            }
            .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var yearJumpBar: some View {
        ScrollViewReader { yearProxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(vm.availableYears, id: \.self) { year in
                        let isFocused = vm.focusedYear == year
                        Button {
                            vm.jumpToYear(year)
                        } label: {
                            Text(String(year))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(isFocused ? Color(.systemBackground) : .primary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    isFocused ? Color.accentColor : Color(.secondarySystemFill),
                                    in: RoundedRectangle(cornerRadius: 8)
                                )
                        }
                        .buttonStyle(.plain)
                        .id(year)
                        .accessibilityLabel("Jump to \(year)")
                        .accessibilityAddTraits(isFocused ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(.bar)
            .onChange(of: vm.focusedYear) { _, year in
                guard let year else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    yearProxy.scrollTo(year, anchor: .center)
                }
            }
        }
    }

    private func scrollToYear(_ year: Int, using proxy: ScrollViewProxy) {
        let prefix = "\(year)-"
        guard let sectionId = photoGridSections.first(where: { $0.id.hasPrefix(prefix) })?.id else {
            // Keep the request if the year is loaded but the grid has not rebuilt yet.
            // Otherwise a year with no matches would leave the highlight stuck.
            if !vm.visibleItemsContain(year: year) {
                vm.acknowledgePendingScrollYear()
            }
            return
        }
        withAnimation(.easeInOut(duration: 0.25)) {
            proxy.scrollTo(sectionId, anchor: .top)
        }
        vm.acknowledgePendingScrollYear()
    }

    private func scrollToMonth(_ sectionId: String, using proxy: ScrollViewProxy) {
        let targetId: String
        if photoGridSections.contains(where: { $0.id == sectionId }) {
            targetId = sectionId
        } else if let year = Self.year(fromMonthSectionId: sectionId) {
            let prefix = "\(year)-"
            guard let fallback = photoGridSections.first(where: { $0.id.hasPrefix(prefix) })?.id else {
                return
            }
            targetId = fallback
        } else {
            return
        }

        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            proxy.scrollTo(targetId, anchor: .top)
        }
        vm.acknowledgePendingScrollMonth()
        vm.rememberVisibleMonth(sectionId: targetId, libraryVM: libraryVM)
    }

    private func monthSectionHeader(sectionId: String) -> some View {
        Text(Self.monthTitle(for: sectionId))
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(.systemBackground))
            .background {
                if let year = Self.year(fromMonthSectionId: sectionId) {
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: PictureBrowserVisibleYearKey.self,
                            value: [
                                PictureBrowserVisibleYear(
                                    year: year,
                                    sectionId: sectionId,
                                    minY: geo.frame(in: .named("pictureBrowserScroll")).minY
                                ),
                            ]
                        )
                    }
                }
            }
    }

    /// Month header currently pinned / nearest the top of the scroll view.
    private static func focusedVisibleMonth(
        from frames: [PictureBrowserVisibleYear]
    ) -> PictureBrowserVisibleYear? {
        guard !frames.isEmpty else { return nil }
        let threshold: CGFloat = 8
        let scrolledPast = frames.filter { $0.minY <= threshold }
        if let active = scrolledPast.max(by: { $0.minY < $1.minY }) {
            return active
        }
        return frames.min(by: { $0.minY < $1.minY })
    }

    private static func year(fromMonthSectionId id: String) -> Int? {
        guard id.count >= 4, let year = Int(id.prefix(4)), year >= 1000 else { return nil }
        return year
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            if vm.isSelecting {
                selectionStatus
            } else {
                Text(displayTitle)
                    .font(.title2.weight(.bold))
                    .lineLimit(1)

                Spacer(minLength: 8)

                sortMenu
                filterMenu
                selectButton
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var selectionStatus: some View {
        Group {
            Button("Cancel") {
                vm.cancelSelection()
            }
            .font(.body.weight(.medium))

            Spacer(minLength: 8)

            Text("\(vm.selectedCount) selected")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var sortMenu: some View {
        Menu {
            ForEach(sortOptions) { option in
                Button {
                    vm.sort = option
                } label: {
                    if vm.sort == option {
                        Label(sortMenuTitle(option), systemImage: "checkmark")
                    } else {
                        Text(sortMenuTitle(option))
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.body.weight(.semibold))
                .frame(width: 32, height: 32)
        }
        .accessibilityLabel("Sort")
    }

    private var filterMenu: some View {
        Menu {
            ForEach(PictureBrowserFilter.allCases) { option in
                Button {
                    guard filterIsAvailable(option) else { return }
                    vm.filter = option
                } label: {
                    if !filterIsAvailable(option) {
                        Text("\(filterMenuTitle(option)) (Coming soon)")
                    } else if vm.filter == option {
                        Label(filterMenuTitle(option), systemImage: "checkmark")
                    } else {
                        Text(filterMenuTitle(option))
                    }
                }
                .disabled(!filterIsAvailable(option))
            }

            Divider()

            Button(vm.showHiddenPhotos ? "Hide Hidden Photos" : "Show Hidden Photos") {
                vm.toggleShowHiddenPhotos()
            }
        } label: {
            Image(
                systemName: vm.filter == .allItems && !vm.showHiddenPhotos
                    ? "line.3.horizontal.decrease"
                    : "line.3.horizontal.decrease.circle.fill"
            )
            .font(.body.weight(.semibold))
            .frame(width: 32, height: 32)
        }
        .accessibilityLabel("Filter")
    }

    private var selectButton: some View {
        Button {
            vm.beginSelection()
        } label: {
            Image(systemName: "checkmark.circle")
                .font(.body.weight(.semibold))
                .frame(width: 32, height: 32)
        }
        .accessibilityLabel("Select")
    }

    /// When video filtering is enabled, `title` is the topic root (e.g. "Christmas", "All").
    private var displayTitle: String {
        guard enablesVideoFilter else { return title }
        switch vm.filter {
        case .photos:
            return "\(title) Photos"
        case .video:
            return "\(title) Videos"
        default:
            return "\(title) Photos and Videos"
        }
    }

    private var headingTitle: String {
        displayTitle
    }

    private var mediaCountText: String {
        let counts = vm.visibleMediaCounts
        let pictures = counts.pictures.formatted()
        let videos = counts.videos.formatted()
        let pictureLabel = counts.pictures == 1 ? "picture" : "pictures"
        let videoLabel = counts.videos == 1 ? "video" : "videos"
        return "\(pictures) \(pictureLabel) · \(videos) \(videoLabel)"
    }

    private func sortMenuTitle(_ option: PictureBrowserSort) -> String {
        usesNavigationTitle ? "Sort by \(option.title)" : option.title
    }

    private func filterMenuTitle(_ option: PictureBrowserFilter) -> String {
        option.title
    }

    private func filterIsAvailable(_ option: PictureBrowserFilter) -> Bool {
        if option == .video { return enablesVideoFilter }
        return true
    }

    private var emptyDescription: String {
        if vm.filter != .allItems {
            return "No pictures match the current filter."
        }
        if vm.showHiddenPhotos {
            return "No pictures in this set."
        }
        return "No visible pictures. Use Filter to show hidden photos."
    }

    private var selectionBar: some View {
        PhotoSelectionToggleBar(
            isEnabled: vm.selectedCount > 0,
            isFrameOn: vm.selectedAllOnFrame,
            isFavoriteOn: vm.selectedAllFavorite,
            isHiddenOn: vm.selectedAllHidden,
            onToggleFrame: {
                vm.toggleSelectedOnFrame()
            },
            onToggleFavorite: {
                vm.toggleSelectedFavorite()
            },
            onToggleHide: {
                vm.toggleSelectedHidden()
            },
            onAdjustDate: {
                guard vm.adjustDateAnchorDate != nil else { return }
                isShowingAdjustDateSheet = true
            },
            onAdjustLocation: {
                guard vm.selectedCount > 0 else { return }
                isShowingAdjustLocationSheet = true
            }
        )
    }

    private var browserProgressOverlayTitle: String {
        if isSyncingApplePhotosDates || isSyncingApplePhotosLocations {
            return "Updating Apple Photos…"
        }
        if vm.isAdjustingLocations {
            return "Updating locations…"
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
            runAfterDialogDismisses {
                isShowingLeaveEventPrompt = true
            }
        } else {
            Task { await commitDateAdjust(destination: nil) }
        }
    }

    private func presentExistingEventChoices() {
        guard let preview = pendingDateAdjustPreview else { return }
        let excluding = vm.sharedEventIdForSelection()
        let candidates = vm.candidateEventsForDateAdjust(
            preview: preview,
            excludingEventId: excluding
        )
        if candidates.isEmpty {
            isShowingNoMatchingEventAlert = true
        } else if candidates.count == 1, let only = candidates.first {
            Task { await commitDateAdjust(destination: .existing(eventId: only.eventId)) }
        } else {
            candidateEventsForDateAdjust = candidates
            isShowingExistingEventPicker = true
        }
    }

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

        if let error = result.errorMessage, result.destinationEvent == nil {
            dateAdjustErrorMessage = error
            return
        }

        pendingApplePhotosDateUpdates = photosUpdates
        dateAdjustSuccessEvent = result.destinationEvent

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

    private var gridTaskKey: String {
        "\(vm.contentRevision)|\(vm.sort.rawValue)|\(vm.filter.rawValue)|\(vm.showHiddenPhotos)"
    }

    private func reloadDisplayItems() async {
        vm.refreshVisibleYears()
        let records = vm.visibleItems
        let sort = vm.sort
        let indexedAtByPhotoId = Dictionary(uniqueKeysWithValues: records.map { ($0.id, vm.indexedAt(for: $0.id)) })
        let confidence = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0.matchConfidence ?? -1) })
        let photos = records.map(\.photo)
        let defersVision = vm.defersFullLibraryVisualRefine

        // Group off the main actor so the first paint is not blocked by a full-library sort/group.
        let metadataItems = await Task.detached(priority: .userInitiated) {
            let ascending = photos.sorted { $0.creationDate < $1.creationDate }
            let grouped = EventSimilarPhotoGrouper.displayItems(from: ascending)
            return Self.orderedDisplayItems(
                grouped,
                sort: sort,
                indexedAtByPhotoId: indexedAtByPhotoId,
                confidence: confidence
            )
        }.value

        guard !Task.isCancelled else { return }
        displayItems = metadataItems

        // Year-nav landings skip Vision on open (metadata stacks only) for performance.
        // Topic browsers without year nav still refine after first paint.
        guard !defersVision else { return }

        let ascending = photos.sorted { $0.creationDate < $1.creationDate }
        let refined = await EventSimilarPhotoGrouper.refinedDisplayItems(from: ascending)
        guard !Task.isCancelled else { return }
        displayItems = Self.orderedDisplayItems(
            refined,
            sort: sort,
            indexedAtByPhotoId: indexedAtByPhotoId,
            confidence: confidence
        )
    }

    private static func orderedDisplayItems(
        _ items: [EventPhotoDisplayItem],
        sort: PictureBrowserSort,
        indexedAtByPhotoId: [String: String],
        confidence: [String: Double]
    ) -> [EventPhotoDisplayItem] {
        switch sort {
        case .dateTaken:
            return Array(items.reversed())
        case .dateImported:
            return items.sorted {
                let left = indexedAtByPhotoId[$0.representative.id] ?? ""
                let right = indexedAtByPhotoId[$1.representative.id] ?? ""
                if left != right { return left > right }
                return $0.representative.id > $1.representative.id
            }
        case .confidence:
            return items.sorted {
                (confidence[$0.representative.id] ?? -1) > (confidence[$1.representative.id] ?? -1)
            }
        }
    }

    private static func monthSections(
        from items: [EventPhotoDisplayItem],
        sort: PictureBrowserSort,
        indexedAt: (String) -> String
    ) -> [PhotoGridSection] {
        var order: [String] = []
        var buckets: [String: [EventPhotoDisplayItem]] = [:]

        for item in items {
            let key = monthKey(for: item, sort: sort, indexedAt: indexedAt)
            if buckets[key] == nil {
                order.append(key)
                buckets[key] = []
            }
            buckets[key, default: []].append(item)
        }

        return order.map { key in
            PhotoGridSection(id: key, items: buckets[key] ?? [])
        }
    }

    private static func monthKey(
        for item: EventPhotoDisplayItem,
        sort: PictureBrowserSort,
        indexedAt: (String) -> String
    ) -> String {
        monthKey(forPhoto: item.representative, sort: sort, indexedAt: indexedAt)
    }

    private static func monthKey(
        forPhoto photo: IndexedPhoto,
        sort: PictureBrowserSort,
        indexedAt: (String) -> String
    ) -> String {
        let raw: String
        switch sort {
        case .dateTaken, .confidence:
            raw = photo.creationDate
        case .dateImported:
            raw = indexedAt(photo.id)
        }
        return monthKey(from: raw)
    }

    private static func monthKey(from dateString: String) -> String {
        let trimmed = dateString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 7 else { return "unknown" }
        let key = String(trimmed.prefix(7))
        guard key.count == 7,
              key[key.index(key.startIndex, offsetBy: 4)] == "-",
              key.prefix(4).allSatisfy(\.isNumber),
              key.suffix(2).allSatisfy(\.isNumber) else {
            return "unknown"
        }
        return key
    }

    private static func monthTitle(for key: String) -> String {
        guard key != "unknown",
              let date = monthKeyFormatter.date(from: key) else {
            return "Unknown Date"
        }
        return monthTitleFormatter.string(from: date)
    }

    private static let monthKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM"
        return formatter
    }()

    private static let monthTitleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "MMMM yyyy"
        return formatter
    }()

    @ViewBuilder
    private func picturePreviewActions(for photo: IndexedPhoto) -> some View {
        VStack(spacing: 6) {
            Spacer(minLength: 0)
            HStack(spacing: 28) {
                Button {
                    vm.togglePhotoOnFrame(photoId: photo.id)
                } label: {
                    VStack(spacing: 4) {
                        Image(
                            systemName: photo.showOnFrame
                                ? "rectangle.inset.filled.and.play.fill"
                                : "rectangle.on.rectangle"
                        )
                        .font(.title2)
                        Text(photo.showOnFrame ? "On Frame" : "Add to Frame")
                            .font(.caption2)
                    }
                    .foregroundStyle(photo.showOnFrame ? .green : .white)
                }

                Button {
                    vm.togglePhotoHidden(photoId: photo.id)
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: photo.isHiddenInEvent ? "eye" : "eye.slash")
                            .font(.title2)
                        Text(photo.isHiddenInEvent ? "Unhide" : "Hide")
                            .font(.caption2)
                    }
                    .foregroundStyle(.white)
                }

                Button {
                    vm.togglePhotoFavorite(photoId: photo.id)
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: photo.isFavorite ? "heart.fill" : "heart")
                            .font(.title2)
                        Text(photo.isFavorite ? "Favorited" : "Favorite")
                            .font(.caption2)
                    }
                    .foregroundStyle(photo.isFavorite ? .pink : .white)
                }
            }
        }
        .padding(.bottom, 20)
    }

    private var isDetailPresented: Binding<Bool> {
        Binding(
            get: { selectedDetailIndex != nil },
            set: { isPresented in
                if !isPresented { selectedDetailIndex = nil }
            }
        )
    }
}

private struct PictureBrowserNavigationTitle: ViewModifier {
    let isEnabled: Bool
    let title: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
        } else {
            content
        }
    }
}

/// Month-section header frame used to drive year-chip highlighting while scrolling.
private struct PictureBrowserVisibleYear: Equatable {
    let year: Int
    let sectionId: String
    let minY: CGFloat
}

private struct PictureBrowserVisibleYearKey: PreferenceKey {
    static var defaultValue: [PictureBrowserVisibleYear] = []

    static func reduce(
        value: inout [PictureBrowserVisibleYear],
        nextValue: () -> [PictureBrowserVisibleYear]
    ) {
        value.append(contentsOf: nextValue())
    }
}
