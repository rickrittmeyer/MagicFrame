//
//  PhotoThumbnailView.swift
//  MagicFrame
//

import SwiftUI
import Photos

struct PhotoThumbnailView: View {
    enum Quality {
        case fast
        case high
    }

    /// When set, portrait photos use persisted face-aware crop for that surface.
    enum CropContext {
        case eventList
        case frame
    }

    let assetIdentifier: String
    var cornerRadius: CGFloat = 8
    var enforceSquareAspect: Bool = true
    var quality: Quality = .fast
    var cropContext: CropContext? = nil
    /// When false, only applies persisted crop data (no Vision analysis). Use for scrolling lists.
    var analyzesFacesIfMissing: Bool = false
    /// Explicit focal point (top-left normalized). Overrides `cropContext` when set.
    var normalizedCropFocus: CGPoint? = nil
    /// White play glyph on videos. Turn off when a parent already draws that button.
    var showsVideoBadge: Bool = true
    /// Known video flag from the database. When nil, the thumbnail checks the photo library.
    var isVideo: Bool? = nil

    @Environment(\.displayScale) private var displayScale

    @State private var image: UIImage?
    @State private var loadedTargetSize: CGSize = .zero
    @State private var loadedQuality: Quality?
    @State private var resolvedCropFocus: CGPoint?
    @State private var detectedIsVideo = false

