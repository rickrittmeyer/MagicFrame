import CoreGraphics
import Foundation

/// Applies detect/embed results, clusters faces, and names/merges people.
final class FaceRecognitionService {

    static let photoPeopleSource = "face"

    /// Reload matching gallery every N photos so memory stays bounded during long scans.
    private static let matchingCacheRefreshInterval = 40
    /// Clusters kept in the live matching gallery (× exemplarsPerCluster embeddings).
    private static let maxCachedClusters = 120
    private static let exemplarsPerCluster = 2
    private static let maxFacesAppliedPerPhoto = 20
    /// During rebuild, only keep this many embeddings per cluster for matching.
    private static let rebuildExemplarsPerCluster = 2
    /// Pairwise consolidate is O(n²) and jetsams easily — keep this tiny.
    private static let consolidateMaxClusters = 80
    private static let consolidateExemplarsPerCluster = 1

    private let database: DatabaseManager
    private let faces: FaceRecognitionRepository
    private let people: PeopleRepository

    private var cachedNamedExemplars: [(personId: Int, embedding: Data)] = []
    private var cachedClusterExemplars: [(clusterId: Int, embedding: Data)] = []
    private var cachedClusterSizes: [Int: Int] = [:]
    private var photosProcessedWithCache = 0

    init(
        database: DatabaseManager,
        faces: FaceRecognitionRepository,
        people: PeopleRepository
    ) {
        self.database = database
        self.faces = faces
        self.people = people
    }

    /// Drop in-memory matching galleries (call after rebuild / large naming changes).
    func clearMatchingCache() {
        cachedNamedExemplars = []
        cachedClusterExemplars = []
        cachedClusterSizes = [:]
        photosProcessedWithCache = 0
    }

    /// Full reset: faces, clusters, face-named people links, and scan stamps.
    func resetAllFaceRecognitionData() {
        clearMatchingCache()
        database.sync {
            faces.wipeAllFaceRecognitionDataUnsafe()
            people.wipeFaceRecognitionPeopleUnsafe(faceSource: Self.photoPeopleSource)
        }
    }

    /// Detect + embed already ran; persist faces, match/cluster, stamp photo version.
    func applyScanResult(
        photoId: String,
        detections: [DetectedFaceCandidate],
        algorithmVersion: Int
    ) {
        let createdAt = ISO8601DateFormatter().string(from: Date())
        database.sync {
            applyScanResultUnsafe(
                photoId: photoId,
                detections: detections,
                algorithmVersion: algorithmVersion,
                createdAt: createdAt
            )
        }
    }

    func applyScanResultUnsafe(
        photoId: String,
        detections: [DetectedFaceCandidate],
        algorithmVersion: Int,
        createdAt: String
    ) {
        // Detect + embed only. Clustering / naming happen later (Rebuild + Show Faces).
        faces.deleteFaceInstancesForPhotoUnsafe(photoId: photoId)

        let detectionsToApply = Array(detections.prefix(Self.maxFacesAppliedPerPhoto))
        for detection in detectionsToApply {
            _ = faces.insertFaceInstanceUnsafe(
                photoId: photoId,
                bboxX: detection.boundingBox.origin.x,
                bboxY: detection.boundingBox.origin.y,
                bboxWidth: detection.boundingBox.size.width,
                bboxHeight: detection.boundingBox.size.height,
                quality: detection.quality,
                embeddingBlob: detection.embeddingData,
                embeddingVersion: FaceRecognitionAnalyzer.embeddingVersion,
                clusterId: nil,
                personId: nil,
                createdAt: createdAt
            )
        }

        faces.markPhotoFaceRecognitionVersionUnsafe(photoId: photoId, version: algorithmVersion)
    }

