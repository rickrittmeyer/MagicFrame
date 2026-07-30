import Foundation

struct VisionLabelAnalysisResult: Sendable {
    let classifications: [VisionClassification]
    let objectMatches: [PhotoObjectDetection]
    let statusMessage: String
}

enum VisionLabelDebugService {

    static func analyze(
        assetIdentifier: String,
        objectKeys: [String]
    ) async -> VisionLabelAnalysisResult {
        let classifications = await PhotoObjectVisionAnalyzer.topClassifications(
            assetIdentifier: assetIdentifier
        )
        let objectMatches = PhotoObjectVisionAnalyzer.matchedObjectDetections(
            classifications: classifications,
            targetObjectKeys: Set(objectKeys)
        )

        let report = VisionLabelDebugFormatter.formatReport(
            assetIdentifier: assetIdentifier,
            classifications: classifications,
            objectKeys: objectKeys,
            objectMatches: objectMatches
        )
        print(report)

        return VisionLabelAnalysisResult(
            classifications: classifications,
            objectMatches: objectMatches,
            statusMessage: VisionLabelDebugFormatter.statusSummary(
                classifications: classifications,
                objectMatches: objectMatches
            )
        )
    }
}
