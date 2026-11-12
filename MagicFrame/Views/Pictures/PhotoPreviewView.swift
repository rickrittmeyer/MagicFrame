import Photos
import SwiftUI
import UIKit

struct PhotoPreviewContext {
    let displayIndex: Int
    let displayCount: Int
    let item: EventPhotoDisplayItem
    let photo: IndexedPhoto
    /// True when the current photo is pinched/zoomed past 1×.
    let isZoomed: Bool
}

/// Close button and counter used by the shared preview. Callers can supply a different header.
struct PhotoPreviewStandardHeader: View {
    let index: Int
    let count: Int
    var showsCounter = true
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            .padding(.trailing, 10)

            if showsCounter {
                Text("\(min(index, max(count, 1))) of \(count)")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(maxWidth: .infinity)
                    .frame(height: 22)
            }
        }
    }
}

private enum PhotoPreviewLayout {
    static let belowSafeAreaCloseOffset: CGFloat = 5
    static let photoTopInset: CGFloat = 78
    static let actionBarHeight: CGFloat = 88
    static let belowPhotoSpacing: CGFloat = 14
    static let referencePortraitAspect = CGSize(width: 3, height: 4)
}

private struct PhotoPreviewDisplayLayout {
    let displaySize: CGSize
    let topY: CGFloat
    var bottomY: CGFloat { topY + displaySize.height }
}

/// Full-screen photo and video preview. Pinch and double-tap zoom, swipe between items,
/// and similar-photo stacks all live here. Headers and action buttons are supplied by the caller.
struct PhotoPreviewView<Header: View, Actions: View, Accessory: View>: View {

    let items: [EventPhotoDisplayItem]
    let resolvingPhotos: [IndexedPhoto]
    let initialPhotoId: String?
    var showsActionBar: Bool
    var dismissWhenEmpty: Bool
    let onDismiss: () -> Void
    let onPhotoVisible: (IndexedPhoto, EventPhotoDisplayItem) async -> Void
    @ViewBuilder let header: (PhotoPreviewContext) -> Header
    @ViewBuilder let actions: (PhotoPreviewContext) -> Actions
    @ViewBuilder let accessory: (PhotoPreviewContext) -> Accessory

    @State private var currentDisplayIndex: Int
    @State private var similarPhotoIndexByGroupID: [String: Int]
    @State private var zoomStateByGroupID: [String: PhotoZoomState] = [:]
    @State private var playingVideoId: String?
    @State private var didApplyInitialPhoto: Bool
    @State private var faceAnnotations: [PhotoFaceAnnotation] = []
    @State private var isScanningFaces = false
    /// Incremented to ask the zoom controller to return to 1×.
    @State private var unzoomRequestID = 0

    init(
        items: [EventPhotoDisplayItem],
        resolvingPhotos: [IndexedPhoto],
        initialIndex: Int,
        initialPhotoId: String? = nil,
        showsActionBar: Bool = true,
        dismissWhenEmpty: Bool = true,
        onDismiss: @escaping () -> Void,
        onPhotoVisible: @escaping (IndexedPhoto, EventPhotoDisplayItem) async -> Void = { _, _ in },
        @ViewBuilder header: @escaping (PhotoPreviewContext) -> Header,
        @ViewBuilder actions: @escaping (PhotoPreviewContext) -> Actions,
        @ViewBuilder accessory: @escaping (PhotoPreviewContext) -> Accessory
    ) {
        self.items = items
        self.resolvingPhotos = resolvingPhotos
        self.initialPhotoId = initialPhotoId
        self.showsActionBar = showsActionBar
        self.dismissWhenEmpty = dismissWhenEmpty
        self.onDismiss = onDismiss
        self.onPhotoVisible = onPhotoVisible
        self.header = header
        self.actions = actions
        self.accessory = accessory

        let start = Self.startingPosition(
            items: items,
            resolvingPhotos: resolvingPhotos,
            initialIndex: initialIndex,
            initialPhotoId: initialPhotoId
        )
        _currentDisplayIndex = State(initialValue: start.index)
        _similarPhotoIndexByGroupID = State(initialValue: start.similar)
        _didApplyInitialPhoto = State(initialValue: start.didApply)
    }

    private var currentItem: EventPhotoDisplayItem? {
        guard items.indices.contains(currentDisplayIndex) else { return nil }
        return items[currentDisplayIndex]
    }

    private var currentPhoto: IndexedPhoto? {
        guard let item = currentItem else { return nil }
        let ranked = rankedSimilarPhotos(for: item.group)
        let index = similarPhotoIndex(for: item.group, rankedPhotos: ranked)
        guard ranked.indices.contains(index) else { return nil }
        return ranked[index]
    }

    private var previewContext: PhotoPreviewContext? {
        guard let item = currentItem, let photo = currentPhoto else { return nil }
        return PhotoPreviewContext(
            displayIndex: currentDisplayIndex,
            displayCount: items.count,
            item: item,
            photo: photo,
            isZoomed: isPhotoZoomed
        )
    }

    private var currentPhotoPresentation: PhotoPresentation? {
        guard let item = currentItem else { return nil }
        let ranked = rankedSimilarPhotos(for: item.group)
        let index = similarPhotoIndex(for: item.group, rankedPhotos: ranked)
        guard ranked.indices.contains(index) else { return nil }

        return PhotoPresentation(
            assetIdentifier: ranked[index].id,
            reloadToken: index,
            groupID: item.group.id,
            preserveZoomOnChange: item.isStack
        )
    }

    private var isPhotoZoomed: Bool {
        guard let presentation = currentPhotoPresentation else { return false }
        let zoom = zoomStateByGroupID[presentation.groupID] ?? PhotoZoomState()
        return zoom.scale > 1.01
    }