    private func refreshMatchingCacheIfNeededUnsafe() {
        let shouldRefresh =
            cachedClusterExemplars.isEmpty
            || photosProcessedWithCache >= Self.matchingCacheRefreshInterval
        guard shouldRefresh else { return }

        let retainIds = Array(
            Set(cachedClusterExemplars.map(\.clusterId)).prefix(150)
        )

        cachedNamedExemplars = faces.fetchNamedPersonExemplarsUnsafe(
            limitPerPerson: 8,
            maxPeople: 200
        )

        var byCluster: [Int: [Data]] = [:]
        let primary = faces.fetchUnassignedClusterExemplarsUnsafe(
            limitPerCluster: Self.exemplarsPerCluster,
            maxClusters: Self.maxCachedClusters
        )
        for item in primary {
            var list = byCluster[item.clusterId, default: []]
            if list.count < Self.exemplarsPerCluster {
                list.append(item.embedding)
                byCluster[item.clusterId] = list
            }
        }

        // Keep identities we were matching against mid-scan so they don't vanish on refresh.
        let missing = retainIds.filter { byCluster[$0] == nil }
        if !missing.isEmpty {
            let retained = faces.fetchExemplarsForClusterIdsUnsafe(
                clusterIds: missing,
                limitPerCluster: Self.exemplarsPerCluster
            )
            for item in retained {
                var list = byCluster[item.clusterId, default: []]
                if list.count < Self.exemplarsPerCluster {
                    list.append(item.embedding)
                    byCluster[item.clusterId] = list
                }
            }
        }

        var merged: [(clusterId: Int, embedding: Data)] = []
        for (clusterId, embeddings) in byCluster {
            for embedding in embeddings.prefix(Self.exemplarsPerCluster) {
                merged.append((clusterId, embedding))
            }
        }
        if merged.count > Self.maxCachedClusters * Self.exemplarsPerCluster {
            merged = Array(merged.prefix(Self.maxCachedClusters * Self.exemplarsPerCluster))
        }
        cachedClusterExemplars = merged
        cachedClusterSizes = faces.fetchUnnamedClusterFaceCountsUnsafe(
            maxClusters: Self.maxCachedClusters + retainIds.count
        )
        photosProcessedWithCache = 0
    }

    private func appendClusterExemplar(
        clusterId: Int,
        embedding: Data,
        to exemplars: inout [(clusterId: Int, embedding: Data)],
        limitPerCluster: Int
    ) {
        let existing = exemplars.filter { $0.clusterId == clusterId }.count
        if existing < limitPerCluster {
            exemplars.append((clusterId, embedding))
            return
        }
        // Already have enough exemplars for this cluster — leave the earlier (usually better) ones.
    }

    /// Keep exemplars for the largest clusters — never drop them in favor of brand-new singletons.
    private func trimExemplarsToLargestClusters(
        _ exemplars: [(clusterId: Int, embedding: Data)],
        sizes: [Int: Int],
        maxClusters: Int,
        limitPerCluster: Int
    ) -> [(clusterId: Int, embedding: Data)] {
        guard !exemplars.isEmpty else { return [] }
        let uniqueIds = Set(exemplars.map(\.clusterId))
        guard uniqueIds.count > maxClusters else { return exemplars }

        let keep = Set(
            uniqueIds
                .sorted { (sizes[$0] ?? 0) > (sizes[$1] ?? 0) }
                .prefix(maxClusters)
        )
        var kept: [(clusterId: Int, embedding: Data)] = []
        var counts: [Int: Int] = [:]
        for item in exemplars where keep.contains(item.clusterId) {
            let used = counts[item.clusterId, default: 0]
            guard used < limitPerCluster else { continue }
            kept.append(item)
            counts[item.clusterId] = used + 1
        }
        return kept
    }

    // MARK: - Naming / merge

    func fetchFaceAnnotations(forPhotoId photoId: String) -> [PhotoFaceAnnotation] {
        database.sync {
            faces.fetchFaceAnnotationsForPhotoUnsafe(photoId: photoId)
        }
    }

