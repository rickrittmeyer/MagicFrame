import SwiftUI

struct ArchiveBatchDetailView: View {

    @ObservedObject var vm: ArchiveBatchesViewModel
    let batch: PhotoUploadBatch

    @State private var captureDate: Date
    @State private var selectedLocationId: Int?
    @State private var didSave = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 4)

    init(vm: ArchiveBatchesViewModel, batch: PhotoUploadBatch) {
        self.vm = vm
        self.batch = batch
        _captureDate = State(initialValue: batch.assignedCaptureDate ?? batch.importStart)
        _selectedLocationId = State(initialValue: batch.assignedLocationId)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Imported")
                        .font(.headline)
                    Text(batch.importDateSummary)
                        .foregroundStyle(.secondary)
                    Text("\(batch.photoCount) photos without GPS")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(batch.samplePhotoIds.prefix(24), id: \.self) { photoId in
                        PhotoThumbnailView(assetIdentifier: photoId, cornerRadius: 6)
                            .frame(height: 78)
                    }
                }

                if batch.photoCount > 24 {
                    Text("+ \(batch.photoCount - 24) more in this batch")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("When were these taken?")
                        .font(.headline)

                    DatePicker(
                        "Capture date",
                        selection: $captureDate,
                        displayedComponents: [.date]
                    )
                    .datePickerStyle(.graphical)

                    Text("Use your best estimate — year is often enough for scans and old prints.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Where were these taken?")
                        .font(.headline)

                    if vm.locations.isEmpty {
                        Text("Add locations from the Locations screen first, or index geotagged photos to build locations automatically.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Location", selection: $selectedLocationId) {
                            Text("Choose a location").tag(nil as Int?)
                            ForEach(vm.locations) { location in
                                Text(location.displayTitle).tag(Optional(location.locationId))
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }

                Button("Save and add to events") {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedLocationId == nil)
            }
            .padding()
        }
        .navigationTitle("Assign batch")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Batch updated", isPresented: $didSave) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("\(batch.photoCount) photos will be grouped into events using the date and location you chose.")
        }
    }

    private func save() {
        guard let locationId = selectedLocationId,
              let location = vm.locations.first(where: { $0.locationId == locationId }) else {
            return
        }

        vm.applyMetadata(to: batch, captureDate: captureDate, location: location)
        didSave = true
    }
}
