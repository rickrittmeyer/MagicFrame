import SwiftUI

/// Reusable photo grid for picture (non-event) surfaces: select → frame / hide / favorite, tap → detail.
struct PictureBrowserView: View {

    let title: String
    private let sortOptions: [PictureBrowserSort]
    private let usesNavigationTitle: Bool
    private let enablesVideoFilter: Bool
    @StateObject private var vm: PictureBrowserViewModel
    @State private var selectedDetailIndex: Int?
    @State private var displayItems: [EventPhotoDisplayItem] = []

    init(
        title: String,
        photoIds: [String] = [],
        confidenceByPhotoId: [String: Double] = [:],
        loadsAllPhotos: Bool = false,
        sortOptions: [PictureBrowserSort]? = nil,
        usesNavigationTitle: Bool = false,
        enablesVideoFilter: Bool = false
    ) {
        self.title = title
        self.sortOptions = sortOptions ?? (loadsAllPhotos ? [.dateTaken, .dateImported] : [.dateTaken, .confidence])
        self.usesNavigationTitle = usesNavigationTitle
        self.enablesVideoFilter = enablesVideoFilter || usesNavigationTitle
        _vm = StateObject(
            wrappedValue: PictureBrowserViewModel(
                photoIds: photoIds,
                confidenceByPhotoId: confidenceByPhotoId,
                loadsAllPhotos: loadsAllPhotos,
                enablesYearNavigation: usesNavigationTitle
            )
        )
    }

    var body: some View {
            VStack(spacing: 0) {
            if usesNavigationTitle {
                iconBar
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
                    guard let year = Self.focusedYear(from: frames) else { return }
                    guard vm.focusedYear != year else { return }
                    vm.focusedYear = year
                }
                .onChange(of: vm.pendingScrollYear) { _, year in
                    guard let year else { return }
                    scrollToYear(year, using: proxy)
                }
                .onChange(of: displayItems.count) { _, _ in
                    guard let year = vm.pendingScrollYear else { return }
                    scrollToYear(year, using: proxy)
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
        .task {
            await vm.load()
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
                sortMenu
                filterMenu
                selectButton
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
            return
        }
        withAnimation(.easeInOut(duration: 0.25)) {
            proxy.scrollTo(sectionId, anchor: .top)
        }
        vm.acknowledgePendingScrollYear()
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
                                    minY: geo.frame(in: .named("pictureBrowserScroll")).minY
                                ),
                            ]
                        )
                    }
                }
            }
    }

    /// Year of the month header currently pinned / nearest the top of the scroll view.
    private static func focusedYear(from frames: [PictureBrowserVisibleYear]) -> Int? {
        guard !frames.isEmpty else { return nil }
        let threshold: CGFloat = 8
        let scrolledPast = frames.filter { $0.minY <= threshold }
        if let active = scrolledPast.max(by: { $0.minY < $1.minY }) {
            return active.year
        }
        return frames.min(by: { $0.minY < $1.minY })?.year
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
                Text(title)
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

    private var headingTitle: String {
        guard usesNavigationTitle, vm.filter != .allItems else { return title }
        return "\(title) \(filterMenuTitle(vm.filter))"
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
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Button("Add to Frame") {
                    vm.setSelectedOnFrame(true)
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.selectedCount == 0)

                Button("Remove from Frame") {
                    vm.setSelectedOnFrame(false)
                }
                .buttonStyle(.bordered)
                .disabled(vm.selectedCount == 0)

                Button("Favorite") {
                    vm.setSelectedFavorite(true)
                }
                .buttonStyle(.bordered)
                .disabled(vm.selectedCount == 0)

                Button("Unfavorite") {
                    vm.setSelectedFavorite(false)
                }
                .buttonStyle(.bordered)
                .disabled(vm.selectedCount == 0)

                Button("Hide", role: .destructive) {
                    vm.setSelectedHidden(true)
                }
                .buttonStyle(.bordered)
                .disabled(vm.selectedCount == 0)

                Button("Unhide") {
                    vm.setSelectedHidden(false)
                }
                .buttonStyle(.bordered)
                .disabled(vm.selectedCount == 0)
            }
            .font(.subheadline)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.bar)
    }

    private var gridTaskKey: String {
        "\(vm.contentRevision)|\(vm.sort.rawValue)|\(vm.filter.rawValue)|\(vm.showHiddenPhotos)"
    }

    private func reloadDisplayItems() async {
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