    /// Names a face from photo preview. Creates a singleton cluster when the face is still unclustered.
    @discardableResult
    func nameFaceInstance(
        faceInstanceId: Int,
        displayName: String,
        firstName: String?,
        lastName: String?,
        maidenName: String?
    ) -> Int {
        database.sync {
            nameFaceInstanceUnsafe(
                faceInstanceId: faceInstanceId,
                displayName: displayName,
                firstName: firstName,
                lastName: lastName,
                maidenName: maidenName
            )
        }
    }

    func nameFaceInstanceUnsafe(
        faceInstanceId: Int,
        displayName: String,
        firstName: String?,
        lastName: String?,
        maidenName: String?
    ) -> Int {
        guard let face = faces.fetchFaceInstanceUnsafe(faceInstanceId: faceInstanceId) else {
            return -1
        }

        let updatedAt = ISO8601DateFormatter().string(from: Date())
        let clusterId: Int
        if let existing = face.clusterId, existing > 0 {
            clusterId = existing
        } else {
            let created = faces.createClusterUnsafe(
                representativeFaceInstanceId: face.faceInstanceId,
                createdAt: updatedAt
            )
            guard created > 0 else { return -1 }
            faces.updateFaceInstanceAssignmentUnsafe(
                faceInstanceId: face.faceInstanceId,
                clusterId: created,
                personId: face.personId
            )
            faces.refreshClusterStatsUnsafe(clusterId: created, updatedAt: updatedAt)
            clusterId = created
        }

        return nameClusterUnsafe(
            clusterId: clusterId,
            displayName: displayName,
            firstName: firstName,
            lastName: lastName,
            maidenName: maidenName
        )
    }

    /// After naming a face in preview, copy that person onto matching faces in sibling similar photos.
    /// Matching is embedding-first with bbox IoU as a tie-breaker. Skips differently named faces.
    @discardableResult
    func propagateNamedFaceToSimilarPhotos(
        sourceFaceInstanceId: Int,
        siblingPhotoIds: [String]
    ) async -> Int {
        let sourceContext: (embedding: Data, clusterId: Int, personId: Int, bbox: CGRect)? = database.sync {
            guard let source = faces.fetchFaceInstanceUnsafe(faceInstanceId: sourceFaceInstanceId),
                  let personId = source.personId, personId > 0,
                  let clusterId = source.clusterId, clusterId > 0,
                  !source.embeddingBlob.isEmpty else {
                return nil
            }
            return (
                embedding: source.embeddingBlob,
                clusterId: clusterId,
                personId: personId,
                bbox: source.faceBoundingBox
            )
        }
        guard let sourceContext else { return 0 }

        var assignedCount = 0
        for photoId in siblingPhotoIds {
            _ = await ensurePhotoFaceScanned(photoId: photoId)
            let didAssign = database.sync {
                assignMatchingFaceOnPhotoUnsafe(
                    photoId: photoId,
                    sourceEmbedding: sourceContext.embedding,
                    sourceBBox: sourceContext.bbox,
                    namedClusterId: sourceContext.clusterId,
                    personId: sourceContext.personId
                )
            }
            if didAssign {
                assignedCount += 1
            }
        }
        return assignedCount
    }

