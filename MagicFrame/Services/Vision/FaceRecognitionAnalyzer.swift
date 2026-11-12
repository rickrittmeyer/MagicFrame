import CoreGraphics
import Foundation
import UIKit
import Vision

struct DetectedFaceCandidate: Sendable {
    let boundingBox: CGRect
    let quality: Double
    let embeddingData: Data
}

/// On-device face detect + feature-print embed for identity clustering.
///
/// Important: `VNGenerateImageFeaturePrintRequest` is a **general image** similarity signal,
/// not a true face-identity model. On iOS 17+ distances are normalized to roughly **0…2**.
/// Thresholds must stay well below the ~0.72 used for full-frame burst matching, or unrelated
/// faces (all “a face in a square”) will cluster together.
enum FaceRecognitionAnalyzer: Sendable {

    /// Bumped when detect persistence / embed behavior changes (forces re-scan).
    nonisolated static let algorithmVersion = 3
    /// Bumped when embedding request / distance scale interpretation changes.
    nonisolated static let embeddingVersion = 2

    // MARK: - Distance thresholds (iOS 17+ normalized feature prints, max ~2.0)

    /// Auto-link to an already-named person.
    nonisolated static let namedMatchDistanceThreshold: Float = 0.40

    /// Join a new detection to an existing unnamed cluster while scanning.
    /// Feature-prints are noisy across age/angle — too-tight thresholds create dozens
    /// of tiny same-person clusters (and “photo counts” look falsely low).
    nonisolated static let clusterMatchDistanceThreshold: Float = 0.52

    /// Manual / post-scan “Combine similar faces”.
    nonisolated static let clusterConsolidateDistanceThreshold: Float = 0.48

    /// Prefer leaving a face unmatched over an ambiguous two-cluster tie.
    nonisolated static let matchMargin: Float = 0.03

    /// Soft cap: large clusters need a slightly closer match to absorb more faces.
    nonisolated static let largeClusterFaceCount = 80
    nonisolated static let largeClusterMatchDistanceThreshold: Float = 0.46

    nonisolated static let matchDistanceThreshold: Float = clusterMatchDistanceThreshold

    /// Reject tiny / background faces (normalized area). Looser than 0.008 so group-shot heads survive.
    nonisolated static let minimumFaceArea: CGFloat = 0.002
    nonisolated static let minimumFaceEdge: CGFloat = 0.012
    nonisolated static let minimumFaceAspect: CGFloat = 0.55
    nonisolated static let maximumFaceAspect: CGFloat = 1.85
    nonisolated static let minimumCaptureQuality: Float = 0.05
    /// Bulk / background jobs — memory-safe.
    nonisolated static let scanTargetPixelSize: CGFloat = 1024
    /// Single-photo preview / ensure path — better small-face recall in groups.
    nonisolated static let previewScanTargetPixelSize: CGFloat = 2048
    nonisolated static let maxFacesPerPhoto: Int = 20

    nonisolated static func analyze(
        assetIdentifier: String,
        preferFastDecode: Bool = true,
        targetPixelSize: CGFloat = scanTargetPixelSize
    ) async -> [DetectedFaceCandidate] {
        guard let cgImage = await PhotoAssetImageLoader.loadCGImage(
            assetIdentifier: assetIdentifier,
            targetPixelSize: targetPixelSize,
            preferFastDecode: preferFastDecode
        ) else {
            return []
        }

        return await Task.detached(priority: .utility) {
            autoreleasepool {
                detectAndEmbed(cgImage: cgImage)
            }
        }.value
    }

    nonisolated static func distance(between lhs: Data, and rhs: Data) -> Float? {
        guard let left = unarchiveFeaturePrint(lhs),
              let right = unarchiveFeaturePrint(rhs) else {
            return nil
        }
        var distance: Float = .greatestFiniteMagnitude
        do {
            try left.computeDistance(&distance, to: right)
            // Guard against corrupt / empty prints collapsing to 0 for everything.
            guard distance.isFinite, distance >= 0 else { return nil }
            return distance
        } catch {
            return nil
        }
    }

    // MARK: - Private