    var body: some View {
        GeometryReader { geometry in
            let actionHeight: CGFloat = {
                if isPhotoZoomed { return PhotoPreviewLayout.actionBarHeight }
                return showsActionBar ? PhotoPreviewLayout.actionBarHeight : 0
            }()
            let photoTopInset = PhotoPreviewLayout.photoTopInset
            let photoZoneHeight = max(geometry.size.height - actionHeight, 0)
            let photoFitBounds = CGSize(
                width: geometry.size.width,
                height: max(photoZoneHeight - photoTopInset, 0)
            )
            let referencePortraitHeight = referencePortraitDisplayHeight(in: photoFitBounds)
            let imageLayout = currentPhoto.map {
                photoDisplayLayout(
                    for: $0,
                    photoTopInset: photoTopInset,
                    fitBounds: photoFitBounds,
                    referencePortraitHeight: referencePortraitHeight
                )
            }

            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    ZStack(alignment: .top) {
                        if let presentation = currentPhotoPresentation,
                           let photo = currentPhoto,
                           let context = previewContext {
                            Group {
                                if playingVideoId == photo.id {
                                    InlineVideoPlayer(assetIdentifier: photo.id)
                                } else {
                                    FullscreenPhotoView(
                                        assetIdentifier: presentation.assetIdentifier,
                                        reloadToken: presentation.reloadToken,
                                        groupID: presentation.groupID,
                                        zoomState: zoomBinding(for: presentation.groupID),
                                        preserveZoomOnAssetChange: presentation.preserveZoomOnChange,
                                        photoTopInset: photoTopInset,
                                        referencePortraitDisplayHeight: referencePortraitHeight,
                                        imagePixelSize: CGSize(
                                            width: CGFloat(photo.width),
                                            height: CGFloat(photo.height)
                                        ),
                                        faceAnnotations: faceAnnotations,
                                        unzoomRequestID: unzoomRequestID,
                                        onAssignFace: { faceId, displayName, firstName, lastName, maidenName in
                                            assignFaceName(
                                                faceInstanceId: faceId,
                                                photoId: photo.id,
                                                displayName: displayName,
                                                firstName: firstName,
                                                lastName: lastName,
                                                maidenName: maidenName
                                            )
                                        }
                                    )
                                    .overlay {
                                        VideoPlayButton(assetIdentifier: photo.id, iconSize: 72) {
                                            playingVideoId = photo.id
                                        }
                                    }
                                    .overlay(alignment: .top) {
                                        if isScanningFaces {
                                            ProgressView("Finding faces…")
                                                .tint(.white)
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 8)
                                                .background(.black.opacity(0.55), in: Capsule())
                                                .padding(.top, photoTopInset + 8)
                                        } else if faceAnnotations.isEmpty {
                                            Text("No faces found")
                                                .font(.caption.weight(.medium))
                                                .foregroundStyle(.white.opacity(0.85))
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 8)
                                                .background(.black.opacity(0.45), in: Capsule())
                                                .padding(.top, photoTopInset + 8)
                                        }
                                    }
                                }
                            }
                            .id(presentation.groupID)
                            .frame(height: photoZoneHeight)
                            .frame(maxWidth: .infinity, alignment: .top)
                            .clipped()
                            .simultaneousGesture(gridPageSwipeGesture(for: presentation))

                            if let item = currentItem,
                               item.isStack,
                               let layout = imageLayout {
                                stackControlsOverlay(
                                    item: item,
                                    context: context,
                                    layout: layout,
                                    zoneHeight: photoZoneHeight
                                )
                            }

                            header(context)
                                .padding(.top, geometry.safeAreaInsets.top + PhotoPreviewLayout.belowSafeAreaCloseOffset)
                                .frame(maxWidth: .infinity, alignment: .top)
                        } else if items.isEmpty {
                            ProgressView()
                                .tint(.white)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(height: photoZoneHeight)

                    if isPhotoZoomed {
                        unzoomActionBar()
                            .frame(maxWidth: .infinity)
                            .frame(height: PhotoPreviewLayout.actionBarHeight)
                    } else if showsActionBar, let context = previewContext {
                        actions(context)
                            .frame(maxWidth: .infinity)
                            .frame(height: PhotoPreviewLayout.actionBarHeight)
                    }
                }
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .onChange(of: items.map(\.id)) { _, _ in
            adoptItems()
        }
        .onChange(of: currentPhoto?.id) { _, _ in
            playingVideoId = nil
            faceAnnotations = []
            isScanningFaces = true
        }
        .task(id: currentPhoto?.id) {
            guard let photo = currentPhoto, let item = currentItem else { return }
            // Face overlays must not wait on metrics / other preview work.
            async let faces: Void = loadFaceAnnotations(for: photo.id)
            async let visible: Void = onPhotoVisible(photo, item)
            _ = await (faces, visible)
        }
    }

    private func loadFaceAnnotations(for photoId: String) async {
        isScanningFaces = true
        defer { isScanningFaces = false }
        let annotations = await AppDependencies.database.ensurePhotoFaceScanned(photoId: photoId)
        guard !Task.isCancelled, currentPhoto?.id == photoId else { return }
        faceAnnotations = annotations
    }

    private func assignFaceName(
        faceInstanceId: Int,
        photoId: String,
        displayName: String,
        firstName: String?,
        lastName: String?,
        maidenName: String?
    ) {
        _ = AppDependencies.database.nameFaceInstance(
            faceInstanceId: faceInstanceId,
            displayName: displayName,
            firstName: firstName,
            lastName: lastName,
            maidenName: maidenName
        )
        faceAnnotations = AppDependencies.database.fetchFaceAnnotations(forPhotoId: photoId)

        guard let group = currentItem?.group, group.isStack else { return }
        let siblingPhotoIds = group.photos.map(\.id).filter { $0 != photoId }
        guard !siblingPhotoIds.isEmpty else { return }
        Task {
            await AppDependencies.database.propagateNamedFaceToSimilarPhotos(
                sourceFaceInstanceId: faceInstanceId,
                siblingPhotoIds: siblingPhotoIds
            )
        }
    }