    /// Best matching unnamed (or same-person) face on `photoId`; attaches it to the named cluster.
    private func assignMatchingFaceOnPhotoUnsafe(
        photoId: String,
        sourceEmbedding: Data,
        sourceBBox: CGRect,
        namedClusterId: Int,
        personId: Int
    ) -> Bool {
        struct ScoredFace {
            let face: FaceInstanceRecord
            let distance: Float
            let iou: Double
        }

        var scored: [ScoredFace] = []
        for candidate in faces.fetchFaceInstancesForPhotoUnsafe(photoId: photoId) {
            if let existingPerson = candidate.personId, existingPerson > 0 {
                // Already labeled — never overwrite a different person; skip same person too.
                continue
            }
            guard !candidate.embeddingBlob.isEmpty,
                  let distance = FaceRecognitionAnalyzer.distance(
                    between: sourceEmbedding,
                    and: candidate.embeddingBlob
                  ),
                  distance <= FaceRecognitionAnalyzer.namedMatchDistanceThreshold else {
                continue
            }
            scored.append(
                ScoredFace(
                    face: candidate,
                    distance: distance,
                    iou: Self.intersectionOverUnion(sourceBBox, candidate.faceBoundingBox)
                )
            )
        }

        scored.sort { lhs, rhs in
            if abs(lhs.distance - rhs.distance) < FaceRecognitionAnalyzer.matchMargin {
                return lhs.iou > rhs.iou
            }
            return lhs.distance < rhs.distance
        }

        guard let best = scored.first else { return false }

        if let second = scored.dropFirst().first,
           !isClearWinner(best: best.distance, second: second.distance) {
            // Embedding tie — require a clearly better spatial overlap in the burst.
            guard best.iou >= 0.15, best.iou > second.iou + 0.05 else {
                return false
            }
        }

        let updatedAt = ISO8601DateFormatter().string(from: Date())
        if let targetCluster = best.face.clusterId,
           targetCluster > 0,
           targetCluster != namedClusterId {
            faces.mergeClusterIntoClusterUnsafe(
                sourceClusterId: targetCluster,
                destinationClusterId: namedClusterId,
                updatedAt: updatedAt
            )
        }

        faces.updateFaceInstanceAssignmentUnsafe(
            faceInstanceId: best.face.faceInstanceId,
            clusterId: namedClusterId,
            personId: personId
        )
        people.linkPhotoToPersonUnsafe(
            photoId: photoId,
            personId: personId,
            source: Self.photoPeopleSource
        )
        faces.refreshClusterStatsUnsafe(clusterId: namedClusterId, updatedAt: updatedAt)
        return true
    }

    private static func intersectionOverUnion(_ lhs: CGRect, _ rhs: CGRect) -> Double {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        let intersectionArea = intersection.width * intersection.height
        let unionArea = (lhs.width * lhs.height) + (rhs.width * rhs.height) - intersectionArea
        guard unionArea > 0 else { return 0 }
        return Double(intersectionArea / unionArea)
    }

    /// Scans a single photo if it is below the current face algorithm version. Returns annotations.
    /// Preview path uses high-quality decode so rectangles are more reliable than bulk fast scans.
    func ensurePhotoFaceScanned(photoId: String) async -> [PhotoFaceAnnotation] {
        let algorithmVersion = FaceRecognitionAnalyzer.algorithmVersion
        let needsScan = database.sync {
            faces.faceRecognitionVersionUnsafe(photoId: photoId) < algorithmVersion
        }
        if needsScan {
        let detections = await FaceRecognitionAnalyzer.analyze(
            assetIdentifier: photoId,
            preferFastDecode: false,
            targetPixelSize: FaceRecognitionAnalyzer.previewScanTargetPixelSize
        )
            autoreleasepool {
                applyScanResult(
                    photoId: photoId,
                    detections: detections,
                    algorithmVersion: algorithmVersion
                )
            }
        }
        return fetchFaceAnnotations(forPhotoId: photoId)
    }

    func nameCluster(
        clusterId: Int,
        displayName: String,
        firstName: String?,
        lastName: String?,
        maidenName: String?
    ) -> Int {
        database.sync {
            nameClusterUnsafe(
                clusterId: clusterId,
                displayName: displayName,
                firstName: firstName,
                lastName: lastName,
                maidenName: maidenName
            )
        }
    }

    func nameClusterUnsafe(
        clusterId: Int,
        displayName: String,
        firstName: String?,
        lastName: String?,
        maidenName: String?
    ) -> Int {
        let personId = people.upsertPersonUnsafe(
            displayName: displayName,
            firstName: firstName,
            lastName: lastName,
            maidenName: maidenName
        )
        guard personId > 0 else { return -1 }
        mergeClusterIntoPersonUnsafe(clusterId: clusterId, personId: personId)
        return personId
    }

