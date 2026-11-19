import Photos
import SwiftUI
import UIKit

/// Circular crop of a single face using a Vision-normalized bounding box (origin bottom-left).
struct FaceCircleAvatar: View {

    let photoId: String
    let faceBoundingBox: CGRect?
    var size: CGFloat = 96

    @State private var image: UIImage?

    private var taskKey: String {
        guard let faceBoundingBox else { return "\(photoId)|full" }
        return String(
            format: "%@|%.4f,%.4f,%.4f,%.4f|%.0f|v6hq",
            photoId,
            faceBoundingBox.origin.x,
            faceBoundingBox.origin.y,
            faceBoundingBox.size.width,
            faceBoundingBox.size.height,
            size
        )
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle()
                    .fill(Color(.secondarySystemFill))
                    .overlay {
                        Image(systemName: "person.fill")
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
            Circle()
                .strokeBorder(Color(.tertiarySystemFill), lineWidth: 1)
        }
        .task(id: taskKey) {
            image = await Self.loadFaceImage(
                photoId: photoId,
                faceBoundingBox: faceBoundingBox,
                displaySize: size,
                cacheKey: taskKey
            )
        }
        .onDisappear {
            image = nil
        }
    }

    private static let cropCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 48
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()

    private static func loadFaceImage(
        photoId: String,
        faceBoundingBox: CGRect?,
        displaySize: CGFloat,
        cacheKey: String
    ) async -> UIImage? {
        guard let faceBoundingBox, faceBoundingBox.width > 0, faceBoundingBox.height > 0 else {
            return nil
        }

        if let cached = cropCache.object(forKey: cacheKey as NSString) {
            return cached
        }

        // High-quality decode sized for retina circle display (face crop needs headroom).
        let scale = UIScreen.main.scale
        let faceFraction = max(faceBoundingBox.width, faceBoundingBox.height)
        let faceBoost = faceFraction > 0 ? min(1.0 / faceFraction, 6.0) : 3.0
        let target = min(
            2400,
            max(1024, displaySize * scale * max(faceBoost, 2.5))
        )

        guard let cgImage = await PhotoAssetImageLoader.loadCGImage(
            assetIdentifier: photoId,
            targetPixelSize: target,
            preferFastDecode: false
        ) else {
            return nil
        }

        let croppedImage = await Task.detached(priority: .userInitiated) {
            autoreleasepool { () -> UIImage? in
                guard let cropped = FaceRecognitionAnalyzer.croppedFaceImage(
                    from: cgImage,
                    normalizedBox: faceBoundingBox,
                    padding: 0.28,
                    verticalBias: 0.08
                ) else {
                    return nil
                }
                return UIImage(cgImage: cropped)
            }
        }.value

        if let croppedImage {
            let cost = Int(croppedImage.size.width * croppedImage.size.height * 4)
            cropCache.setObject(croppedImage, forKey: cacheKey as NSString, cost: max(cost, 1))
        }
        return croppedImage
    }

    static func clearCache() {
        cropCache.removeAllObjects()
    }
}