    @ViewBuilder
    private func stackControlsOverlay(
        item: EventPhotoDisplayItem,
        context: PhotoPreviewContext,
        layout: PhotoPreviewDisplayLayout,
        zoneHeight: CGFloat
    ) -> some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: layout.bottomY + PhotoPreviewLayout.belowPhotoSpacing)
                .allowsHitTesting(false)

            if !isPhotoZoomed {
                similarPhotoNavigation(for: item.group)
                accessory(context)
            }

            Spacer(minLength: 0)
                .allowsHitTesting(false)
        }
        .frame(height: zoneHeight)
        .frame(maxWidth: .infinity)
    }

    private func referencePortraitDisplayHeight(in fitBounds: CGSize) -> CGFloat {
        aspectFitDisplaySize(for: PhotoPreviewLayout.referencePortraitAspect, in: fitBounds).height
    }

    private func photoDisplayLayout(
        for photo: IndexedPhoto,
        photoTopInset: CGFloat,
        fitBounds: CGSize,
        referencePortraitHeight: CGFloat
    ) -> PhotoPreviewDisplayLayout {
        guard photo.width > 0, photo.height > 0, fitBounds.width > 0, fitBounds.height > 0 else {
            return PhotoPreviewDisplayLayout(displaySize: fitBounds, topY: photoTopInset)
        }

        let imageSize = CGSize(width: CGFloat(photo.width), height: CGFloat(photo.height))
        let displaySize = aspectFitDisplaySize(for: imageSize, in: fitBounds)
        let isPortrait = imageSize.height > imageSize.width
        let landscapeOffset = isPortrait
            ? 0
            : max((referencePortraitHeight - displaySize.height) * 0.5, 0)

        return PhotoPreviewDisplayLayout(
            displaySize: displaySize,
            topY: photoTopInset + landscapeOffset
        )
    }

    private func aspectFitDisplaySize(for imageSize: CGSize, in bounds: CGSize) -> CGSize {
        let fitScale = min(
            bounds.width / imageSize.width,
            bounds.height / imageSize.height
        )
        return CGSize(
            width: imageSize.width * fitScale,
            height: imageSize.height * fitScale
        )
    }

    @ViewBuilder
    private func similarPhotoNavigation(for group: SimilarPhotoGroup) -> some View {
        let ranked = rankedSimilarPhotos(for: group)
        let index = similarPhotoIndex(for: group, rankedPhotos: ranked)

        HStack(spacing: 8) {
            similarPhotoArrowButton(
                systemName: "chevron.left.circle.fill",
                accessibilityLabel: "Previous similar photo"
            ) {
                showPreviousSimilarPhoto(in: group, rankedPhotos: ranked)
            }

            Text("\(index + 1) of \(ranked.count) Similar Photos")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            similarPhotoArrowButton(
                systemName: "chevron.right.circle.fill",
                accessibilityLabel: "Next similar photo"
            ) {
                showNextSimilarPhoto(in: group, rankedPhotos: ranked)
            }
        }
        .padding(.horizontal, 12)
    }

    private func similarPhotoArrowButton(
        systemName: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.title2)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .white.opacity(0.25))
                .frame(width: 52, height: 52)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    private func rankedSimilarPhotos(for group: SimilarPhotoGroup) -> [IndexedPhoto] {
        group.rankedPhotos(resolvingFrom: resolvingPhotos)
    }

    private func similarPhotoIndex(
        for group: SimilarPhotoGroup,
        rankedPhotos: [IndexedPhoto]
    ) -> Int {
        guard !rankedPhotos.isEmpty else { return 0 }
        if let stored = similarPhotoIndexByGroupID[group.id] {
            return min(max(stored, 0), rankedPhotos.count - 1)
        }
        return 0
    }

    private func showPreviousSimilarPhoto(
        in group: SimilarPhotoGroup,
        rankedPhotos: [IndexedPhoto]
    ) {
        let current = similarPhotoIndex(for: group, rankedPhotos: rankedPhotos)
        similarPhotoIndexByGroupID[group.id] = max(current - 1, 0)
    }

    private func showNextSimilarPhoto(
        in group: SimilarPhotoGroup,
        rankedPhotos: [IndexedPhoto]
    ) {
        let current = similarPhotoIndex(for: group, rankedPhotos: rankedPhotos)
        similarPhotoIndexByGroupID[group.id] = min(current + 1, rankedPhotos.count - 1)
    }

    private func zoomBinding(for groupID: String) -> Binding<PhotoZoomState> {
        Binding(
            get: { zoomStateByGroupID[groupID] ?? PhotoZoomState() },
            set: { zoomStateByGroupID[groupID] = $0 }
        )
    }

    @ViewBuilder
    private func unzoomActionBar() -> some View {
        VStack(spacing: 6) {
            Spacer(minLength: 0)
            Button {
                unzoomRequestID += 1
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.title2)
                    Text("Zoom Out")
                        .font(.caption2)
                }
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Zoom out")
        }
        .padding(.bottom, 20)
    }

    private func gridPageSwipeGesture(for presentation: PhotoPresentation) -> some Gesture {
        DragGesture(minimumDistance: 40)
            .onEnded { value in
                let zoom = zoomStateByGroupID[presentation.groupID] ?? PhotoZoomState()
                guard zoom.scale <= 1.01 else { return }

                let horizontal = value.translation.width
                let vertical = value.translation.height
                guard abs(horizontal) > abs(vertical), abs(horizontal) > 60 else { return }

                if horizontal < 0 {
                    showNextGridPhoto()
                } else {
                    showPreviousGridPhoto()
                }
            }
    }

    private func showNextGridPhoto() {
        guard !items.isEmpty else { return }
        currentDisplayIndex = min(currentDisplayIndex + 1, items.count - 1)
    }

    private func showPreviousGridPhoto() {
        guard !items.isEmpty else { return }
        currentDisplayIndex = max(currentDisplayIndex - 1, 0)
    }

    private func adoptItems() {
        if !didApplyInitialPhoto {
            let start = Self.startingPosition(
                items: items,
                resolvingPhotos: resolvingPhotos,
                initialIndex: currentDisplayIndex,
                initialPhotoId: initialPhotoId
            )
            if start.didApply {
                currentDisplayIndex = start.index
                similarPhotoIndexByGroupID.merge(start.similar) { _, new in new }
                didApplyInitialPhoto = true
            }
        }

        if items.isEmpty {
            if dismissWhenEmpty {
                onDismiss()
            }
            return
        }

        if currentDisplayIndex >= items.count {
            currentDisplayIndex = max(items.count - 1, 0)
        }
    }

    private static func startingPosition(
        items: [EventPhotoDisplayItem],
        resolvingPhotos: [IndexedPhoto],
        initialIndex: Int,
        initialPhotoId: String?
    ) -> (index: Int, similar: [String: Int], didApply: Bool) {
        guard let initialPhotoId else {
            return (initialIndex, [:], true)
        }
        guard let index = items.firstIndex(where: { item in
            item.representative.id == initialPhotoId
                || item.group.photos.contains(where: { $0.id == initialPhotoId })
        }) else {
            return (initialIndex, [:], false)
        }

        let ranked = items[index].group.rankedPhotos(resolvingFrom: resolvingPhotos)
        var similar: [String: Int] = [:]
        if let similarIndex = ranked.firstIndex(where: { $0.id == initialPhotoId }) {
            similar[items[index].group.id] = similarIndex
        }
        return (index, similar, true)
    }
}

