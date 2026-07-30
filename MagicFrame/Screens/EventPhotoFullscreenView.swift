import SwiftUI
import Photos
import UIKit

struct EventPhotoFullscreenView: View {

    private enum Layout {
        static let belowSafeAreaCloseOffset: CGFloat = 5
        static let closeButtonRowHeight: CGFloat = 44
        static let eventCounterRowHeight: CGFloat = 22
        static let belowTopChromeBuffer: CGFloat = 8
        /// Photo vertical inset — unchanged when top chrome moves.
        static let photoTopInset: CGFloat = 78
        static let actionBarHeight: CGFloat = 88
        static let belowPhotoSpacing: CGFloat = 14
        static let metricsSpacing: CGFloat = 10
        /// Reference portrait used to center landscapes: 3:4 width×height.
        static let referencePortraitAspect = CGSize(width: 3, height: 4)
    }

    private struct PhotoDisplayLayout {
        let displaySize: CGSize
        let topY: CGFloat

        var bottomY: CGFloat { topY + displaySize.height }
    }

    @ObservedObject var viewModel: EventDetailViewModel
    let initialDisplayIndex: Int
    let onDismiss: () -> Void

    @State private var currentDisplayIndex: Int
    @State private var similarPhotoIndexByGroupID: [String: Int] = [:]
    @State private var zoomStateByGroupID: [String: PhotoZoomState] = [:]

    init(
        viewModel: EventDetailViewModel,
        initialDisplayIndex: Int,
        onDismiss: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.initialDisplayIndex = initialDisplayIndex
        self.onDismiss = onDismiss
        _currentDisplayIndex = State(initialValue: initialDisplayIndex)
    }

    private var displayItems: [EventPhotoDisplayItem] {
        viewModel.fullscreenDisplayItems
    }

    private var currentItem: EventPhotoDisplayItem? {
        guard displayItems.indices.contains(currentDisplayIndex) else { return nil }
        return displayItems[currentDisplayIndex]
    }

    private var currentPhoto: IndexedPhoto? {
        guard let item = currentItem else { return nil }
        let ranked = rankedSimilarPhotos(for: item.group)
        let index = similarPhotoIndex(for: item.group, rankedPhotos: ranked)
        guard ranked.indices.contains(index) else { return nil }
        return ranked[index]
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

    var body: some View {
        GeometryReader { geometry in
            let photoTopInset = Layout.photoTopInset
            let photoZoneHeight = max(geometry.size.height - Layout.actionBarHeight, 0)
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
                           let photo = currentPhoto {
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
                                )
                            )
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
                                    photo: photo,
                                    layout: layout,
                                    zoneHeight: photoZoneHeight
                                )
                            }