    func mergeClusterIntoPerson(clusterId: Int, personId: Int) {
        database.sync {
            mergeClusterIntoPersonUnsafe(clusterId: clusterId, personId: personId)
        }
    }

    func mergeClusterIntoPersonUnsafe(clusterId: Int, personId: Int) {
        let updatedAt = ISO8601DateFormatter().string(from: Date())
        faces.assignClusterToPersonUnsafe(
            clusterId: clusterId,
            personId: personId,
            updatedAt: updatedAt
        )
        let photoIds = faces.fetchPhotoIdsForClusterUnsafe(clusterId: clusterId)
        for photoId in photoIds {
            people.linkPhotoToPersonUnsafe(
                photoId: photoId,
                personId: personId,
                source: Self.photoPeopleSource
            )
        }
        faces.refreshClusterStatsUnsafe(clusterId: clusterId, updatedAt: updatedAt)
    }

    func ignoreCluster(clusterId: Int) {
        database.sync {
            let updatedAt = ISO8601DateFormatter().string(from: Date())
            faces.ignoreClusterUnsafe(clusterId: clusterId, updatedAt: updatedAt)
        }
    }

    /// Conservative merge of clearly-similar unnamed clusters (manual button).
    @discardableResult
    func consolidateUnnamedClusters() -> Int {
        database.sync {
            consolidateUnnamedClustersUnsafe(
                updatedAt: ISO8601DateFormatter().string(from: Date())
            )
        }
    }

    /// Tear down over-merged unnamed clusters and rebuild from stored embeddings.
    @discardableResult
    func rebuildUnnamedClusters() -> Int {
        clearMatchingCache()
        return database.sync {
            rebuildUnnamedClustersUnsafe(
                updatedAt: ISO8601DateFormatter().string(from: Date())
            )
        }
    }

    @discardableResult
    func consolidateUnnamedClustersUnsafe(updatedAt: String) -> Int {
        // Hard-capped: pairwise consolidate is O(n²) and jetsams above ~100 clusters.
        // fetchUnassignedClusterExemplars already returns largest clusters first.
        let exemplars = faces.fetchUnassignedClusterExemplarsUnsafe(
            limitPerCluster: Self.consolidateExemplarsPerCluster,
            maxClusters: Self.consolidateMaxClusters
        )
        guard !exemplars.isEmpty else { return 0 }

        var byCluster: [Int: Data] = [:]
        var ids: [Int] = []
        for item in exemplars {
            if byCluster[item.clusterId] == nil {
                byCluster[item.clusterId] = item.embedding
                ids.append(item.clusterId)
            }
        }
        guard ids.count > 1 else { return 0 }

        var parent: [Int: Int] = Dictionary(uniqueKeysWithValues: ids.map { ($0, $0) })

        func find(_ id: Int) -> Int {
            var current = id
            while parent[current] != current {
                let p = parent[current] ?? current
                parent[current] = parent[p] ?? p
                current = parent[current] ?? current
            }
            return current
        }

        func union(_ a: Int, _ b: Int) {
            let ra = find(a)
            let rb = find(b)
            guard ra != rb else { return }
            if ra < rb { parent[rb] = ra } else { parent[ra] = rb }
        }

        let threshold = FaceRecognitionAnalyzer.clusterConsolidateDistanceThreshold
        for i in 0..<ids.count {
            let leftId = ids[i]
            guard let leftEmbedding = byCluster[leftId] else { continue }
            autoreleasepool {
                for j in (i + 1)..<ids.count {
                    let rightId = ids[j]
                    if find(leftId) == find(rightId) { continue }
                    guard let rightEmbedding = byCluster[rightId] else { continue }
                    if let distance = FaceRecognitionAnalyzer.distance(
                        between: leftEmbedding,
                        and: rightEmbedding
                    ), distance <= threshold {
                        union(leftId, rightId)
                    }
                }
            }
        }

        var merged = 0
        for clusterId in ids {
            let root = find(clusterId)
            guard root != clusterId else { continue }
            faces.mergeClusterIntoClusterUnsafe(
                sourceClusterId: clusterId,
                destinationClusterId: root,
                updatedAt: updatedAt
            )
            merged += 1
        }
        return merged
    }