extension PhotoPreviewView where Accessory == EmptyView {
    init(
        items: [EventPhotoDisplayItem],
        resolvingPhotos: [IndexedPhoto],
        initialIndex: Int,
        initialPhotoId: String? = nil,
        showsActionBar: Bool = true,
        dismissWhenEmpty: Bool = true,
        onDismiss: @escaping () -> Void,
        onPhotoVisible: @escaping (IndexedPhoto, EventPhotoDisplayItem) async -> Void = { _, _ in },
        @ViewBuilder header: @escaping (PhotoPreviewContext) -> Header,
        @ViewBuilder actions: @escaping (PhotoPreviewContext) -> Actions
    ) {
        self.init(
            items: items,
            resolvingPhotos: resolvingPhotos,
            initialIndex: initialIndex,
            initialPhotoId: initialPhotoId,
            showsActionBar: showsActionBar,
            dismissWhenEmpty: dismissWhenEmpty,
            onDismiss: onDismiss,
            onPhotoVisible: onPhotoVisible,
            header: header,
            actions: actions,
            accessory: { _ in EmptyView() }
        )
    }
}

/// Event detail's full-screen preview. The photo UI is `PhotoPreviewView`; this only supplies
/// the event header, frame actions, and similar-photo scores.
struct EventPhotoFullscreenView: View {
    @ObservedObject var viewModel: EventDetailViewModel
    let initialDisplayIndex: Int
    let onDismiss: () -> Void

    var body: some View {
        PhotoPreviewView(
            items: viewModel.fullscreenDisplayItems,
            resolvingPhotos: viewModel.photos,
            initialIndex: initialDisplayIndex,
            onDismiss: onDismiss,
            onPhotoVisible: { photo, item in
                await viewModel.analyzeFaceMetricsIfNeeded(for: photo.id)
                if item.isStack {
                    await viewModel.prefetchFaceMetrics(for: item.group)
                }
            },
            header: { context in
                PhotoPreviewStandardHeader(
                    index: context.displayIndex + 1,
                    count: context.displayCount,
                    showsCounter: !context.isZoomed,
                    onClose: onDismiss
                )
            },
            actions: { context in
                eventActions(for: context)
            },
            accessory: { context in
                photoMetricsView(for: context.photo)
            }
        )
    }

    @ViewBuilder
    private func eventActions(for context: PhotoPreviewContext) -> some View {
        let photo = context.photo
        let item = context.item

        VStack(spacing: 6) {
            Spacer(minLength: 0)

            if let visionStatus = viewModel.visionLabelDebugStatus {
                Text(visionStatus)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 12)
            }

            HStack(spacing: 28) {
                Button {
                    viewModel.togglePhotoOnFrame(
                        photoId: photo.id,
                        in: item.isStack ? item.group : nil
                    )
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
                    if viewModel.hidePhoto(photoId: photo.id) {
                        onDismiss()
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "eye.slash")
                            .font(.title2)
                        Text("Hide")
                            .font(.caption2)
                    }
                    .foregroundStyle(.white)
                }

                Button {
                    viewModel.logVisionLabelsForPhoto(photo)
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "viewfinder")
                            .font(.title2)
                        Text("Vision")
                            .font(.caption2)
                    }
                    .foregroundStyle(.white)
                }
            }
        }
        .padding(.bottom, 20)
    }

    @ViewBuilder
    private func photoMetricsView(for photo: IndexedPhoto) -> some View {
        let isAnalyzing = viewModel.analyzingFaceMetricsPhotoIds.contains(photo.id)

        HStack(spacing: 28) {
            photoMetric(
                title: "Eyes Open",
                value: isAnalyzing ? "…" : formattedFaceScore(photo.faceEyesOpenScore)
            )
            photoMetric(
                title: "Smile",
                value: isAnalyzing ? "…" : formattedFaceScore(photo.faceSmileScore)
            )
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    private func photoMetric(title: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.7))
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
        }
    }

    private func formattedFaceScore(_ score: Double?) -> String {
        guard let score else { return "—" }
        return "\(Int((score * 100).rounded()))%"
    }
}

/// Loads photos by id, groups similar shots, and opens the shared preview.
struct FetchedPhotoPreview: View {
    let photoIds: [String]
    let initialPhotoId: String

    @Environment(\.dismiss) private var dismiss
    @State private var items: [EventPhotoDisplayItem] = []
    @State private var photos: [IndexedPhoto] = []

    var body: some View {
        Group {
            if items.isEmpty {
                ZStack {
                    Color.black.ignoresSafeArea()
                    ProgressView()
                        .tint(.white)
                    VStack {
                        PhotoPreviewStandardHeader(
                            index: 1,
                            count: 1,
                            showsCounter: false,
                            onClose: { dismiss() }
                        )
                        .padding(.top, 8)
                        Spacer()
                    }
                }
            } else {
                PhotoPreviewView(
                    items: items,
                    resolvingPhotos: photos,
                    initialIndex: 0,
                    initialPhotoId: initialPhotoId,
                    showsActionBar: false,
                    onDismiss: { dismiss() },
                    header: { context in
                        PhotoPreviewStandardHeader(
                            index: context.displayIndex + 1,
                            count: context.displayCount,
                            showsCounter: !context.isZoomed,
                            onClose: { dismiss() }
                        )
                    },
                    actions: { _ in
                        EmptyView()
                    }
                )
            }
        }
        .task {
            let ids = photoIds
            let records = AppDependencies.database.fetchPhotosForBrowser(photoIds: ids)
            let loaded = records.map(\.photo).sorted { $0.creationDate < $1.creationDate }
            let refined = await EventSimilarPhotoGrouper.refinedDisplayItems(from: loaded)
            guard !Task.isCancelled else { return }
            photos = loaded
            items = Array(refined.reversed())
        }
    }
}

private struct PhotoPresentation: Equatable {
    let assetIdentifier: String
    let reloadToken: Int
    let groupID: String
    let preserveZoomOnChange: Bool
}

private struct PhotoZoomState: Equatable {
    var scale: CGFloat = 1
    var contentOffset: CGPoint = .zero
}

// MARK: - SwiftUI bridge

private struct FullscreenPhotoView: UIViewControllerRepresentable {

    let assetIdentifier: String
    let reloadToken: Int
    let groupID: String
    @Binding var zoomState: PhotoZoomState
    var preserveZoomOnAssetChange: Bool
    var photoTopInset: CGFloat
    var referencePortraitDisplayHeight: CGFloat
    var imagePixelSize: CGSize
    var faceAnnotations: [PhotoFaceAnnotation]
    var unzoomRequestID: Int
    var onAssignFace: (
        _ faceInstanceId: Int,
        _ displayName: String,
        _ firstName: String?,
        _ lastName: String?,
        _ maidenName: String?
    ) -> Void

    func makeUIViewController(context: Context) -> PhotoZoomViewController {
        let controller = PhotoZoomViewController()
        controller.onZoomStateChanged = { state in
            if state != zoomState {
                zoomState = state
            }
        }
        controller.onAssignFace = onAssignFace
        return controller
    }