                            topChromeOverlay(safeAreaTop: geometry.safeAreaInsets.top)
                        } else if displayItems.isEmpty {
                            ProgressView()
                                .tint(.white)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(height: photoZoneHeight)

                    bottomActionBar
                        .frame(height: Layout.actionBarHeight)
                }
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .onChange(of: displayItems.count) { _, newCount in
            if newCount == 0 {
                onDismiss()
                return
            }

            if currentDisplayIndex >= newCount {
                currentDisplayIndex = max(newCount - 1, 0)
            }
        }
        .onChange(of: displayItems.map(\.id)) { _, _ in
            if currentDisplayIndex >= displayItems.count {
                currentDisplayIndex = max(displayItems.count - 1, 0)
            }
        }
        .task(id: currentPhoto?.id) {
            guard let photoId = currentPhoto?.id else { return }
            await viewModel.analyzeFaceMetricsIfNeeded(for: photoId)
        }
        .task(priority: .background) {
            guard let item = currentItem, item.isStack else { return }
            await viewModel.prefetchFaceMetrics(for: item.group)
        }
    }

    @ViewBuilder
    private func stackControlsOverlay(
        item: EventPhotoDisplayItem,
        photo: IndexedPhoto,
        layout: PhotoDisplayLayout,
        zoneHeight: CGFloat
    ) -> some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: layout.bottomY + Layout.belowPhotoSpacing)
                .allowsHitTesting(false)

            similarPhotoNavigation(for: item.group)

            photoMetricsView(for: photo)
                .padding(.top, Layout.metricsSpacing)

            Spacer(minLength: 0)
                .allowsHitTesting(false)
        }
        .frame(height: zoneHeight)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var bottomActionBar: some View {
        if let item = currentItem, let photo = currentPhoto {
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
                    frameActionButtons(for: photo, in: item)
                }
            }
            .padding(.bottom, 20)
        }
    }

    @ViewBuilder
    private func topChromeOverlay(safeAreaTop: CGFloat) -> some View {
        VStack(spacing: 4) {
            HStack {
                Spacer()

                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(width: Layout.closeButtonRowHeight, height: Layout.closeButtonRowHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            .padding(.trailing, 10)

            eventGridCounterText
                .frame(maxWidth: .infinity)
                .frame(height: Layout.eventCounterRowHeight)
        }
        .padding(.top, safeAreaTop + Layout.belowSafeAreaCloseOffset)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var eventGridCounterText: some View {
        Text("\(min(currentDisplayIndex + 1, max(displayItems.count, 1))) of \(displayItems.count)")
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.85))
    }

    private func referencePortraitDisplayHeight(in fitBounds: CGSize) -> CGFloat {
        aspectFitDisplaySize(for: Layout.referencePortraitAspect, in: fitBounds).height
    }

    private func photoDisplayLayout(
        for photo: IndexedPhoto,
        photoTopInset: CGFloat,
        fitBounds: CGSize,
        referencePortraitHeight: CGFloat
    ) -> PhotoDisplayLayout {
        guard photo.width > 0, photo.height > 0, fitBounds.width > 0, fitBounds.height > 0 else {
            return PhotoDisplayLayout(displaySize: fitBounds, topY: photoTopInset)
        }

        let imageSize = CGSize(width: CGFloat(photo.width), height: CGFloat(photo.height))
        let displaySize = aspectFitDisplaySize(for: imageSize, in: fitBounds)
        let isPortrait = imageSize.height > imageSize.width
        let landscapeOffset = isPortrait
            ? 0
            : max((referencePortraitHeight - displaySize.height) * 0.5, 0)

        return PhotoDisplayLayout(
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
    private func frameActionButtons(for photo: IndexedPhoto, in item: EventPhotoDisplayItem) -> some View {
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
            let shouldDismiss = viewModel.hidePhoto(photoId: photo.id)
            if shouldDismiss {
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

    @ViewBuilder
    private var bottomStatusText: some View {
        if currentItem?.isStack != true {
            Text("\(min(currentDisplayIndex + 1, max(displayItems.count, 1))) of \(displayItems.count)")
        }
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

    private func rankedSimilarPhotos(for group: SimilarPhotoGroup) -> [IndexedPhoto] {
        group.rankedPhotos(resolvingFrom: viewModel.photos)
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
        guard !displayItems.isEmpty else { return }
        currentDisplayIndex = min(currentDisplayIndex + 1, displayItems.count - 1)
    }

    private func showPreviousGridPhoto() {
        guard !displayItems.isEmpty else { return }
        currentDisplayIndex = max(currentDisplayIndex - 1, 0)
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

    func makeUIViewController(context: Context) -> PhotoZoomViewController {
        let controller = PhotoZoomViewController()
        controller.onZoomStateChanged = { state in
            if state != zoomState {
                zoomState = state
            }
        }
        return controller
    }

    func updateUIViewController(_ controller: PhotoZoomViewController, context: Context) {
        controller.onZoomStateChanged = { state in
            if state != zoomState {
                zoomState = state
            }
        }

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
    }
}

// MARK: - UIKit photo zoom controller

private final class PhotoZoomViewController: UIViewController, UIScrollViewDelegate {

    var onZoomStateChanged: ((PhotoZoomState) -> Void)?

    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .large)

    private var loadedAssetIdentifier: String?
    private var loadedReloadToken = -1
    private var loadedGroupID: String?
    private var imageRequestID: PHImageRequestID?

    private var pendingZoomRestore: PhotoZoomState?
    private var isApplyingZoomState = false
    private var isNewAssetLoad = false

    private var photoTopInset: CGFloat = 0
    private var referencePortraitDisplayHeight: CGFloat = 0
    private var layoutImagePixelSize = CGSize.zero

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

        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true

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
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        guard scrollView.bounds.width > 0, scrollView.bounds.height > 0 else { return }

        if scrollView.zoomScale <= scrollView.minimumZoomScale + 0.001 {
            layoutAtMinimumZoom()
        }

        if let pendingZoomRestore, imageView.image != nil {
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
                let keepZoom = self.scrollView.zoomScale > self.scrollView.minimumZoomScale + 0.001
                if keepZoom {
                    self.pendingZoomRestore = self.currentZoomState()
                }
                self.setImage(image, isFinal: true)
            }
        }
    }

    private func setImage(_ image: UIImage, isFinal: Bool) {
        let wasZoomed = scrollView.zoomScale > scrollView.minimumZoomScale + 0.001

        imageView.image = image

        if isNewAssetLoad, pendingZoomRestore != nil {
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
            return
        }

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

        imageView.frame = CGRect(
            x: (boundsSize.width - displaySize.width) * 0.5,
            y: photoTopInset + landscapeOffset,
            width: displaySize.width,
            height: displaySize.height
        )
        scrollView.contentSize = boundsSize
    }

    private func resetToMinimumZoom(animated: Bool) {
        isApplyingZoomState = true
        scrollView.setZoomScale(scrollView.minimumZoomScale, animated: animated)
        scrollView.contentOffset = .zero
        layoutAtMinimumZoom()
        centerZoomedContents()
        isApplyingZoomState = false
        publishZoomState()
    }

    private func applyZoomState(_ state: PhotoZoomState, animated: Bool) {
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
        let boundsSize = scrollView.bounds.size
        let frame = imageView.frame
        let insetX = max((boundsSize.width - frame.width) * 0.5, 0)
        let atMinimumZoom = scrollView.zoomScale <= scrollView.minimumZoomScale + 0.001

        if atMinimumZoom {
            scrollView.contentInset = UIEdgeInsets(
                top: 0,
                left: insetX,
                bottom: 0,
                right: insetX
            )
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
        centerZoomedContents()
        publishZoomState()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        publishZoomState()
    }

    func scrollViewDidEndZooming(
        _ scrollView: UIScrollView,
        with view: UIView?,
        atScale scale: CGFloat
    ) {
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
