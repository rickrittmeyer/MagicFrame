import Foundation
import Vision

struct PhotoObjectDetection: Sendable, Equatable {
    let objectKey: String
    let confidence: Double
}

struct VisionClassification: Sendable, Identifiable, Equatable {
    let identifier: String
    let confidence: Double

    var id: String { identifier }
}

enum PhotoObjectVisionAnalyzer: Sendable {

    nonisolated static let algorithmVersion = 1

    nonisolated static func analyze(
        assetIdentifier: String,
        targetObjectKeys: Set<String>,
        minimumObservationConfidence: Float = 0.12
    ) async -> [PhotoObjectDetection] {
        guard !targetObjectKeys.isEmpty,
              let cgImage = await PhotoAssetImageLoader.loadCGImage(assetIdentifier: assetIdentifier) else {
            return []
        }

        return await Task.detached(priority: .utility) {
            classify(
                cgImage: cgImage,
                targetObjectKeys: targetObjectKeys,
                minimumObservationConfidence: minimumObservationConfidence
            )
        }.value
    }

    nonisolated static func topClassifications(
        assetIdentifier: String,
        limit: Int = 25,
        minimumObservationConfidence: Float = 0.01
    ) async -> [VisionClassification] {
        guard limit > 0,
              let cgImage = await PhotoAssetImageLoader.loadCGImage(assetIdentifier: assetIdentifier) else {
            return []
        }

        return await Task.detached(priority: .utility) {
            let observations = classifyObservations(cgImage: cgImage)
            return observations
                .filter { $0.confidence >= minimumObservationConfidence }
                .sorted { $0.confidence > $1.confidence }
                .prefix(limit)
                .map {
                    VisionClassification(
                        identifier: $0.identifier,
                        confidence: Double($0.confidence)
                    )
                }
        }.value
    }

    nonisolated static func matchedObjectDetections(
        classifications: [VisionClassification],
        targetObjectKeys: Set<String>,
        minimumObservationConfidence: Float = 0.12
    ) -> [PhotoObjectDetection] {
        var bestByObjectKey: [String: Double] = [:]

        for classification in classifications where classification.confidence >= Double(minimumObservationConfidence) {
            for objectKey in targetObjectKeys {
                guard let confidence = ObjectVisionLabelMatcher.matches(
                    objectKey: objectKey,
                    classificationIdentifier: classification.identifier,
                    minConfidence: Float(classification.confidence)
                ) else {
                    continue
                }

                let score = Double(confidence)
                if score > bestByObjectKey[objectKey, default: 0] {
                    bestByObjectKey[objectKey] = score
                }
            }
        }

        return bestByObjectKey
            .map { PhotoObjectDetection(objectKey: $0.key, confidence: $0.value) }
            .sorted { $0.confidence > $1.confidence }
    }

    nonisolated private static func classify(
        cgImage: CGImage,
        targetObjectKeys: Set<String>,
        minimumObservationConfidence: Float
    ) -> [PhotoObjectDetection] {
        let observations = classifyObservations(cgImage: cgImage)
        let classifications = observations.map {
            VisionClassification(identifier: $0.identifier, confidence: Double($0.confidence))
        }
        return matchedObjectDetections(
            classifications: classifications,
            targetObjectKeys: targetObjectKeys,
            minimumObservationConfidence: minimumObservationConfidence
        )
    }

    nonisolated private static func classifyObservations(cgImage: CGImage) -> [VNClassificationObservation] {
        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform([request])
        } catch {
            return []
        }

        return request.results ?? []
    }
}