    func updateUIViewController(_ controller: PhotoZoomViewController, context: Context) {
        controller.onZoomStateChanged = { state in
            if state != zoomState {
                zoomState = state
            }
        }
        controller.onAssignFace = onAssignFace

        controller.display(
            assetIdentifier: assetIdentifier,
            reloadToken: reloadToken,
            groupID: groupID,
            preserveZoom: preserveZoomOnAssetChange,
            fallbackZoom: zoomState,
            photoTopInset: photoTopInset,
            referencePortraitDisplayHeight: referencePortraitDisplayHeight,
            imagePixelSize: imagePixelSize
        )
        controller.setFaceAnnotations(faceAnnotations)
        controller.handleUnzoomRequestIfNeeded(unzoomRequestID)
    }
}

// MARK: - Scroll view that won't keyboard-scroll while naming

/// UITextField inside a zooming UIScrollView triggers `scrollRectToVisible` when the
/// keyboard appears, which undoes our careful face pan (math lands correctly, then jumps).
private final class NamingFocusScrollView: UIScrollView {
    var blockScrollRectToVisible = false
    var onBlockedScrollRectToVisible: (() -> Void)?

    override func scrollRectToVisible(_ rect: CGRect, animated: Bool) {
        if blockScrollRectToVisible {
            onBlockedScrollRectToVisible?()
            return
        }
        super.scrollRectToVisible(rect, animated: animated)
    }
}

// MARK: - UIKit photo zoom controller

private final class PhotoZoomViewController: UIViewController, UIScrollViewDelegate {

    var onZoomStateChanged: ((PhotoZoomState) -> Void)?
    var onAssignFace: ((
        _ faceInstanceId: Int,
        _ displayName: String,
        _ firstName: String?,
        _ lastName: String?,
        _ maidenName: String?
    ) -> Void)?

    private let scrollView = NamingFocusScrollView()
    private let imageView = UIImageView()
    private let faceOverlayHost = PhotoFaceOverlayHost()
    private let spinner = UIActivityIndicatorView(style: .large)

    private var loadedAssetIdentifier: String?
    private var loadedReloadToken = -1
    private var loadedGroupID: String?
    private var imageRequestID: PHImageRequestID?

    private var pendingZoomRestore: PhotoZoomState?
    private var isApplyingZoomState = false
    private var isNewAssetLoad = false
    /// While naming, skip letterbox recentering so our contentOffset sticks.
    private var isPinnedForNaming = false
    private var lastHandledUnzoomRequestID = 0
    private var keyboardOverlapInScrollView: CGFloat = 0
    private var namingFocusFaceRect: CGRect = .zero
    private var namingFocusFaceInstanceId: Int?

    private var photoTopInset: CGFloat = 0
    private var referencePortraitDisplayHeight: CGFloat = 0
    private var layoutImagePixelSize = CGSize.zero
    /// Extra top padding baked into minimum-zoom contentInset (landscape letterbox under header).
    private var minimumZoomTopOffset: CGFloat = 0

    /// Face-center Y as a fraction of the visible photo band (below header, above keyboard).
    private static let namingFaceTargetYFraction: CGFloat = 0.18
    private static let namingFaceScreenHeight: CGFloat = 72
    /// Always zoom at least this much when naming (keeps us off the 1× layoutAtMinimumZoom path).
    private static let namingMinimumZoomScale: CGFloat = 1.35
    private static let defaultKeyboardOverlapEstimate: CGFloat = 336
    private static let namingStackBottomPadding: CGFloat = 12
    /// Set true while debugging naming zoom/pan; filter Xcode console for `[NamingFocus]`.
    private static let namingFocusDebugLogging = true

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = .clear
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.onBlockedScrollRectToVisible = { [weak self] in
            self?.namingFocusLog("BLOCKED scrollRectToVisible (keyboard auto-scroll)")
        }

        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        imageView.clipsToBounds = false

        faceOverlayHost.frame = imageView.bounds
        faceOverlayHost.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        faceOverlayHost.onAssign = { [weak self] faceId, display, first, last, maiden in
            self?.onAssignFace?(faceId, display, first, last, maiden)
            self?.resetToMinimumZoom(animated: true)
        }
        faceOverlayHost.onBeginEditingFace = { [weak self] faceId, faceRectInImage in
            self?.focusFaceForNaming(faceInstanceId: faceId, faceRectInImage: faceRectInImage)
        }
        faceOverlayHost.onEditingChromeNeedsRefocus = { [weak self] in
            self?.refocusNamingChromeIfNeeded()
        }
        imageView.addSubview(faceOverlayHost)

