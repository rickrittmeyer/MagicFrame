import Foundation

enum OccasionObjectKeyFormatter: Sendable {

    nonisolated static func canonical(from input: String) -> String? {
        let trimmed = input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !trimmed.isEmpty else { return nil }

        let normalized = trimmed
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) || $0 == "_" }
            .map(String.init)
            .joined()

        return normalized.isEmpty ? nil : normalized
    }

    nonisolated static func displayName(from objectKey: String) -> String {
        objectKey
            .split(separator: "_")
            .map { part in
                part.isEmpty ? "" : part.prefix(1).uppercased() + part.dropFirst()
            }
            .joined(separator: " ")
    }
}
