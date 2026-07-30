import Photos
import UIKit

enum PhotoAssetImageLoader {

    static func loadCGImage(
        assetIdentifier: String,
        targetPixelSize: CGFloat = 512
    ) async -> CGImage? {
        await withCheckedContinuation { continuation in
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetIdentifier], options: nil)
            guard let asset = assets.firstObject else {
                continuation.resume(returning: nil)
                return
            }

            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
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

            PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFit,
                options: options
            ) { image, _ in
                continuation.resume(returning: image?.cgImage)
            }
        }
    }
}
