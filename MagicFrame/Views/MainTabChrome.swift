import SwiftUI

/// Bottom chrome under the Media stack and sibling tabs.
enum MainTabChromeMode: Equatable {
    /// Home and category hubs: Help | Developer only.
    case landing
    /// Topic browsers, event lists, Search, Developer: full tab set.
    case full
}

/// Media-stack deep link requested from another tab (e.g. Events back → Home / Holidays).
enum MediaNavigationRequest: Equatable {
    case home
    case holidaysHub
    /// All Events → All Media Photos.
    case allMediaPhotos
}

enum MediaRoute: Hashable {
    case holidays
    case allMediaPhotos
}
