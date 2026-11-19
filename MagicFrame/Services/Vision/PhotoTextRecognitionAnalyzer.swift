import Foundation
import Vision

struct PhotoTextObservation: Sendable, Equatable {
    let string: String
    let confidence: Double
}

enum PhotoTextRecognitionAnalyzer: Sendable {

    nonisolated static let algorithmVersion = 1

    /// Higher than scene classify so small signage / jersey text stays readable.
    nonisolated static let targetPixelSize: CGFloat = 1600

    /// `nil` if the asset image cannot be loaded.
    nonisolated static func recognizeText(
        assetIdentifier: String,
        minimumConfidence: Float = 0.3
    ) async -> [PhotoTextObservation]? {
        guard let cgImage = await PhotoAssetImageLoader.loadCGImage(
            assetIdentifier: assetIdentifier,
            targetPixelSize: targetPixelSize
        ) else {
            return nil
        }

        return await Task.detached(priority: .utility) {
            recognize(cgImage: cgImage, minimumConfidence: minimumConfidence)
        }.value
    }

    nonisolated private static func recognize(
        cgImage: CGImage,
        minimumConfidence: Float
    ) -> [PhotoTextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }

        let observations = request.results ?? []
        var lines: [PhotoTextObservation] = []
        lines.reserveCapacity(observations.count)

        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            guard candidate.confidence >= minimumConfidence else { continue }
            let trimmed = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            lines.append(
                PhotoTextObservation(
                    string: trimmed,
                    confidence: Double(candidate.confidence)
                )
            )
        }

        return lines
    }

    nonisolated static func joinedFullText(from observations: [PhotoTextObservation]) -> String {
        observations.map(\.string).joined(separator: "\n")
    }
}
