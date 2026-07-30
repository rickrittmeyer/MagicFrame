import SwiftUI

struct OccasionAddPhotosSheet: View {

    let item: OccasionLandingItem
    @ObservedObject var vm: LibraryViewModel

    @Environment(\.dismiss) private var dismiss

    @State private var showsPeopleWizard = false
    @State private var showsEventCollections = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(addIntro)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section("Add photos") {
                    Button {
                        showsEventCollections = true
                    } label: {
                        Label("Add by event", systemImage: "calendar.badge.plus")
                    }

                    Button {
                        showsPeopleWizard = true
                    } label: {
                        Label("Add by people", systemImage: "person.2.badge.plus")
                    }
                }
            }
            .navigationTitle("Add \(item.name) Pics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .navigationDestination(isPresented: $showsEventCollections) {
                EventsLibraryScreen(
                    filter: item.eventListFilter,
                    vm: vm
                )
                .navigationTitle("\(item.name) Events")
            }
            .sheet(isPresented: $showsPeopleWizard) {
                OccasionPeopleAddPhotosSheet(item: item, vm: vm)
            }
        }
    }

    private var addIntro: String {
        if item.isBirthday {
            return "Choose photos from collections near this birthday, or search your library for photos of this person."
        }
        switch item.occasionKey {
        case "fathers_day":
            return "Choose photos from Father's Day events, or search your library for photos of Dad with children."
        default:
            return "Choose photos from Mother's Day events, or search your library for photos of Mom with children."
        }
    }
}
