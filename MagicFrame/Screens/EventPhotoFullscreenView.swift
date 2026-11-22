import SwiftUI
import Photos
import UIKit

struct EventPhotoFullscreenView: View {

    @ObservedObject var viewModel: EventDetailViewModel
    let initialDisplayIndex: Int
    let onDismiss: () -> Void

    @State private var currentDisplayIndex: Int
    @State private var similarPhotoIndexByGroupID: [String: Int] = [:]
    @State private var zoomStateByGroupID: [String: PhotoZoomState] = [:]
    @State private var isAskingPhotoLibraryDelete = false
    @State private var pendingDeletePhotoId: String?
    @State private var pendingDeleteRemovesEvent = false
    @State private var photoLibraryError: String?

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
            let bottomChromeHeight = bottomOverlayHeight(for: currentItem)
            let photoHeight = max(geometry.size.height - bottomChromeHeight, 0)

            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    if let presentation = currentPhotoPresentation {
                        FullscreenPhotoView(
                            assetIdentifier: presentation.assetIdentifier,
                            reloadToken: presentation.reloadToken,
                            groupID: presentation.groupID,
                            zoomState: zoomBinding(for: presentation.groupID),
                            preserveZoomOnAssetChange: presentation.preserveZoomOnChange,
                            onClose: onDismiss
                        )
                        .id(presentation.groupID)
                        .frame(height: photoHeight)
                        .frame(maxWidth: .infinity, alignment: .top)
                        .clipped()
                        .simultaneousGesture(gridPageSwipeGesture(for: presentation))
                    } else if displayItems.isEmpty {
                        Spacer()
                        ProgressView()
                            .tint(.white)
                        Spacer()
                    }

