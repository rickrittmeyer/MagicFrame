import Foundation

/// Finds near-identical copies of an event's photos elsewhere in the library (re-imports / screenshots).
enum EventLibraryDuplicateDetector {

    /// Max library hits kept per event photo (best / lowest distance first).
    static let maxMatchesPerEventPhoto = 3

    /// Tighter than in-event burst grouping — screenshots/reimports should still pass.
    static let aspectRatioTolerance = 0.05
    static let dimensionTolerance = 0.10

    struct Progress: Sendable {
        let current: Int
        let total: Int
    }

    static func findDuplicates(
        eventPhotos: [IndexedPhoto],
        libraryPhotos: [IndexedPhoto],
        progress: (@Sendable (Progress) -> Void)? = nil
    ) async -> [(eventPhotoId: String, libraryPhotoId: String, distance: Float)] {
        let eventIds = Set(eventPhotos.map(\.id))
        let candidates = libraryPhotos.filter { !eventIds.contains($0.id) }
        guard !eventPhotos.isEmpty, !candidates.isEmpty else { return [] }

        var matches: [(eventPhotoId: String, libraryPhotoId: String, distance: Float)] = []
        let total = eventPhotos.count

        for (index, eventPhoto) in eventPhotos.enumerated() {
            if Task.isCancelled { break }
            progress?(Progress(current: index + 1, total: total))

            let prefiltered = candidates.filter { isNearIdenticalCandidate(eventPhoto, $0) }
            guard !prefiltered.isEmpty else { continue }

            var scored: [(photoId: String, distance: Float)] = []
            scored.reserveCapacity(prefiltered.count)

            for candidate in prefiltered {
                if Task.isCancelled { break }
                guard let distance = await PhotoVisualSimilarity.distance(
                    between: eventPhoto.id,
                    and: candidate.id
                ),
                    distance <= PhotoVisualSimilarity.maxNearIdenticalDistance
                else {
                    continue
                }
                scored.append((candidate.id, distance))
            }

            scored.sort { $0.distance < $1.distance }
            for hit in scored.prefix(maxMatchesPerEventPhoto) {
                matches.append(
                    (
                        eventPhotoId: eventPhoto.id,
                        libraryPhotoId: hit.photoId,
                        distance: hit.distance
                    )
                )
            }
        }

        return matches
    }

    /// Metadata gate before Vision — no time window (screenshots often differ in capture date).
    static func isNearIdenticalCandidate(_ left: IndexedPhoto, _ right: IndexedPhoto) -> Bool {
        // Allow looser aspect when orientation differs (screenshot of a rotated original).
        let aspectLimit = left.orientation == right.orientation
            ? aspectRatioTolerance
            : aspectRatioTolerance * 2
        if abs(left.aspectRatio - right.aspectRatio) > aspectLimit {
            return false
        }
        return dimensionsAreCompatible(left, right)
    }

    private static func dimensionsAreCompatible(_ left: IndexedPhoto, _ right: IndexedPhoto) -> Bool {
        guard left.width > 0, left.height > 0, right.width > 0, right.height > 0 else {
            return true
        }

        let widthDelta = abs(Double(left.width - right.width)) / Double(max(left.width, right.width))
        let heightDelta = abs(Double(left.height - right.height)) / Double(max(left.height, right.height))
        if widthDelta <= dimensionTolerance && heightDelta <= dimensionTolerance {
            return true
        }

        // Screenshot of a photo: one side often matches while the other is cropped/scaled.
        let minSideDelta = min(widthDelta, heightDelta)
        return minSideDelta <= dimensionTolerance
    }
}