    var body: some View {
        Group {
            if enforceSquareAspect {
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay { imageLayer }
                    .background(sizeReader)
            } else {
                // Fill the parent (e.g. 4:3 event banner). Avoid Color.clear + infinity,
                // which can report a zero size in LazyVStack and skip thumbnail loads.
                Rectangle()
                    .fill(Color(.systemGray5))
                    .overlay { imageLayer }
                    .background(sizeReader)
            }
        }
        .overlay {
            if showsPlayIcon {
                VideoPlayIcon(size: 36)
                    .allowsHitTesting(false)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .onAppear {
            restoreCachedImageIfNeeded()
        }
        .task(id: cropLoadTaskKey) {
            guard cropContext != nil else { return }
            await resolveCropFocusIfNeeded()
        }
    }

    private var showsPlayIcon: Bool {
        guard showsVideoBadge else { return false }
        return isVideo ?? detectedIsVideo
    }

    private var fastCacheKey: String {
        PhotoThumbnailImageCache.key(assetIdentifier: assetIdentifier, quality: "fast")
    }

    private var highCacheKey: String {
        PhotoThumbnailImageCache.key(assetIdentifier: assetIdentifier, quality: "high")
    }

    private var thumbnailCacheKey: String {
        quality == .high ? highCacheKey : fastCacheKey
    }

    @MainActor
    private func restoreCachedImageIfNeeded() {
        // Prefer a sharp cached frame when available (even if the row asked for .fast).
        if let high = PhotoThumbnailImageCache.image(for: highCacheKey) {
            image = high
            loadedQuality = .high
            return
        }
        guard image == nil, let fast = PhotoThumbnailImageCache.image(for: fastCacheKey) else {
            return
        }
        image = fast
        loadedQuality = .fast
    }

    private var usesCustomCrop: Bool {
        normalizedCropFocus != nil || resolvedCropFocus != nil
    }

    private var cropLoadTaskKey: String {
        let contextKey = cropContext.map { "\($0)" } ?? "none"
        return "\(assetIdentifier)|\(contextKey)"
    }

    private var effectiveCropFocus: CGPoint? {
        normalizedCropFocus ?? resolvedCropFocus
    }

    @ViewBuilder
    private var imageLayer: some View {
        if let image {
            GeometryReader { geometry in
                let focus = effectiveCropFocus
                if let focus {
                    let pan = PhotoCropCalculator.fillOffset(
                        imageSize: image.size,
                        containerSize: geometry.size,
                        focus: focus
                    )
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .offset(x: pan.width, y: pan.height)
                } else {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
        } else {
            Rectangle()
                .fill(Color(.systemGray5))
        }
    }

    private var sizeReader: some View {
        GeometryReader { geometry in
            Color.clear
                .task(id: loadTaskKey(for: geometry.size)) {
                    await loadThumbnail(for: geometry.size)
                }
        }
    }

    private func loadTaskKey(for size: CGSize) -> String {
        let pixelWidth = Int(size.width * displayScale)
        let pixelHeight = Int(size.height * displayScale)
        return "\(assetIdentifier)|\(quality)|\(pixelWidth)x\(pixelHeight)"
    }

    @MainActor
    private func loadThumbnail(for size: CGSize) async {
        restoreCachedImageIfNeeded()
        if isVideo == nil, image != nil {
            detectedIsVideo = PhotoAssetKind.isVideo(assetIdentifier: assetIdentifier)
        }

        // Ignore collapse/layout passes during navigation transitions.
        guard size.width > 1, size.height > 1 else { return }

        if cropContext != nil, effectiveCropFocus == nil {
            await resolveCropFocusIfNeeded()
        }

        let targetSize = CGSize(
            width: size.width * displayScale,
            height: size.height * displayScale
        )

        // Keep a sharp frame while the list temporarily asks for .fast during scroll.
        if quality == .fast, loadedQuality == .high, image != nil {
            return
        }

        // Already have a matching-quality frame at a similar size.
        if loadedQuality == quality, let image, loadedTargetSize.width > 10 {
            let widthRatio = targetSize.width / loadedTargetSize.width
            if image.size.width > 0, widthRatio > 0.75, widthRatio < 1.35 {
                return
            }
        }

        if targetSize == loadedTargetSize, loadedQuality == quality, image != nil {
            return
        }

        // Fast path satisfied by cache — still allow .high to upgrade below.
        if quality == .fast, loadedQuality == .fast, image != nil {
            return
        }

        let identifier = assetIdentifier

        let asset = await Task.detached(priority: .utility) {
            PHAsset.fetchAssets(
                withLocalIdentifiers: [identifier],
                options: nil
            ).firstObject
        }.value

        guard let asset else { return }
        if isVideo == nil {
            detectedIsVideo = asset.mediaType == .video
        }

        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        let requestQuality = quality

        switch requestQuality {
        case .fast:
            options.deliveryMode = .fastFormat
            options.resizeMode = .fast
            await requestImage(
                for: asset,
                targetSize: targetSize,
                options: options,
                waitForFinalQuality: false,
                requestedQuality: requestQuality
            )
        case .high:
            // Keep the current (possibly fast) image visible until high delivers.
            options.deliveryMode = .opportunistic
            options.resizeMode = .exact
            await requestImage(
                for: asset,
                targetSize: targetSize,
                options: options,
                waitForFinalQuality: true,
                requestedQuality: requestQuality
            )
        }
    }

    @MainActor
    private func requestImage(
        for asset: PHAsset,
        targetSize: CGSize,
        options: PHImageRequestOptions,
        waitForFinalQuality: Bool,
        requestedQuality: Quality
    ) async {
        final class RequestSession: @unchecked Sendable {
            var requestID = PHImageRequestID(PHInvalidImageRequestID)
            var deliveredImage = false
        }
        let session = RequestSession()
        let cacheKey = requestedQuality == .high ? highCacheKey : fastCacheKey

        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                final class ResumeGate: @unchecked Sendable {
                    private let lock = NSLock()
                    private var resumed = false
                    private let continuation: CheckedContinuation<Void, Never>

                    init(_ continuation: CheckedContinuation<Void, Never>) {
                        self.continuation = continuation
                    }

                    func resumeOnce() {
                        lock.lock()
                        defer { lock.unlock() }
                        guard !resumed else { return }
                        resumed = true
                        continuation.resume()
                    }
                }

                let gate = ResumeGate(continuation)

                let contentMode: PHImageContentMode = usesCustomCrop ? .aspectFit : .aspectFill

                session.requestID = PHImageManager.default().requestImage(
                    for: asset,
                    targetSize: targetSize,
                    contentMode: contentMode,
                    options: options
                ) { result, info in
                    Task { @MainActor in
                        let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                        if let result {
                            session.deliveredImage = true
                            // Don't cache opportunistic placeholders — they stick as blurry "high" thumbs.
                            if !isDegraded || !waitForFinalQuality {
                                PhotoThumbnailImageCache.store(result, for: cacheKey)
                                self.loadedQuality = requestedQuality
                            } else if self.loadedQuality == nil {
                                // Show degraded high preview without demoting a sharper cached frame.
                                self.loadedQuality = .fast
                            }
                            self.image = result
                            self.loadedTargetSize = targetSize
                        }

                        if waitForFinalQuality {
                            let isCancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                            let hasError = info?[PHImageErrorKey] != nil
                            if isCancelled || hasError || !isDegraded {
                                gate.resumeOnce()
                            }
                        } else {
                            gate.resumeOnce()
                        }
                    }
                }

                if waitForFinalQuality {
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        gate.resumeOnce()
                    }
                }
            }
        } onCancel: {
            guard !session.deliveredImage else { return }
            let requestID = session.requestID
            if requestID != PHInvalidImageRequestID {
                PHImageManager.default().cancelImageRequest(requestID)
            }
        }
    }

    @MainActor
    private func resolveCropFocusIfNeeded() async {
        if normalizedCropFocus != nil {
            resolvedCropFocus = nil
            return
        }

        guard let cropContext else {
            resolvedCropFocus = nil
            return
        }

        guard let cropData = AppDependencies.database.getPhotoCropData(photoId: assetIdentifier) else {
            resolvedCropFocus = nil
            return
        }

        guard PhotoFaceCropAnalyzer.needsFaceAwareCrop(orientation: cropData.orientation) else {
            resolvedCropFocus = nil
            return
        }

        let storedFocus: PhotoCropFocus? = switch cropContext {
        case .eventList: cropData.list
        case .frame: cropData.frame
        }

        if let storedFocus {
            resolvedCropFocus = storedFocus.cgPoint
            return
        }

        resolvedCropFocus = nil

        guard analyzesFacesIfMissing else { return }

        guard let analyzed = await PhotoFaceCropAnalyzer.analyze(assetIdentifier: assetIdentifier) else {
            return
        }

        AppDependencies.database.updateCropFocuses(
            photoId: assetIdentifier,
            list: analyzed.list,
            frame: analyzed.frame
        )

        switch cropContext {
        case .eventList:
            resolvedCropFocus = analyzed.list?.cgPoint
        case .frame:
            resolvedCropFocus = analyzed.frame?.cgPoint
        }
    }
}