    nonisolated private static func detectAndEmbed(cgImage: CGImage) -> [DetectedFaceCandidate] {
        let rectangles = VNDetectFaceRectanglesRequest()
        let qualityRequest = VNDetectFaceCaptureQualityRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        do {
            try handler.perform([rectangles, qualityRequest])
        } catch {
            return []
        }

        let qualityByBox = captureQualityByBoundingBox(qualityRequest.results ?? [])
        let faces = rectangles.results ?? []
        var candidates: [DetectedFaceCandidate] = []
        candidates.reserveCapacity(min(faces.count, maxFacesPerPhoto))

        for face in faces {
            let box = face.boundingBox
            guard isPlausibleFaceBox(box) else { continue }

            let captureQuality = nearestCaptureQuality(for: box, in: qualityByBox)
            if let captureQuality, captureQuality < minimumCaptureQuality {
                continue
            }

            let candidate: DetectedFaceCandidate? = autoreleasepool {
                // Keep the rectangle even if embed fails — preview overlays need boxes.
                let crop = croppedFaceImage(from: cgImage, normalizedBox: box)
                let embedding = crop.flatMap { featurePrintData(for: $0) } ?? Data()
                let area = Float(box.width * box.height)
                let quality = Double(min(1, max(0, captureQuality ?? (area * 3))))
                return DetectedFaceCandidate(
                    boundingBox: box,
                    quality: quality,
                    embeddingData: embedding
                )
            }
            guard let candidate else { continue }
            candidates.append(candidate)
        }

        return Array(candidates.sorted { $0.quality > $1.quality }.prefix(maxFacesPerPhoto))
    }

    nonisolated private static func isPlausibleFaceBox(_ box: CGRect) -> Bool {
        let area = box.width * box.height
        guard area >= minimumFaceArea else { return false }
        guard box.width > minimumFaceEdge, box.height > minimumFaceEdge else { return false }
        let aspect = box.width / max(box.height, 0.0001)
        guard aspect >= minimumFaceAspect, aspect <= maximumFaceAspect else { return false }
        guard area <= 0.45 else { return false }
        return true
    }

    nonisolated private static func captureQualityByBoundingBox(
        _ observations: [VNFaceObservation]
    ) -> [(CGRect, Float)] {
        observations.compactMap { observation in
            guard let quality = observation.faceCaptureQuality else { return nil }
            return (observation.boundingBox, quality)
        }
    }

    nonisolated private static func nearestCaptureQuality(
        for box: CGRect,
        in qualities: [(CGRect, Float)]
    ) -> Float? {
        guard !qualities.isEmpty else { return nil }
        var best: (Float, CGFloat)?
        for (other, quality) in qualities {
            let dx = box.midX - other.midX
            let dy = box.midY - other.midY
            let dist = dx * dx + dy * dy
            if best == nil || dist < best!.1 {
                best = (quality, dist)
            }
        }
        return best?.0
    }

    /// - Parameters:
    ///   - padding: Extra normalized margin around the Vision box before squaring.
    ///   - verticalBias: Shift crop center upward in Vision space (toward hair/forehead).
    nonisolated static func croppedFaceImage(
        from cgImage: CGImage,
        normalizedBox: CGRect,
        padding: CGFloat = 0.08,
        verticalBias: CGFloat = 0
    ) -> CGImage? {
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        guard width > 0, height > 0,
              normalizedBox.width > 0, normalizedBox.height > 0 else {
            return nil
        }

        let side = max(normalizedBox.width, normalizedBox.height) * (1 + padding * 2)
        let bias = verticalBias * normalizedBox.height
        var square = CGRect(
            x: normalizedBox.midX - side / 2,
            y: normalizedBox.midY - side / 2 + bias,
            width: side,
            height: side
        )
        square.origin.x = min(max(square.origin.x, 0), max(0, 1 - square.width))
        square.origin.y = min(max(square.origin.y, 0), max(0, 1 - square.height))
        if square.maxX > 1 { square.size.width = max(0, 1 - square.origin.x) }
        if square.maxY > 1 { square.size.height = max(0, 1 - square.origin.y) }

        let rect = CGRect(
            x: square.origin.x * width,
            y: (1 - square.origin.y - square.height) * height,
            width: square.width * width,
            height: square.height * height
        ).integral

        guard rect.width > 8, rect.height > 8,
              rect.minX >= 0, rect.minY >= 0,
              rect.maxX <= width + 1, rect.maxY <= height + 1,
              let cropped = cgImage.cropping(to: rect.intersection(CGRect(x: 0, y: 0, width: width, height: height))) else {
            return nil
        }
        return cropped
    }

    nonisolated private static func featurePrintData(for cgImage: CGImage) -> Data? {
        let request = VNGenerateImageFeaturePrintRequest()
        // Pin revision so distances stay on the iOS 17+ normalized 0…2 scale.
        request.revision = VNGenerateImageFeaturePrintRequestRevision2
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first as? VNFeaturePrintObservation else {
            return nil
        }
        return archiveFeaturePrint(observation)
    }

    nonisolated private static func archiveFeaturePrint(_ observation: VNFeaturePrintObservation) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: observation, requiringSecureCoding: true)
    }

    nonisolated private static func unarchiveFeaturePrint(_ data: Data) -> VNFeaturePrintObservation? {
        try? NSKeyedUnarchiver.unarchivedObject(
            ofClass: VNFeaturePrintObservation.self,
            from: data
        )
    }
}
