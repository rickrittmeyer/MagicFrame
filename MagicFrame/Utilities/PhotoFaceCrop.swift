import CoreImage
import Foundation
import Photos
import UIKit
import Vision

/// Normalized crop anchor (0–1, top-left origin) for `scaledToFill` into a target aspect.
struct PhotoCropFocus: Equatable {
    let x: Double
    let y: Double

    var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    init(_ point: CGPoint) {
        x = Double(point.x)
        y = Double(point.y)
    }
}

enum PhotoCropTarget {
    case eventList
    case frame

    var aspectRatio: CGFloat {
        switch self {
        case .eventList:
            return PhotoCropCalculator.eventListAspectRatio
        case .frame:
            return PhotoCropCalculator.frameAspectRatio
        }
    }
}

enum PhotoCropCalculator {
    /// Event library banner (`EventLibraryRowView`).
    static let eventListAspectRatio: CGFloat = 4.0 / 3.0
    /// Physical frame display; adjust when hardware ratio is known.
    static let frameAspectRatio: CGFloat = 16.0 / 9.0

    /// Clamps a focal point so the visible `scaledToFill` window stays inside the image.
    static func clampedFocus(
        _ focus: CGPoint,
        imageAspect: CGFloat,
        targetAspect: CGFloat
    ) -> CGPoint {
        guard imageAspect > 0, targetAspect > 0 else { return focus }

        let imageWidth = imageAspect
        let imageHeight: CGFloat = 1

        let visibleWidth: CGFloat
        let visibleHeight: CGFloat

        if imageAspect > targetAspect {
            visibleHeight = imageHeight
            visibleWidth = imageHeight * targetAspect
        } else {
            visibleWidth = imageWidth
            visibleHeight = imageWidth / targetAspect
        }

        let minX = visibleWidth / 2
        let maxX = imageWidth - visibleWidth / 2
        let minY = visibleHeight / 2
        let maxY = imageHeight - visibleHeight / 2

        let pixelX = focus.x * imageWidth
        let pixelY = focus.y * imageHeight

        return CGPoint(
            x: pixelX.clamped(to: minX...maxX) / imageWidth,
            y: pixelY.clamped(to: minY...maxY) / imageHeight
        )
    }

    /// Offset for a center-aligned `scaledToFill` image so `focus` (top-left normalized 0–1)
    /// lands on the container center.
    static func fillOffset(
        imageSize: CGSize,
        containerSize: CGSize,
        focus: CGPoint
    ) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0,
              containerSize.width > 0, containerSize.height > 0 else {
            return .zero
        }

        let scale = max(
            containerSize.width / imageSize.width,
            containerSize.height / imageSize.height
        )
        let scaledWidth = imageSize.width * scale
        let scaledHeight = imageSize.height * scale

        // Default scaledToFill centers the image (anchor 0.5, 0.5). Shift from that anchor.
        return CGSize(
            width: (0.5 - focus.x) * scaledWidth,
            height: (0.5 - focus.y) * scaledHeight
        )
    }
}

enum PhotoFaceCropAnalyzer {

    static let algorithmVersion = 2

    /// Face-aware list crop is for display-tall photos only (not landscape).
    static func needsFaceAwareCrop(orientation: String) -> Bool {
        orientation != "landscape"
    }

    static func needsFaceAwareCrop(image: UIImage) -> Bool {
        image.size.height > image.size.width
    }

    static func analyze(assetIdentifier: String) async -> (list: PhotoCropFocus?, frame: PhotoCropFocus?)? {
        guard let image = await PhotoFaceAnalyzer.loadAnalysisImage(for: assetIdentifier) else {
            return nil
        }
        return analyze(image: image)
    }

    static func analyze(image: UIImage) -> (list: PhotoCropFocus?, frame: PhotoCropFocus?)? {
        guard needsFaceAwareCrop(image: image) else { return nil }
        guard let union = normalizedFaceUnionRect(in: image) else { return nil }

        let imageAspect = image.size.width / image.size.height
        let rawFocus = CGPoint(x: union.midX, y: union.midY)

        let listFocus = PhotoCropFocus(
            PhotoCropCalculator.clampedFocus(
                rawFocus,
                imageAspect: imageAspect,
                targetAspect: PhotoCropCalculator.eventListAspectRatio
            )
        )

        let frameFocus = PhotoCropFocus(
            PhotoCropCalculator.clampedFocus(
                rawFocus,
                imageAspect: imageAspect,
                targetAspect: PhotoCropCalculator.frameAspectRatio
            )
        )

        return (list: listFocus, frame: frameFocus)
    }

    private static func normalizedFaceUnionRect(in image: UIImage) -> CGRect? {
        guard let cgImage = image.normalizedCGImageForVision() else { return nil }

        let ciImage = CIImage(cgImage: cgImage)
        let ciFaces = detectAllCIFaces(in: ciImage)
        let vnFaces = detectAllVNFaces(cgImage: cgImage)

        var rects: [CGRect] = []

        for vnFace in vnFaces {
            rects.append(visionRectTopLeftNormalized(vnFace.boundingBox))
        }

        for ciFace in ciFaces {
            rects.append(
                ciRectTopLeftNormalized(for: ciFace, imageExtent: ciImage.extent)
            )
        }

        guard !rects.isEmpty else { return nil }

        var union = rects[0]
        for rect in rects.dropFirst() {
            union = union.union(rect)
        }

        return paddedFaceUnion(union)
    }

    private static func paddedFaceUnion(_ union: CGRect) -> CGRect {
        let padX = union.width * 0.12
        let padTop = union.height * 0.22
        let padBottom = union.height * 0.08

        var padded = union
        padded.origin.x -= padX
        padded.origin.y -= padTop
        padded.size.width += padX * 2
        padded.size.height += padTop + padBottom
        return padded.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    private static func visionRectTopLeftNormalized(_ box: CGRect) -> CGRect {
        CGRect(
            x: box.origin.x,
            y: 1 - box.origin.y - box.height,
            width: box.width,
            height: box.height
        )
    }

    private static func detectAllCIFaces(in image: CIImage) -> [CIFaceFeature] {
        let options: [String: Any] = [CIDetectorAccuracy: CIDetectorAccuracyHigh]
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
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(
            cgImage: cgImage,
            orientation: .up,
            options: [:]
        )

        do {
            try handler.perform([request])
        } catch {
            return []
        }

        return (request.results ?? []).sorted {
            $0.boundingBox.width * $0.boundingBox.height >
                $1.boundingBox.width * $1.boundingBox.height
        }
    }

    /// CIFaceFeature uses a bottom-left origin; convert to top-left normalized (0–1).
    private static func ciRectTopLeftNormalized(
        for ciFace: CIFaceFeature,
        imageExtent: CGRect
    ) -> CGRect {
        let bounds = ciFace.bounds
        guard imageExtent.width > 0, imageExtent.height > 0 else { return .zero }

        let width = bounds.width / imageExtent.width
        let height = bounds.height / imageExtent.height
        let x = (bounds.origin.x - imageExtent.origin.x) / imageExtent.width
        let yTop = 1 - ((bounds.origin.y - imageExtent.origin.y) + bounds.height) / imageExtent.height

        return CGRect(x: x, y: yTop, width: width, height: height)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
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
