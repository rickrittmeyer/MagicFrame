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
            format: "%@|%.4f,%.4f,%.4f,%.4f|v5",
            photoId,
            faceBoundingBox.origin.x,
            faceBoundingBox.origin.y,
            faceBoundingBox.size.width,
            faceBoundingBox.size.height
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
        cache.countLimit = 24
        cache.totalCostLimit = 6 * 1024 * 1024
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

        // Memory-first: modest decode. Representatives are already large faces.
        let target = min(720, max(480, displaySize * UIScreen.main.scale * 2.5))

        guard let cgImage = await PhotoAssetImageLoader.loadCGImage(
            assetIdentifier: photoId,
            targetPixelSize: target,
            preferFastDecode: true
        ) else {
            return nil
        }

        let croppedImage = await Task.detached(priority: .utility) {
            autoreleasepool { () -> UIImage? in
                guard let cropped = FaceRecognitionAnalyzer.croppedFaceImage(
                    from: cgImage,
                    normalizedBox: faceBoundingBox,
                    padding: 0.32,
                    verticalBias: 0.10
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
