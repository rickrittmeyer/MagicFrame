import AVFoundation
import Foundation
import ImageIO
import Photos

/// Reads still-image EXIF and video header metadata without downloading iCloud originals.
final class PhotoExifImportService {

    private let repository: PhotoExifRepository

    init(repository: PhotoExifRepository) {
        self.repository = repository
    }

    func importMissingExif(onProgress: @escaping @Sendable (String) -> Void) async {
        let photoIds = repository.fetchPhotoIdsNeedingExif()
        let total = photoIds.count
        guard total > 0 else {
            onProgress("EXIF already imported")
            return
        }

        onProgress("Reading EXIF… 0 of \(total.formatted())")
        let indexedAt = ISO8601DateFormatter().string(from: Date())
        var notLocal = 0
        var noHeader = 0
        var checked = 0

        for batchStart in stride(from: 0, to: total, by: 200) {
            let batchEnd = min(batchStart + 200, total)
            let batchIds = Array(photoIds[batchStart..<batchEnd])
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: batchIds, options: nil)
            var assetsById: [String: PHAsset] = [:]
            assets.enumerateObjects { asset, _, _ in
                assetsById[asset.localIdentifier] = asset
            }

            for photoId in batchIds {
                checked += 1
                if checked == 1 || checked == total || checked % 25 == 0 {
                    onProgress("Reading EXIF… \(checked.formatted()) of \(total.formatted())")
                }

                guard let asset = assetsById[photoId] else {
                    repository.upsert(
                        photoId: photoId,
                        record: PhotoExifRecord(status: "noHeader"),
                        indexedAt: indexedAt
                    )
                    noHeader += 1
                    continue
                }

                let record = await headerRecord(for: asset)
                if record.status == "notLocal" { notLocal += 1 }
                if record.status == "noHeader" { noHeader += 1 }
                repository.upsert(photoId: photoId, record: record, indexedAt: indexedAt)
            }
        }

        onProgress(
            "EXIF read for \(total.formatted()) items"
                + " (\(notLocal.formatted()) not on this device, \(noHeader.formatted()) without a header)"
        )
    }

    private struct ResolvedHeader {
        let imageURL: URL?
        let videoAsset: AVAsset?
        let inCloud: Bool
    }

    private func headerRecord(for asset: PHAsset) async -> PhotoExifRecord {
        let resolved = await withCheckedContinuation { (continuation: CheckedContinuation<ResolvedHeader, Never>) in
            DispatchQueue.main.async {
                let options = PHContentEditingInputRequestOptions()
                options.isNetworkAccessAllowed = false
                options.canHandleAdjustmentData = { _ in true }
                asset.requestContentEditingInput(with: options) { input, info in
                    let cloudValue = info[PHContentEditingInputResultIsInCloudKey]
                    let inCloud = (cloudValue as? NSNumber)?.boolValue ?? (cloudValue as? Bool) ?? false
                    continuation.resume(
                        returning: ResolvedHeader(
                            imageURL: input?.fullSizeImageURL,
                            videoAsset: input?.avAsset,
                            inCloud: inCloud
                        )
                    )
                }
            }
        }

        if let url = resolved.imageURL {
            return Self.readStill(at: url)
        }
        if let avAsset = resolved.videoAsset {
            return await Self.readVideo(avAsset)
        }
        return PhotoExifRecord(status: resolved.inCloud ? "notLocal" : "noHeader")
    }

    private static func readStill(at url: URL) -> PhotoExifRecord {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return PhotoExifRecord(status: "noHeader")
        }

        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any]

        let gpsDate = trimmed(gps?[kCGImagePropertyGPSDateStamp] as? String)
        let gpsTime = trimmed(gps?[kCGImagePropertyGPSTimeStamp] as? String)
        let gpsTimestamp: String? = {
            switch (gpsDate, gpsTime) {
            case let (date?, time?): return "\(date) \(time)"
            case let (date?, nil): return date
            case let (nil, time?): return time
            default: return nil
            }
        }()

        return PhotoExifRecord(
            dateTimeOriginal: trimmed(exif?[kCGImagePropertyExifDateTimeOriginal] as? String),
            dateTimeDigitized: trimmed(exif?[kCGImagePropertyExifDateTimeDigitized] as? String),
            gpsTimestamp: gpsTimestamp,
            imageUniqueId: trimmed(exif?[kCGImagePropertyExifImageUniqueID] as? String),
            cameraMake: trimmed(tiff?[kCGImagePropertyTIFFMake] as? String),
            cameraModel: trimmed(tiff?[kCGImagePropertyTIFFModel] as? String),
            lensModel: trimmed(exif?[kCGImagePropertyExifLensModel] as? String),
            status: "read"
        )
    }

    private static func readVideo(_ asset: AVAsset) async -> PhotoExifRecord {
        guard let items = try? await asset.load(.metadata) else {
            return PhotoExifRecord(status: "noHeader")
        }

        var original: String?
        var make: String?
        var model: String?
        for item in items {
            guard let identifier = item.identifier?.rawValue.lowercased(),
                  let value = trimmed(try? await item.load(.stringValue)) else {
                continue
            }
            if identifier.contains("creationdate") || identifier.hasSuffix("©day") {
                original = original ?? value
            } else if identifier.contains("quicktime.make") || identifier.hasSuffix("©mak") {
                make = make ?? value
            } else if identifier.contains("quicktime.model") || identifier.hasSuffix("©mod") {
                model = model ?? value
            }
        }

        return PhotoExifRecord(
            dateTimeOriginal: original,
            cameraMake: make,
            cameraModel: model,
            status: "read"
        )
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
