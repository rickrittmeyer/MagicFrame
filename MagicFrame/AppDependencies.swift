import Foundation

/// Shared app services for production; override in tests or previews.
enum AppDependencies {
    static var container: AppContainer = .shared
    static var database: any MagicFrameDatabase { container.photoDatabase }
}
