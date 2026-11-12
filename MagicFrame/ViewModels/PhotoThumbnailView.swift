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

    private var thumbnailCacheKey: String {
        PhotoThumbnailImageCache.key(
            assetIdentifier: assetIdentifier,
            quality: quality == .high ? "high" : "fast"
        )
    }

    @MainActor
    private func restoreCachedImageIfNeeded() {
        guard image == nil, let cached = PhotoThumbnailImageCache.image(for: thumbnailCacheKey) else {
            return
        }
        image = cached
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
        if image == nil, let cached = PhotoThumbnailImageCache.image(for: thumbnailCacheKey) {
            image = cached
            if isVideo == nil {
                detectedIsVideo = PhotoAssetKind.isVideo(assetIdentifier: assetIdentifier)
            }
            if size.width > 1, size.height > 1 {
                loadedTargetSize = CGSize(
                    width: size.width * displayScale,
                    height: size.height * displayScale
                )
            }
            return
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

        if let image, loadedTargetSize.width > 10 {
            let widthRatio = targetSize.width / loadedTargetSize.width
            if image.size.width > 0, widthRatio > 0.75, widthRatio < 1.35 {
                return
            }
        }

        if targetSize == loadedTargetSize, image != nil {
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

        switch quality {
        case .fast:
            options.deliveryMode = .fastFormat
            options.resizeMode = .fast
            await requestImage(
                for: asset,
                targetSize: targetSize,
                options: options,
                waitForFinalQuality: false
            )
        case .high:
            options.deliveryMode = .opportunistic
            options.resizeMode = .exact
            await requestImage(
                for: asset,
                targetSize: targetSize,
                options: options,
                waitForFinalQuality: true
            )
        }
    }

    @MainActor
    private func requestImage(
        for asset: PHAsset,
        targetSize: CGSize,
        options: PHImageRequestOptions,
        waitForFinalQuality: Bool
    ) async {
        final class RequestSession: @unchecked Sendable {
            var requestID = PHImageRequestID(PHInvalidImageRequestID)
            var deliveredImage = false
        }
        let session = RequestSession()

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
                                PhotoThumbnailImageCache.store(result, for: self.thumbnailCacheKey)
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