        spinner.color = .white
        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(scrollView)
        scrollView.addSubview(imageView)
        view.addSubview(spinner)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardFrameWillChange(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func setFaceAnnotations(_ faces: [PhotoFaceAnnotation]) {
        faceOverlayHost.frame = imageView.bounds
        faceOverlayHost.setFaces(faces)
        faceOverlayHost.updateZoomScale(scrollView.zoomScale)
    }

    func handleUnzoomRequestIfNeeded(_ requestID: Int) {
        guard requestID > 0, requestID != lastHandledUnzoomRequestID else { return }
        lastHandledUnzoomRequestID = requestID
        faceOverlayHost.endAllEditing()
        resetToMinimumZoom(animated: true)
    }

    /// Naming focus: zoom, then pan by measuring where the face actually is on screen.
    /// Do not use `faceMid * zoomScale` alone — after `setZoomScale`, UIScrollView's
    /// transform/frame layout means that formula is often wrong (works on some photos,
    /// misses left-edge faces on others).
    private func focusFaceForNaming(faceInstanceId: Int, faceRectInImage: CGRect) {
        guard faceRectInImage.width > 0, faceRectInImage.height > 0,
              imageView.bounds.width > 0, scrollView.bounds.width > 0 else { return }

        namingFocusFaceInstanceId = faceInstanceId
        namingFocusFaceRect = faceRectInImage
        applyNamingFocus(faceRectInImage: faceRectInImage)
    }

    private func refocusNamingChromeIfNeeded() {
        guard isPinnedForNaming else { return }
    }

    private func namingFocusLog(_ message: String) {
        guard Self.namingFocusDebugLogging else { return }
        // Single line only — Xcode filter "NamingFocus" drops continuation lines.
        print("[NamingFocus] \(message)")
    }

    /// Face center in the phone picture frame (0,0 = top-left of scrollView.frame).
    private func faceCenterInPictureFrame(_ faceRectInImage: CGRect) -> CGPoint? {
        guard let parent = scrollView.superview else { return nil }
        let point = CGPoint(x: faceRectInImage.midX, y: faceRectInImage.midY)
        let inParent = imageView.convert(point, to: parent)
        let viewer = scrollView.frame
        return CGPoint(x: inParent.x - viewer.minX, y: inParent.y - viewer.minY)
    }

    /// Content-space estimate of face center on screen: mid×zoom − contentOffset.
    private func faceCenterByContentMath(_ faceRectInImage: CGRect) -> CGPoint {
        let s = scrollView.zoomScale
        let o = scrollView.contentOffset
        return CGPoint(x: faceRectInImage.midX * s - o.x, y: faceRectInImage.midY * s - o.y)
    }

    /// Move contentOffset so the face center sits at `target` in picture-frame coords.
    private func panFaceCenter(_ faceRectInImage: CGRect, to target: CGPoint, pass: String) {
        let byConvert = faceCenterInPictureFrame(faceRectInImage)
        let byMath = faceCenterByContentMath(faceRectInImage)
        // Prefer convert when available; fall back to content math.
        let current = byConvert ?? byMath
        let before = scrollView.contentOffset
        var desired = before
        let dx = current.x - target.x
        let dy = current.y - target.y
        desired.x += dx
        desired.y += dy
        let minX = -scrollView.contentInset.left
        let maxX = maxHorizontalOffset()
        let minY = -scrollView.contentInset.top
        let maxY = maxVerticalOffset()
        let clamped = clampedContentOffset(desired)
        scrollView.contentOffset = clamped
        let afterConvert = faceCenterInPictureFrame(faceRectInImage)
        let afterMath = faceCenterByContentMath(faceRectInImage)
        namingFocusLog("\(pass) mid=(\(String(format: "%.1f", faceRectInImage.midX)),\(String(format: "%.1f", faceRectInImage.midY))) zoom=\(String(format: "%.3f", scrollView.zoomScale)) contentSize=\(scrollView.contentSize) imageFrame=\(imageView.frame) target=\(target) convertBefore=\(String(describing: byConvert)) mathBefore=\(byMath) dx=\(String(format: "%.1f", dx)) dy=\(String(format: "%.1f", dy)) offBefore=\(before) desired=\(desired) clampX=[\(String(format: "%.1f", minX)),\(String(format: "%.1f", maxX))] clamped=\(clamped != desired) offAfter=\(clamped) convertAfter=\(String(describing: afterConvert)) mathAfter=\(afterMath)")
    }

    private func applyNamingFocus(faceRectInImage: CGRect) {
        let viewerW = scrollView.bounds.width
        let viewerH = scrollView.bounds.height
        guard viewerW > 0, viewerH > 0 else { return }

        let heightScale = Self.namingFaceScreenHeight / max(faceRectInImage.height, 1)
        let maxWidthScale = (viewerW * 0.70) / max(faceRectInImage.width, 1)
        let scale = min(
            scrollView.maximumZoomScale,
            max(Self.namingMinimumZoomScale, min(heightScale, maxWidthScale))
        )

        let bandTop = photoTopInset + 8
        let keyboard = min(Self.defaultKeyboardOverlapEstimate, viewerH * 0.40)
        let bandBottom = max(bandTop + 120, viewerH - keyboard - Self.namingStackBottomPadding)
        let target = CGPoint(
            x: viewerW * 0.5,
            y: bandTop + (bandBottom - bandTop) * Self.namingFaceTargetYFraction
        )

        namingFocusLog("START viewer=(\(viewerW)x\(viewerH)) insetTop=\(photoTopInset) face=\(faceRectInImage) heightScale=\(String(format: "%.3f", heightScale)) maxWScale=\(String(format: "%.3f", maxWidthScale)) scale=\(String(format: "%.3f", scale)) band=[\(String(format: "%.1f", bandTop)),\(String(format: "%.1f", bandBottom))] target=\(target)")

        isApplyingZoomState = true
        pendingZoomRestore = nil

        isPinnedForNaming = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        scrollView.setZoomScale(scrollView.minimumZoomScale, animated: false)
        layoutAtMinimumZoom()
        centerZoomedContents()
        scrollView.layoutIfNeeded()

        // Large insets so edge faces can sit at screen center (negative contentOffset).
        isPinnedForNaming = true
        scrollView.blockScrollRectToVisible = true
        let pad: CGFloat = 100
        scrollView.contentInset = UIEdgeInsets(
            top: target.y + Self.namingFaceScreenHeight + pad,
            left: viewerW * 0.5 + pad,
            bottom: max(viewerH - bandBottom, 0) + pad,
            right: viewerW * 0.5 + pad
        )

        // Zoom around viewport center first (UIScrollView default) — face may go off-screen.
        scrollView.setZoomScale(scale, animated: false)
        scrollView.layoutIfNeeded()
        namingFocusLog("afterZoom zoom=\(String(format: "%.3f", scrollView.zoomScale)) offset=\(scrollView.contentOffset) convert=\(String(describing: faceCenterInPictureFrame(faceRectInImage))) math=\(faceCenterByContentMath(faceRectInImage))")

        // One synchronous measure-pan only. An async re-pan during keyboard layout
        // was a likely cause of sometimes-too-left / sometimes-too-right.
        panFaceCenter(faceRectInImage, to: target, pass: "pass1")
        scrollView.layoutIfNeeded()
        panFaceCenter(faceRectInImage, to: target, pass: "pass2")

        CATransaction.commit()

        faceOverlayHost.updateZoomScale(scrollView.zoomScale)
        isApplyingZoomState = false
        publishZoomState()

        // Read-only: detect drift after keyboard/layout (does not pan).
        let face = faceRectInImage
        let targetCopy = target
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self, self.isPinnedForNaming else { return }
            let convert = self.faceCenterInPictureFrame(face)
            let math = self.faceCenterByContentMath(face)
            let errX = (convert ?? math).x - targetCopy.x
            let errY = (convert ?? math).y - targetCopy.y
            self.namingFocusLog("postKeyboard offset=\(self.scrollView.contentOffset) convert=\(String(describing: convert)) math=\(math) err=(\(String(format: "%.1f", errX)),\(String(format: "%.1f", errY))) zoom=\(String(format: "%.3f", self.scrollView.zoomScale))")
        }
    }

