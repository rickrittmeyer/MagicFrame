import SwiftUI

/// Compatibility wrapper — Christmas uses the shared holiday photos pipeline.
struct ChristmasTopicView: View {
    @ObservedObject var vm: LibraryViewModel

    var body: some View {
        HolidayTopicView(tagValue: "Christmas", vm: vm)
    }
}
