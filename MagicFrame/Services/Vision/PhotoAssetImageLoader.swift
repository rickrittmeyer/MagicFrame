import Photos
import UIKit

enum PhotoAssetImageLoader {

    static func loadCGImage(
        assetIdentifier: String,
        targetPixelSize: CGFloat = 512,
        preferFastDecode: Bool = false
    ) async -> CGImage? {
        await withCheckedContinuation { continuation in
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetIdentifier], options: nil)
            guard let asset = assets.firstObject else {
                continuation.resume(returning: nil)
                return
            }

            let options = PHImageRequestOptions()
            options.deliveryMode = preferFastDecode ? .fastFormat : .highQualityFormat
            options.resizeMode = preferFastDecode ? .fast : .exact
            options.isNetworkAccessAllowed = true
            options.isSynchronous = false

            let width = max(1, asset.pixelWidth)
            let height = max(1, asset.pixelHeight)
            let longest = max(width, height)
            let scale = min(1, targetPixelSize / CGFloat(longest))
            let targetSize = CGSize(
                width: max(1, CGFloat(width) * scale),
                height: max(1, CGFloat(height) * scale)
            )

            final class ResumeBox: @unchecked Sendable {
                var didResume = false
            }
            let box = ResumeBox()

            // Copy an upright CGImage out of the PHImageManager UIImage so orientation
            // flags can't desync Vision-normalized face boxes from pixel buffers.
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if !preferFastDecode, isDegraded {
                    return
                }
                guard !box.didResume else { return }
                box.didResume = true
                continuation.resume(returning: image.flatMap(uprightCGImage(from:)))
            }
        }
    }

    /// Renders `UIImage` into an upright bitmap so `.cgImage` matches on-screen orientation.
    static func uprightCGImage(from image: UIImage) -> CGImage? {
        if image.imageOrientation == .up, let cgImage = image.cgImage {
            return cgImage.copy() ?? cgImage
        }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image.cgImage }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let rendered = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return rendered.cgImage
    }
}