    @discardableResult
    func rebuildUnnamedClustersUnsafe(updatedAt: String) -> Int {
        faces.dissolveUnnamedClustersUnsafe(updatedAt: updatedAt)

        // IDs first (cheap), then load embeddings in small batches.
        let faceIds = faces.fetchUnnamedFaceInstanceIdsForReclusterUnsafe()
        let namedExemplars = faces.fetchNamedPersonExemplarsUnsafe(
            limitPerPerson: 8,
            maxPeople: 200
        )
        var clusterExemplars: [(clusterId: Int, embedding: Data)] = []
        var clusterSizes: [Int: Int] = [:]
        var dirtyClusterIds = Set<Int>()
        var clusterCount = 0
        let batchSize = 150

        var start = 0
        while start < faceIds.count {
            let end = min(start + batchSize, faceIds.count)
            let batchIds = Array(faceIds[start..<end])
            start = end
            let batch = faces.fetchFaceInstancesForClusteringByIdsUnsafe(ids: batchIds)

            for instance in batch {
                autoreleasepool {
                    let match = bestMatch(
                        embedding: instance.embedding,
                        namedExemplars: namedExemplars,
                        clusterExemplars: clusterExemplars,
                        clusterSizes: clusterSizes
                    )

                    switch match {
                    case .named(let personId):
                        faces.updateFaceInstanceAssignmentUnsafe(
                            faceInstanceId: instance.faceInstanceId,
                            clusterId: nil,
                            personId: personId
                        )
                        people.linkPhotoToPersonUnsafe(
                            photoId: instance.photoId,
                            personId: personId,
                            source: Self.photoPeopleSource
                        )

                    case .cluster(let matchedClusterId):
                        faces.updateFaceInstanceAssignmentUnsafe(
                            faceInstanceId: instance.faceInstanceId,
                            clusterId: matchedClusterId,
                            personId: nil
                        )
                        dirtyClusterIds.insert(matchedClusterId)
                        appendClusterExemplar(
                            clusterId: matchedClusterId,
                            embedding: instance.embedding,
                            to: &clusterExemplars,
                            limitPerCluster: Self.rebuildExemplarsPerCluster
                        )
                        clusterSizes[matchedClusterId, default: 0] += 1

                    case .none:
                        let clusterId = faces.createClusterUnsafe(
                            representativeFaceInstanceId: instance.faceInstanceId,
                            createdAt: updatedAt
                        )
                        guard clusterId > 0 else { return }
                        clusterCount += 1
                        faces.updateFaceInstanceAssignmentUnsafe(
                            faceInstanceId: instance.faceInstanceId,
                            clusterId: clusterId,
                            personId: nil
                        )
                        dirtyClusterIds.insert(clusterId)
                        appendClusterExemplar(
                            clusterId: clusterId,
                            embedding: instance.embedding,
                            to: &clusterExemplars,
                            limitPerCluster: Self.rebuildExemplarsPerCluster
                        )
                        clusterSizes[clusterId, default: 0] += 1
                    }
                }
            }

            // Flush cluster stats periodically instead of after every face.
            if dirtyClusterIds.count >= 80 {
                for clusterId in dirtyClusterIds {
                    faces.refreshClusterStatsUnsafe(clusterId: clusterId, updatedAt: updatedAt)
                }
                dirtyClusterIds.removeAll(keepingCapacity: true)
            }

            // Bound matching gallery growth during long rebuilds — keep largest clusters.
            clusterExemplars = trimExemplarsToLargestClusters(
                clusterExemplars,
                sizes: clusterSizes,
                maxClusters: Self.maxCachedClusters,
                limitPerCluster: Self.rebuildExemplarsPerCluster
            )
        }

        for clusterId in dirtyClusterIds {
            faces.refreshClusterStatsUnsafe(clusterId: clusterId, updatedAt: updatedAt)
        }

        return clusterCount
    }

