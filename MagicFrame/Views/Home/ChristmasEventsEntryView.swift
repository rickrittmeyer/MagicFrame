import SwiftUI

/// Compatibility wrapper — Christmas Events uses the shared holiday events pipeline.
struct ChristmasEventsEntryView: View {
    @ObservedObject var vm: LibraryViewModel

    var body: some View {
        HolidayEventsEntryView(tagValue: "Christmas", vm: vm)
    }
}
