import Foundation
import Photos
import UIKit
import Vision
import CoreImage

struct SimilarPhotoGroup: Identifiable, Equatable {
    let id: String
    let photos: [IndexedPhoto]

    var isStack: Bool {
        photos.count > 1
    }

    static func == (lhs: SimilarPhotoGroup, rhs: SimilarPhotoGroup) -> Bool {
        lhs.id == rhs.id && lhs.photos.map(\.id) == rhs.photos.map(\.id)
    }

    func autoBestPhoto() -> IndexedPhoto {
        rank(photos).first ?? photos[0]
    }

    func displayPhoto(picks: Set<String>) -> IndexedPhoto {
        let pickedPhotos = photos.filter { picks.contains($0.id) }
        if pickedPhotos.isEmpty {
            return autoBestPhoto()
        }
        return rank(pickedPhotos).first ?? autoBestPhoto()
    }

    func pickedPhotoIds(from photos: [IndexedPhoto]) -> Set<String> {
        Set(photos.filter(\.isSimilarGroupPick).map(\.id))
    }

    func rankedPhotos(resolvingFrom allPhotos: [IndexedPhoto]) -> [IndexedPhoto] {
        let resolved = photos.map { photo in
            allPhotos.first(where: { $0.id == photo.id }) ?? photo
        }
        return rank(resolved)
    }

    private func rank(_ photos: [IndexedPhoto]) -> [IndexedPhoto] {
        photos.sorted { left, right in
            if left.faceCombinedScore != right.faceCombinedScore {
                return left.faceCombinedScore > right.faceCombinedScore
            }
            if left.isFavorite != right.isFavorite {
                return left.isFavorite
            }
            return left.creationDate < right.creationDate
        }
    }
}

extension IndexedPhoto {
    /// Sum of eyes-open and smile scores (0–2) for ranking similar bursts.
    var faceCombinedScore: Double {
        (faceEyesOpenScore ?? 0) + (faceSmileScore ?? 0)
    }

    /// Legacy alias used by grid auto-pick ranking.
    var similarPhotoExpressionScore: Double {
        faceCombinedScore * 100
    }
}

struct EventPhotoDisplayItem: Identifiable {
    let group: SimilarPhotoGroup
    let representative: IndexedPhoto

    var id: String { group.id }

    var extraCount: Int {
        max(0, group.photos.count - 1)
    }

    var isStack: Bool {
        group.isStack
    }
}

enum EventSimilarPhotoGrouper {

    /// Burst-style shots taken within this window can collapse into one grid cell.
    static let maxGapSeconds: TimeInterval = 4
    static let aspectRatioTolerance = 0.1
    static let dimensionTolerance = 0.15

    static func group(_ photos: [IndexedPhoto]) -> [SimilarPhotoGroup] {
        guard !photos.isEmpty else { return [] }

        var groups: [SimilarPhotoGroup] = []
        var currentMembers: [IndexedPhoto] = [photos[0]]

        for photo in photos.dropFirst() {
            if let previous = currentMembers.last,
               areSimilar(previous, photo) {
                currentMembers.append(photo)
            } else {
                groups.append(makeGroup(from: currentMembers))
                currentMembers = [photo]
            }
        }

        groups.append(makeGroup(from: currentMembers))
        return groups
    }

    static func displayItems(from photos: [IndexedPhoto]) -> [EventPhotoDisplayItem] {
        group(photos).map { group in
            let picks = group.pickedPhotoIds(from: group.photos)
            return EventPhotoDisplayItem(
                group: group,
                representative: group.displayPhoto(picks: picks)
            )
        }
    }

    private static func makeGroup(from photos: [IndexedPhoto]) -> SimilarPhotoGroup {
        let leaderId = photos[0].id
        return SimilarPhotoGroup(id: leaderId, photos: photos)
    }

