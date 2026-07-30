import UIKit

/// In-memory thumbnail cache so grid cells keep images across navigation / list reloads.
@MainActor
enum PhotoThumbnailImageCache {

    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 400
        return cache
    }()

    static func key(assetIdentifier: String, quality: String) -> String {
        "\(assetIdentifier)|\(quality)"
    }

    static func image(for key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    static func store(_ image: UIImage, for key: String) {
        cache.setObject(image, forKey: key as NSString)
    }
}
