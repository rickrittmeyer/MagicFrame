import SwiftUI

/// Compatibility wrapper — Christmas Developer uses the shared holiday developer tools.
struct ChristmasDeveloperView: View {
    @ObservedObject var vm: LibraryViewModel

    var body: some View {
        HolidayDeveloperView(tagValue: "Christmas", vm: vm)
    }
}