    private static func areSimilar(_ left: IndexedPhoto, _ right: IndexedPhoto) -> Bool {
        guard left.orientation == right.orientation else { return false }

        if abs(left.aspectRatio - right.aspectRatio) > aspectRatioTolerance {
            return false
        }

        if !dimensionsAreSimilar(left, right) {
            return false
        }

        guard let leftDate = EventDateParser.parseDate(left.creationDate),
              let rightDate = EventDateParser.parseDate(right.creationDate) else {
            return false
        }

        return abs(rightDate.timeIntervalSince(leftDate)) <= maxGapSeconds
    }

    private static func dimensionsAreSimilar(_ left: IndexedPhoto, _ right: IndexedPhoto) -> Bool {
        guard left.width > 0, left.height > 0, right.width > 0, right.height > 0 else {
            return true
        }

        let widthDelta = abs(Double(left.width - right.width)) / Double(max(left.width, right.width))
        let heightDelta = abs(Double(left.height - right.height)) / Double(max(left.height, right.height))
        return widthDelta <= dimensionTolerance && heightDelta <= dimensionTolerance
    }
}

struct TripPhotoDisplaySection: Identifiable {
    let section: TripEventSection
    let displayItems: [EventPhotoDisplayItem]

    var id: Int { section.id }
}

struct PhotoFaceMetrics: Equatable {
    let eyesOpenScore: Double
    let smileScore: Double

    var rankScore: Double {
        eyesOpenScore * 0.55 + smileScore * 0.45
    }
}

enum PhotoFaceAnalyzer {

    /// Bump when scoring logic changes so cached values can be refreshed.
    static let algorithmVersion = 5

    static func analyze(assetIdentifier: String) async -> PhotoFaceMetrics? {
        guard let image = await loadAnalysisImage(for: assetIdentifier) else {
            return nil
        }
        return analyze(image: image)
    }

    static func analyze(image: UIImage) -> PhotoFaceMetrics? {
        guard let cgImage = image.normalizedCGImageForVision() else { return nil }

        let ciImage = CIImage(cgImage: cgImage)
        let ciFaces = detectAllCIFaces(in: ciImage)
        let vnFaces = detectAllVNFaces(cgImage: cgImage)

        guard !ciFaces.isEmpty || !vnFaces.isEmpty else { return nil }

        let pairs = pairFaces(
            ciFaces: ciFaces,
            vnFaces: vnFaces,
            imageExtent: ciImage.extent
        )

        let eyesScores = pairs.map { eyesOpenScore(ciFace: $0.ciFace, vnFace: $0.vnFace) }
        let smileScores = pairs.map { smileScore(ciFace: $0.ciFace, vnFace: $0.vnFace) }

        // Eyes: worst face wins — one blink shouldn't lose to a solo smiler.
        // Smile: best face wins — clearest smile in the group.
        return PhotoFaceMetrics(
            eyesOpenScore: eyesScores.min() ?? 0,
            smileScore: smileScores.max() ?? 0
        )
    }

    private struct FacePair {
        let ciFace: CIFaceFeature?
        let vnFace: VNFaceObservation?
    }

    private static func detectAllCIFaces(in image: CIImage) -> [CIFaceFeature] {
        let options: [String: Any] = [
            CIDetectorAccuracy: CIDetectorAccuracyHigh,
            CIDetectorSmile: true,
            CIDetectorEyeBlink: true
        ]

        guard let detector = CIDetector(
            ofType: CIDetectorTypeFace,
            context: nil,
            options: options
        ) else {
            return []
        }

        let features = detector.features(in: image) as? [CIFaceFeature] ?? []
        return features.sorted {
            $0.bounds.width * $0.bounds.height > $1.bounds.width * $1.bounds.height
        }
    }

