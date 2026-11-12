import Foundation
import Photos
import UIKit
import Vision

/// Vision feature-print distance for burst/stack verification (lower = more alike).
enum PhotoVisualSimilarity {

    /// Max `VNFeaturePrintObservation.computeDistance` to treat two photos as the same shot.
    /// True bursts are typically well under this; unrelated imports with matching timestamps are above it.
    static let maxDistance: Float = 0.72

    private static let analysisPixelSize = CGSize(width: 360, height: 360)

    private static let printCache = NSCache<NSString, VNFeaturePrintObservation>()

    static func areVisuallySimilar(photoIdA: String, photoIdB: String) async -> Bool {
        if photoIdA == photoIdB { return true }
        guard let printA = await featurePrint(forAssetIdentifier: photoIdA),
              let printB = await featurePrint(forAssetIdentifier: photoIdB) else {
            // If either print fails, keep the metadata grouping (don't drop true bursts).
            return true
        }
        var distance: Float = .greatestFiniteMagnitude
        do {
            try printA.computeDistance(&distance, to: printB)
        } catch {
            return true
        }
        return distance <= maxDistance
    }

    static func featurePrint(forAssetIdentifier assetIdentifier: String) async -> VNFeaturePrintObservation? {
        let key = assetIdentifier as NSString
        if let cached = printCache.object(forKey: key) {
            return cached
        }
        guard let cgImage = await loadCGImage(forAssetIdentifier: assetIdentifier) else {
            return nil
        }

        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first as? VNFeaturePrintObservation else {
            return nil
        }
        printCache.setObject(observation, forKey: key)
        return observation
    }

    private static func loadCGImage(forAssetIdentifier assetIdentifier: String) async -> CGImage? {
        await withCheckedContinuation { continuation in
            let assets = PHAsset.fetchAssets(
                withLocalIdentifiers: [assetIdentifier],
                options: nil
            )
            guard let asset = assets.firstObject else {
                continuation.resume(returning: nil)
                return
            }

            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            options.isSynchronous = false

            final class ResumeGate: @unchecked Sendable {
                private let lock = NSLock()
                private var resumed = false
                private let continuation: CheckedContinuation<CGImage?, Never>

                init(_ continuation: CheckedContinuation<CGImage?, Never>) {
                    self.continuation = continuation
                }

                func resume(_ value: CGImage?) {
                    lock.lock()
                    defer { lock.unlock() }
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(returning: value)
                }
            }

            let gate = ResumeGate(continuation)
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: analysisPixelSize,
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                let failed = info?[PHImageErrorKey] != nil
                if cancelled || failed {
                    gate.resume(nil)
                    return
                }
                gate.resume(image?.normalizedCGImageForFeaturePrint())
            }
        }
    }
}

private extension UIImage {
    func normalizedCGImageForFeaturePrint() -> CGImage? {
        if imageOrientation == .up, let cgImage {
            return cgImage
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let rendered = renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
        return rendered.cgImage
    }
}
