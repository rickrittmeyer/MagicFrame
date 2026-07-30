import Foundation

enum VisionLabelDebugFormatter {

    static func formatReport(
        assetIdentifier: String,
        classifications: [VisionClassification],
        objectKeys: [String],
        objectMatches: [PhotoObjectDetection]
    ) -> String {
        var lines: [String] = []
        lines.append("---- VISION CLASSIFICATIONS ----")
        lines.append("Photo: \(assetIdentifier)")

        if classifications.isEmpty {
            lines.append("No classifications returned (image missing or Vision failed).")
        } else {
            for (index, classification) in classifications.enumerated() {
                lines.append(
                    String(
                        format: "%2d. %-32@ %5.1f%%",
                        index + 1,
                        classification.identifier as NSString,
                        classification.confidence * 100
                    )
                )
            }
        }

        if !objectKeys.isEmpty {
            lines.append("---- CHRISTMAS OBJECT RULE MATCHES ----")
            if objectMatches.isEmpty {
                lines.append("No matches for: \(objectKeys.joined(separator: ", "))")
            } else {
                for match in objectMatches {
                    let display = OccasionObjectKeyFormatter.displayName(from: match.objectKey)
                    lines.append(
                        String(
                            format: "• %@ (%@) %.1f%%",
                            display,
                            match.objectKey,
                            match.confidence * 100
                        )
                    )
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    static func statusSummary(
        classifications: [VisionClassification],
        objectMatches: [PhotoObjectDetection]
    ) -> String {
        guard let top = classifications.first else {
            return "Vision: no classifications."
        }

        let topLine = String(
            format: "Top: %@ %.0f%%",
            top.identifier,
            top.confidence * 100
        )

        guard let bestMatch = objectMatches.first else {
            return "\(topLine). No Christmas object matches."
        }

        let matchLine = String(
            format: "%@ %.0f%%",
            OccasionObjectKeyFormatter.displayName(from: bestMatch.objectKey),
            bestMatch.confidence * 100
        )
        return "\(topLine). Best object match: \(matchLine). See console for full list."
    }
}