    private static func detectAllVNFaces(cgImage: CGImage) -> [VNFaceObservation] {
        let landmarksRequest = VNDetectFaceLandmarksRequest()
        landmarksRequest.revision = VNDetectFaceLandmarksRequestRevision3

        let handler = VNImageRequestHandler(
            cgImage: cgImage,
            orientation: .up,
            options: [:]
        )

        do {
            try handler.perform([landmarksRequest])
        } catch {
            return []
        }

        return (landmarksRequest.results ?? []).sorted {
            $0.boundingBox.area > $1.boundingBox.area
        }
    }

    private static func pairFaces(
        ciFaces: [CIFaceFeature],
        vnFaces: [VNFaceObservation],
        imageExtent: CGRect
    ) -> [FacePair] {
        var pairs: [FacePair] = []
        var usedCIFaceIndexes = Set<Int>()

        for vnFace in vnFaces {
            var bestIndex: Int?
            var bestOverlap = 0.15

            for (index, ciFace) in ciFaces.enumerated() where !usedCIFaceIndexes.contains(index) {
                let ciBounds = normalizedBounds(for: ciFace, imageExtent: imageExtent)
                let overlap = intersectionOverUnion(vnFace.boundingBox, ciBounds)
                if overlap > bestOverlap {
                    bestOverlap = overlap
                    bestIndex = index
                }
            }

            if let bestIndex {
                usedCIFaceIndexes.insert(bestIndex)
                pairs.append(FacePair(ciFace: ciFaces[bestIndex], vnFace: vnFace))
            } else {
                pairs.append(FacePair(ciFace: nil, vnFace: vnFace))
            }
        }

        for (index, ciFace) in ciFaces.enumerated() where !usedCIFaceIndexes.contains(index) {
            pairs.append(FacePair(ciFace: ciFace, vnFace: nil))
        }

        return pairs
    }

    private static func normalizedBounds(
        for ciFace: CIFaceFeature,
        imageExtent: CGRect
    ) -> CGRect {
        let bounds = ciFace.bounds
        guard imageExtent.width > 0, imageExtent.height > 0 else { return .zero }

        return CGRect(
            x: bounds.origin.x / imageExtent.width,
            y: bounds.origin.y / imageExtent.height,
            width: bounds.width / imageExtent.width,
            height: bounds.height / imageExtent.height
        )
    }

    private static func intersectionOverUnion(_ lhs: CGRect, _ rhs: CGRect) -> Double {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }

        let intersectionArea = intersection.width * intersection.height
        let unionArea = lhs.area + rhs.area - intersectionArea
        guard unionArea > 0 else { return 0 }