    private func clampedContentOffset(_ offset: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(offset.x, -scrollView.contentInset.left), maxHorizontalOffset()),
            y: min(max(offset.y, -scrollView.contentInset.top), maxVerticalOffset())
        )
    }

    @objc private func keyboardFrameWillChange(_ notification: Notification) {
        guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
            return
        }
        let frameInView = view.convert(frame, from: nil)
        let overlap = max(0, scrollView.bounds.maxY - scrollView.convert(frameInView, from: view).minY)
        keyboardOverlapInScrollView = overlap
        // Intentionally no pan/zoom while naming. First settle already used a keyboard estimate.
        // Changing insets or re-fitting here was the "lands right then jumps wrong" bug.
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        guard scrollView.bounds.width > 0, scrollView.bounds.height > 0 else { return }

        // While naming, never run layoutAtMinimumZoom — resetting contentSize
        // collapses contentOffset and puts left-edge name fields back off-screen.
        if !isPinnedForNaming,
           scrollView.zoomScale <= scrollView.minimumZoomScale + 0.001 {
            layoutAtMinimumZoom()
            centerZoomedContents()
        }

        // Never restore a stale zoom while naming — that was overwriting the face pan.
        if isPinnedForNaming {
            pendingZoomRestore = nil
        } else if let pendingZoomRestore, imageView.image != nil {
            applyZoomState(pendingZoomRestore, animated: false)
            self.pendingZoomRestore = nil
            isNewAssetLoad = false
        }
    }

    private func previewTargetPixelSize() -> CGSize {
        let scale = view.traitCollection.displayScale
        let bounds = view.bounds.size
        if bounds.width > 1, bounds.height > 1 {
            return CGSize(width: bounds.width * scale, height: bounds.height * scale)
        }
        if let screen = view.window?.windowScene?.screen {
            return CGSize(
                width: screen.bounds.width * screen.scale,
                height: screen.bounds.height * screen.scale
            )
        }
        return CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }

    func display(
        assetIdentifier: String,
        reloadToken: Int,
        groupID: String,
        preserveZoom: Bool,
        fallbackZoom: PhotoZoomState,
        photoTopInset: CGFloat,
        referencePortraitDisplayHeight: CGFloat,
        imagePixelSize: CGSize
    ) {
        let layoutChanged =
            self.photoTopInset != photoTopInset
            || self.referencePortraitDisplayHeight != referencePortraitDisplayHeight
            || self.layoutImagePixelSize != imagePixelSize

        self.photoTopInset = photoTopInset
        self.referencePortraitDisplayHeight = referencePortraitDisplayHeight
        self.layoutImagePixelSize = imagePixelSize

        let assetChanged = assetIdentifier != loadedAssetIdentifier || reloadToken != loadedReloadToken
        guard assetChanged || layoutChanged else { return }

        if !assetChanged, layoutChanged, imageView.image != nil {
            if scrollView.zoomScale <= scrollView.minimumZoomScale + 0.001 {
                layoutAtMinimumZoom()
                centerZoomedContents()
            }
            return
        }

        let isSameGroup = groupID == loadedGroupID
        let shouldPreserveZoom = preserveZoom && isSameGroup

        if shouldPreserveZoom {
            if scrollView.zoomScale > scrollView.minimumZoomScale + 0.001 {
                pendingZoomRestore = currentZoomState()
            } else if fallbackZoom.scale > scrollView.minimumZoomScale + 0.001 {
                pendingZoomRestore = fallbackZoom
            }
        } else {
            pendingZoomRestore = nil
            resetToMinimumZoom(animated: false)
        }

        isNewAssetLoad = true
        cancelImageRequest()
        loadedAssetIdentifier = assetIdentifier
        loadedReloadToken = reloadToken
        loadedGroupID = groupID
        faceOverlayHost.endAllEditing()

        spinner.startAnimating()

        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetIdentifier], options: nil)
        guard let asset = assets.firstObject else {
            spinner.stopAnimating()
            return
        }

        let previewSize = previewTargetPixelSize()

        let fastOptions = PHImageRequestOptions()
        fastOptions.deliveryMode = .opportunistic
        fastOptions.resizeMode = .fast
        fastOptions.isNetworkAccessAllowed = true

        PHImageManager.default().requestImage(
            for: asset,
            targetSize: previewSize,
            contentMode: .aspectFit,
            options: fastOptions
        ) { [weak self] image, info in
            guard let self, let image else { return }
            guard self.loadedAssetIdentifier == assetIdentifier else { return }

            let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            DispatchQueue.main.async {
                self.setImage(image, isFinal: !isDegraded)
            }
        }

        let highQualityOptions = PHImageRequestOptions()
        highQualityOptions.deliveryMode = .highQualityFormat
        highQualityOptions.resizeMode = .none
        highQualityOptions.isNetworkAccessAllowed = true

        imageRequestID = PHImageManager.default().requestImage(
            for: asset,
            targetSize: PHImageManagerMaximumSize,
            contentMode: .aspectFit,
            options: highQualityOptions
        ) { [weak self] image, _ in
            guard let self, let image else { return }
            guard self.loadedAssetIdentifier == assetIdentifier else { return }

            DispatchQueue.main.async {
                // Don't queue a zoom restore while naming — layout would reapply it
                // and wipe the face pan.
                if !self.isPinnedForNaming {
                    let keepZoom = self.scrollView.zoomScale > self.scrollView.minimumZoomScale + 0.001
                    if keepZoom {
                        self.pendingZoomRestore = self.currentZoomState()
                    }
                }
                self.setImage(image, isFinal: true)
            }
        }
    }

    private func setImage(_ image: UIImage, isFinal: Bool) {
        let wasZoomed = scrollView.zoomScale > scrollView.minimumZoomScale + 0.001

        imageView.image = image

        if isPinnedForNaming {
            // Naming owns zoom/pan — only swap pixels.
        } else if isNewAssetLoad, pendingZoomRestore != nil {
            resetToMinimumZoom(animated: false)
            view.setNeedsLayout()
            view.layoutIfNeeded()
        } else if wasZoomed {
            // Quality upgrade while zoomed — only swap pixels, keep scroll state.
        } else {
            resetToMinimumZoom(animated: false)
        }

        if isFinal {
            spinner.stopAnimating()
        }
    }

    private func cancelImageRequest() {
        if let imageRequestID {
            PHImageManager.default().cancelImageRequest(imageRequestID)
            self.imageRequestID = nil
        }
    }

    private func layoutImageSize() -> CGSize {
        if layoutImagePixelSize.width > 0, layoutImagePixelSize.height > 0 {
            return layoutImagePixelSize
        }
        if let image = imageView.image,
           image.size.width > 0,
           image.size.height > 0 {
            return image.size
        }
        return .zero
    }

    private func layoutAtMinimumZoom() {
        guard scrollView.bounds.width > 0, scrollView.bounds.height > 0 else { return }

        let boundsSize = scrollView.bounds.size
        let imageSize = layoutImageSize()

        guard imageSize.width > 0, imageSize.height > 0 else {
            imageView.frame = CGRect(origin: .zero, size: boundsSize)
            scrollView.contentSize = boundsSize
            scrollView.contentInset = .zero
            minimumZoomTopOffset = 0
            return
        }

        // Fit in the area below the header; letterbox via contentInset (not frame.origin)
        // so UIScrollView zoom math stays standard: contentSize == image size, origin at 0.
        let availableHeight = max(boundsSize.height - photoTopInset, 0)
        let fitBounds = CGSize(width: boundsSize.width, height: availableHeight)
        let fitScale = min(
            fitBounds.width / imageSize.width,
            fitBounds.height / imageSize.height
        )
        let displaySize = CGSize(
            width: imageSize.width * fitScale,
            height: imageSize.height * fitScale
        )
        let isPortrait = imageSize.height > imageSize.width
        let landscapeOffset = isPortrait
            ? 0
            : max((referencePortraitDisplayHeight - displaySize.height) * 0.5, 0)
        minimumZoomTopOffset = photoTopInset + landscapeOffset

        imageView.frame = CGRect(origin: .zero, size: displaySize)
        faceOverlayHost.frame = imageView.bounds
        faceOverlayHost.updateZoomScale(scrollView.zoomScale)
        scrollView.contentSize = displaySize
    }

    private func resetToMinimumZoom(animated: Bool) {
        isPinnedForNaming = false
        scrollView.blockScrollRectToVisible = false
        namingFocusFaceRect = .zero
        namingFocusFaceInstanceId = nil
        keyboardOverlapInScrollView = 0
        isApplyingZoomState = true
        scrollView.setZoomScale(scrollView.minimumZoomScale, animated: animated)
        layoutAtMinimumZoom()
        centerZoomedContents()
        isApplyingZoomState = false
        publishZoomState()
    }

    private func applyZoomState(_ state: PhotoZoomState, animated: Bool) {
        // Naming owns zoom/pan until unzoom/assign.
        guard !isPinnedForNaming else { return }

        isApplyingZoomState = true

        let targetScale = min(
            max(state.scale, scrollView.minimumZoomScale),
            scrollView.maximumZoomScale
        )

        scrollView.setZoomScale(scrollView.minimumZoomScale, animated: false)
        layoutAtMinimumZoom()
        scrollView.setZoomScale(targetScale, animated: animated)
        centerZoomedContents()

        let maxX = maxHorizontalOffset()
        let maxY = maxVerticalOffset()
        let offset = CGPoint(
            x: min(max(state.contentOffset.x, -scrollView.contentInset.left), maxX),
            y: min(max(state.contentOffset.y, -scrollView.contentInset.top), maxY)
        )
        scrollView.setContentOffset(offset, animated: animated)
        centerZoomedContents()

        isApplyingZoomState = false
        publishZoomState()
    }

    private func currentZoomState() -> PhotoZoomState {
        PhotoZoomState(
            scale: scrollView.zoomScale,
            contentOffset: scrollView.contentOffset
        )
    }

    private func publishZoomState() {
        guard !isApplyingZoomState else { return }
        onZoomStateChanged?(currentZoomState())
    }

    private func centerZoomedContents() {
        // While naming, leave insets/offset alone — applyNamingFocus owns them.
        if isPinnedForNaming { return }

        let boundsSize = scrollView.bounds.size
        let frame = imageView.frame
        let insetX = max((boundsSize.width - frame.width) * 0.5, 0)
        let atMinimumZoom = scrollView.zoomScale <= scrollView.minimumZoomScale + 0.001

        if atMinimumZoom {
            let top = minimumZoomTopOffset
            let bottom = max(boundsSize.height - top - frame.height, 0)
            scrollView.contentInset = UIEdgeInsets(
                top: top,
                left: insetX,
                bottom: bottom,
                right: insetX
            )
            // Show the image under the header / centered horizontally.
            scrollView.contentOffset = CGPoint(x: -insetX, y: -top)
        } else {
            let insetY = max((boundsSize.height - frame.height) * 0.5, 0)
            scrollView.contentInset = UIEdgeInsets(
                top: insetY,
                left: insetX,
                bottom: insetY,
                right: insetX
            )
        }
    }

    private func maxHorizontalOffset() -> CGFloat {
        max(
            scrollView.contentSize.width - scrollView.bounds.width + scrollView.contentInset.right,
            -scrollView.contentInset.left
        )
    }

    private func maxVerticalOffset() -> CGFloat {
        max(
            scrollView.contentSize.height - scrollView.bounds.height + scrollView.contentInset.bottom,
            -scrollView.contentInset.top
        )
    }

    private func clampZoomScale(_ scrollView: UIScrollView) {
        if scrollView.zoomScale < scrollView.minimumZoomScale {
            scrollView.zoomScale = scrollView.minimumZoomScale
        }
    }

    // MARK: UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        clampZoomScale(scrollView)
        // Skip inset/offset fighting while applyNamingFocus drives zoom+pan.
        guard !isApplyingZoomState else {
            faceOverlayHost.updateZoomScale(scrollView.zoomScale)
            return
        }
        centerZoomedContents()
        faceOverlayHost.updateZoomScale(scrollView.zoomScale)
        publishZoomState()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isApplyingZoomState else { return }
        if isPinnedForNaming {
            namingFocusLog("didScroll offset=\(scrollView.contentOffset) convert=\(String(describing: namingFocusFaceRect.width > 0 ? faceCenterInPictureFrame(namingFocusFaceRect) : nil))")
        }
        publishZoomState()
    }

    func scrollViewDidEndZooming(
        _ scrollView: UIScrollView,
        with view: UIView?,
        atScale scale: CGFloat
    ) {
        guard !isApplyingZoomState else { return }
        if scrollView.zoomScale < scrollView.minimumZoomScale {
            resetToMinimumZoom(animated: true)
        } else {
            centerZoomedContents()
            publishZoomState()
        }
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        if scrollView.zoomScale > scrollView.minimumZoomScale + 0.001 {
            pendingZoomRestore = nil
            resetToMinimumZoom(animated: true)
            return
        }

        let point = recognizer.location(in: imageView)
        let targetScale: CGFloat = 2.5
        let size = CGSize(
            width: scrollView.bounds.width / targetScale,
            height: scrollView.bounds.height / targetScale
        )
        let zoomRect = CGRect(
            x: point.x - size.width * 0.5,
            y: point.y - size.height * 0.5,
            width: size.width,
            height: size.height
        )
        scrollView.zoom(to: zoomRect, animated: true)
    }
}
