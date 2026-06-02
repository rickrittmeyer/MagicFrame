import SwiftUI

struct ArchiveBatchesView: View {

    @ObservedObject var vm: ArchiveBatchesViewModel

    var body: some View {
        List {
            if vm.batches.isEmpty {
                ContentUnavailableView(
                    "No import batches",
                    systemImage: "photo.on.rectangle.angled",
                    description: Text("Photos without GPS will appear here grouped by likely upload session.")
                )
            } else {
                Section {
                    Text(vm.statusText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section("Likely upload batches") {
                    ForEach(vm.batches) { batch in
                        NavigationLink {
                            ArchiveBatchDetailView(vm: vm, batch: batch)
                        } label: {
                            ArchiveBatchRowView(batch: batch)
                        }
                    }
                }
            }
        }
        .navigationTitle("Archive Photos")
        .onAppear {
            vm.load()
        }
    }
}

private struct ArchiveBatchRowView: View {

    let batch: PhotoUploadBatch

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(batch.importDateSummary)
                .font(.headline)

            Text("\(batch.photoCount) photos · \(batch.statusSummary)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(batch.samplePhotoIds.prefix(6), id: \.self) { photoId in
                    PhotoThumbnailView(assetIdentifier: photoId, cornerRadius: 4)
                        .frame(height: 56)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