        return Double(intersectionArea / unionArea)
    }

    private static func eyesOpenScore(
        ciFace: CIFaceFeature?,
        vnFace: VNFaceObservation?
    ) -> Double {
        let visionScore = vnFace.map { visionEyeOpenness(from: $0) }

        guard let ciFace else {
            return visionScore ?? 0
        }

        let leftOpen = !ciFace.leftEyeClosed
        let rightOpen = !ciFace.rightEyeClosed

        switch (leftOpen, rightOpen) {
        case (false, false):
            return min(visionScore ?? 0.08, 0.12)
        case (true, false), (false, true):
            let openSide = visionScore ?? 0.55
            return 0.38 + openSide * 0.35
        case (true, true):
            let openSide = visionScore ?? 0.82
            return 0.62 + openSide * 0.38
        }
    }

    private static func smileScore(
        ciFace: CIFaceFeature?,
        vnFace: VNFaceObservation?
    ) -> Double {
        let visionScore = vnFace.map { visionSmileScore(from: $0) } ?? 0

        guard let ciFace else {
            return calibrateSmileScore(visionScore)
        }

        if ciFace.hasSmile {
            return max(0.88, 0.82 + visionScore * 0.18)
        }

        return calibrateSmileScore(visionScore)
    }

    private static func calibrateSmileScore(_ raw: Double) -> Double {
        min(1, 0.22 + raw * 0.78)
    }

    private static func visionEyeOpenness(from face: VNFaceObservation) -> Double {
        guard let landmarks = face.landmarks else { return 0 }

        let leftScore = eyeOpenness(
            eye: landmarks.leftEye,
            pupil: landmarks.leftPupil
        )
        let rightScore = eyeOpenness(
            eye: landmarks.rightEye,
            pupil: landmarks.rightPupil
        )

        switch (leftScore, rightScore) {
        case let (left?, right?):
            return (left + right) / 2
        case let (left?, nil):
            return left
        case let (nil, right?):
            return right
        default:
            return 0
        }
    }

    private static func eyeOpenness(
        eye: VNFaceLandmarkRegion2D?,
        pupil: VNFaceLandmarkRegion2D?
    ) -> Double? {
        guard let eye else { return nil }

        let points = eye.normalizedPoints
        guard points.count >= 4 else {
            return pupil != nil ? 0.75 : nil
        }

        let xs = points.map { Double($0.x) }
        let centerX = (xs.max()! + xs.min()!) / 2
        let centerBand = points.filter {
            abs(Double($0.x) - centerX) <= (xs.max()! - xs.min()!) * 0.22
        }

        let verticalPoints = centerBand.isEmpty ? points : centerBand
        let ys = verticalPoints.map { Double($0.y) }
        let vertical = (ys.max() ?? 0) - (ys.min() ?? 0)
        let horizontal = max((xs.max() ?? 0) - (xs.min() ?? 0), 0.0001)
        let ear = vertical / horizontal

        var score = min(1, max(0, (ear - 0.08) / 0.20))

        if let pupil, !pupil.normalizedPoints.isEmpty {
            score = max(score, 0.68)
        }

        return score
    }

    private static func visionSmileScore(from face: VNFaceObservation) -> Double {
        guard let outerLips = face.landmarks?.outerLips?.normalizedPoints,
              outerLips.count >= 4 else {
            return 0
        }

        let sortedByX = outerLips.sorted { $0.x < $1.x }
        guard let leftCorner = sortedByX.first,
              let rightCorner = sortedByX.last else {
            return 0
        }

        let lipYs = outerLips.map { Double($0.y) }
        let lipCenterY = lipYs.reduce(0, +) / Double(lipYs.count)
        let cornerY = (Double(leftCorner.y) + Double(rightCorner.y)) / 2
        let cornerLift = cornerY - lipCenterY
        let mouthWidth = Double(rightCorner.x - leftCorner.x)

        let liftScore = min(1, max(0, cornerLift / 0.008))
        let widthScore = min(1, max(0, (mouthWidth - 0.30) / 0.14))

        var score = (liftScore * 0.55) + (widthScore * 0.45)

        if let innerLips = face.landmarks?.innerLips?.normalizedPoints,
           innerLips.count >= 4 {
            let innerXs = innerLips.map { Double($0.x) }
            let innerYs = innerLips.map { Double($0.y) }
            let innerWidth = (innerXs.max() ?? 0) - (innerXs.min() ?? 0)
            let innerHeight = (innerYs.max() ?? 0) - (innerYs.min() ?? 0)
            let innerWidthScore = min(1, max(0, (innerWidth - 0.12) / 0.10))
            let opennessScore = min(1, max(0, innerHeight / 0.025))
            let innerScore = (innerWidthScore * 0.6) + (opennessScore * 0.4)
            score = max(score, (liftScore * 0.3) + (innerScore * 0.7))
        }

        return score
    }

    static func loadAnalysisImage(for assetIdentifier: String) async -> UIImage? {
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
            options.resizeMode = .none
            options.isNetworkAccessAllowed = true
            options.isSynchronous = false

            PHImageManager.default().requestImage(
                for: asset,
                targetSize: PHImageManagerMaximumSize,
                contentMode: .aspectFit,
                options: options
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }
}

private extension CGRect {
    var area: CGFloat {
        width * height
    }
}

private extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}

private extension UIImage {
    func normalizedCGImageForVision() -> CGImage? {
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