                    bottomOverlay
                        .frame(height: bottomChromeHeight)
                }
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .confirmationDialog(
            "Delete from Photos?",
            isPresented: $isAskingPhotoLibraryDelete,
            titleVisibility: .visible
        ) {
            Button("Delete from Photos", role: .destructive) {
                finishPhotoDelete(alsoDeleteFromPhotos: true)
            }
            Button("Keep in Photos", role: .cancel) {
                finishPhotoDelete(alsoDeleteFromPhotos: false)
            }
        } message: {
            Text("Also delete this photo from the Photos app?")
        }
        .alert(
            "Couldn’t Delete from Photos",
            isPresented: Binding(
                get: { photoLibraryError != nil },
                set: { if !$0 { photoLibraryError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(photoLibraryError ?? "")
        }
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
    private var bottomOverlay: some View {
        if let item = currentItem, let photo = currentPhoto {
            if item.isStack {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)

                    photoMetricsView(for: photo)

                    Spacer(minLength: 0)

                    similarPhotoNavigation(for: item.group)

                    photoActionBar(for: photo)
                }
            } else {
                VStack(spacing: 12) {
                    Spacer(minLength: 0)

                    bottomStatusText

                    photoActionBar(for: photo)
                }
            }
        }
    }

    private func photoActionBar(for photo: IndexedPhoto) -> some View {
        SelectionFooterBar(
            isEnabled: true,
            isFrameOn: photo.showOnFrame,
            favoriteIcon: photo.isFavorite ? "heart.fill" : "heart",
            favoriteCaption: "Fav",
            hideIcon: "eye.slash",
            hideCaption: "Hide",
            onFrame: {
                viewModel.togglePhotoOnFrame(
                    photoId: photo.id,
                    in: currentItem?.isStack == true ? currentItem?.group : nil
                )
            },
            onFavorite: {
                viewModel.flagPhotoAsFavorite(photoId: photo.id)
            },
            onHide: {
                let shouldDismiss = viewModel.hidePhoto(photoId: photo.id)
                if shouldDismiss {
                    onDismiss()
                }
            },
            onDelete: {
                pendingDeletePhotoId = photo.id
                pendingDeleteRemovesEvent = viewModel.isOnlyPhotoInEvent(photo.id)
                isAskingPhotoLibraryDelete = true
            }
        ) {
            Button("Coming Soon") {}
        }
    }

    private func finishPhotoDelete(alsoDeleteFromPhotos: Bool) {
        guard let photoId = pendingDeletePhotoId else { return }
        let removesEvent = pendingDeleteRemovesEvent
        pendingDeletePhotoId = nil
        pendingDeleteRemovesEvent = false
        let shouldLeave = viewModel.softDeletePhoto(photoId, deletingEventIfEmpty: removesEvent)
        if alsoDeleteFromPhotos {
            Task {
                if let error = await PhotoLibraryDeletion.deleteAssets(localIdentifiers: [photoId]) {
                    photoLibraryError = error
                }
            }
        }
        if shouldLeave {
            onDismiss()
        }
    }

    private func bottomOverlayHeight(for item: EventPhotoDisplayItem?) -> CGFloat {
        guard let item else { return 0 }
        return item.isStack ? 300 : 148
    }

    @ViewBuilder
    private var bottomStatusText: some View {
        if currentItem?.isStack != true {
            Text("\(min(currentDisplayIndex + 1, max(displayItems.count, 1))) of \(displayItems.count)")
                .font(.subheadline)
                .foregroundStyle(.white)
        }
    }

    @ViewBuilder
    private func similarPhotoNavigation(for group: SimilarPhotoGroup) -> some View {
        let ranked = rankedSimilarPhotos(for: group)
        let index = similarPhotoIndex(for: group, rankedPhotos: ranked)

        HStack(spacing: 12) {
            Button {
                showPreviousSimilarPhoto(in: group, rankedPhotos: ranked)
            } label: {
                Image(systemName: "chevron.left.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .white.opacity(0.25))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Previous similar photo")

            Text("\(index + 1) of \(ranked.count) Similar Photos")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            Button {
                showNextSimilarPhoto(in: group, rankedPhotos: ranked)
            } label: {
                Image(systemName: "chevron.right.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .white.opacity(0.25))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Next similar photo")
        }
        .padding(.horizontal, 16)
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
    var onClose: () -> Void

    func makeUIViewController(context: Context) -> PhotoZoomViewController {
        let controller = PhotoZoomViewController()
        controller.onClose = onClose
        controller.onZoomStateChanged = { state in
            if state != zoomState {
                zoomState = state
            }
        }
        return controller
    }

    func updateUIViewController(_ controller: PhotoZoomViewController, context: Context) {
        controller.onClose = onClose
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
            fallbackZoom: zoomState
        )
    }
}

// MARK: - UIKit photo zoom controller

private final class PhotoZoomViewController: UIViewController, UIScrollViewDelegate {

    var onClose: (() -> Void)?
    var onZoomStateChanged: ((PhotoZoomState) -> Void)?

    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let closeButton = UIButton(type: .system)

    private var loadedAssetIdentifier: String?
    private var loadedReloadToken = -1
    private var loadedGroupID: String?
    private var imageRequestID: PHImageRequestID?

    private var pendingZoomRestore: PhotoZoomState?
    private var isApplyingZoomState = false
    private var isNewAssetLoad = false

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

        let closeImage = UIImage(systemName: "xmark.circle.fill")?
            .withConfiguration(UIImage.SymbolConfiguration(textStyle: .title2))
        closeButton.setImage(closeImage, for: .normal)
        closeButton.tintColor = .white
        closeButton.translatesAutoresizingMaskIntoConstraints = true
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.accessibilityLabel = "Close"

        view.addSubview(scrollView)
        scrollView.addSubview(imageView)
        view.addSubview(spinner)
        view.addSubview(closeButton)

        // Keep scroll view below the close button.
        let scrollTop = scrollView.topAnchor.constraint(equalTo: view.topAnchor)
        scrollTop.priority = .defaultHigh

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollTop,
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
    }

    @objc private func closeTapped() {
        onClose?()
    }

    private func layoutCloseButton() {
        let safeTop = view.safeAreaInsets.top > 0
            ? view.safeAreaInsets.top
            : (view.window?.safeAreaInsets.top ?? 47)
        let safeTrailing = view.safeAreaInsets.right > 0
            ? view.safeAreaInsets.right
            : (view.window?.safeAreaInsets.right ?? 0)

        let size: CGFloat = 44
        closeButton.frame = CGRect(
            x: view.bounds.width - safeTrailing - size - 10,
            y: safeTop + 6,
            width: size,
            height: size
        )
        view.bringSubviewToFront(closeButton)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        layoutCloseButton()

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

    func display(
        assetIdentifier: String,
        reloadToken: Int,
        groupID: String,
        preserveZoom: Bool,
        fallbackZoom: PhotoZoomState
    ) {
        guard assetIdentifier != loadedAssetIdentifier || reloadToken != loadedReloadToken else {
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

        let screenSize = UIScreen.main.bounds.size
        let screenScale = UIScreen.main.scale
        let previewSize = CGSize(
            width: screenSize.width * screenScale,
            height: screenSize.height * screenScale
        )

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

    private func layoutAtMinimumZoom() {
        imageView.frame = CGRect(origin: .zero, size: scrollView.bounds.size)
        scrollView.contentSize = scrollView.bounds.size
        scrollView.contentInset = .zero
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
        let insetY = max((boundsSize.height - frame.height) * 0.5, 0)
        scrollView.contentInset = UIEdgeInsets(top: insetY, left: insetX, bottom: insetY, right: insetX)
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