    func fetchUnnamedClusters() -> [PersonClusterRecord] {
        database.sync {
            faces.fetchUnnamedClustersUnsafe()
        }
    }

    func fetchPhotoIds(forPersonId personId: Int) -> [String] {
        database.sync {
            people.fetchPhotoIdsForPersonUnsafe(personId: personId)
        }
    }

    func fetchPhotoIds(forClusterId clusterId: Int) -> [String] {
        database.sync {
            faces.fetchPhotoIdsForClusterUnsafe(clusterId: clusterId)
        }
    }

    // MARK: - Matching

    private enum Match: Equatable {
        case named(Int)
        case cluster(Int)
        case none
    }

    private func bestMatch(
        embedding: Data,
        namedExemplars: [(personId: Int, embedding: Data)],
        clusterExemplars: [(clusterId: Int, embedding: Data)],
        clusterSizes: [Int: Int] = [:]
    ) -> Match {
        // Best distance per person first — comparing two exemplars of the *same* person
        // used to fail the margin check and reject good name matches.
        var bestByPerson: [Int: Float] = [:]
        for exemplar in namedExemplars {
            guard let distance = FaceRecognitionAnalyzer.distance(
                between: embedding,
                and: exemplar.embedding
            ) else { continue }
            let previous = bestByPerson[exemplar.personId] ?? .greatestFiniteMagnitude
            if distance < previous {
                bestByPerson[exemplar.personId] = distance
            }
        }

        let rankedPeople = bestByPerson.sorted { $0.value < $1.value }
        if let bestPerson = rankedPeople.first,
           bestPerson.value <= FaceRecognitionAnalyzer.namedMatchDistanceThreshold {
            let secondPerson = rankedPeople.dropFirst().first?.value
            if isClearWinner(best: bestPerson.value, second: secondPerson) {
                return .named(bestPerson.key)
            }
        }

        var bestByCluster: [Int: Float] = [:]
        for exemplar in clusterExemplars {
            guard let distance = FaceRecognitionAnalyzer.distance(
                between: embedding,
                and: exemplar.embedding
            ) else { continue }
            let previous = bestByCluster[exemplar.clusterId] ?? .greatestFiniteMagnitude
            if distance < previous {
                bestByCluster[exemplar.clusterId] = distance
            }
        }

        let ranked = bestByCluster.sorted { $0.value < $1.value }
        guard let best = ranked.first else { return .none }

        let size = clusterSizes[best.key] ?? 1
        let threshold = size >= FaceRecognitionAnalyzer.largeClusterFaceCount
            ? FaceRecognitionAnalyzer.largeClusterMatchDistanceThreshold
            : FaceRecognitionAnalyzer.clusterMatchDistanceThreshold
        let second = ranked.dropFirst().first?.value
        guard best.value <= threshold,
              isClearWinner(best: best.value, second: second) else {
            return .none
        }
        return .cluster(best.key)
    }

    private func isClearWinner(best: Float, second: Float?) -> Bool {
        guard let second else { return true }
        return (second - best) >= FaceRecognitionAnalyzer.matchMargin
    }

    private func bestPairDistance(_ left: [Data], _ right: [Data]) -> Float? {
        var best: Float?
        for a in left {
            for b in right {
                guard let distance = FaceRecognitionAnalyzer.distance(between: a, and: b) else {
                    continue
                }
                if best == nil || distance < best! {
                    best = distance
                }
            }
        }
        return best
    }
}
