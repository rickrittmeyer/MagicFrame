import SwiftUI

struct OccasionFrameLandingView: View {

    let item: OccasionLandingItem
    @ObservedObject var vm: LibraryViewModel

    @State private var showsAddPhotosSheet = false

    private let photoColumns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                onFrameSection
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add") {
                    showsAddPhotosSheet = true
                }
            }
        }
        .sheet(isPresented: $showsAddPhotosSheet, onDismiss: {
            Task {
                await vm.refreshOccasionFrameLanding(for: item)
            }
        }) {
            OccasionAddPhotosSheet(item: item, vm: vm)
        }
        .task(id: item.occasionKey) {
            await vm.refreshOccasionFrameLanding(for: item)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(nextOccurrenceLabel, systemImage: "calendar")
                .font(.subheadline)
                .foregroundStyle(.primary)

            Text(collectionCountLabel)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(onFrameCountLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(themeTint.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(themeTint.opacity(0.3), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var onFrameSection: some View {
        if vm.isLoadingOccasionFrame && vm.occasionFrameSnapshot == nil {
            ProgressView("Loading photos on frame…")
                .frame(maxWidth: .infinity)
                .padding(.top, 24)
        } else if let snapshot = vm.occasionFrameSnapshot {
            if snapshot.onFramePhotoIds.isEmpty {
                ContentUnavailableView(
                    "No Photos on Frame",
                    systemImage: "photo.on.rectangle.angled",
                    description: Text(
                        "Add \(item.name) photos from tagged events or pick photos of family members."
                    )
                )
                .padding(.top, 12)
            } else {
                Text("On frame")
                    .font(.headline)

                LazyVGrid(columns: photoColumns, spacing: 8) {
                    ForEach(snapshot.onFramePhotoIds, id: \.self) { photoId in
                        OccasionFramePhotoCell(
                            photoId: photoId,
                            tint: themeTint,
                            onRemove: {
                                vm.removePhotoFromOccasionFrame(
                                    photoId: photoId,
                                    occasionKey: item.occasionKey
                                )
                            }
                        )
                    }
                }
            }
        }
    }

    private var nextOccurrenceLabel: String {
        item.nextOccurrenceLabel
    }

    private var collectionCountLabel: String {
        let count = vm.occasionFrameSnapshot?.collectionCount ?? item.collectionCount
        guard let count else { return "… collections" }
        return count == 1 ? "1 collection" : "\(count.formatted()) collections"
    }

    private var onFrameCountLabel: String {
        let count = vm.occasionFrameSnapshot?.onFramePhotoIds.count ?? item.onFramePhotoCount
        guard let count else { return "… of pics on frame" }
        if count == 1 {
            return "1 of pic on frame"
        }
        return "\(count.formatted()) of pics on frame"
    }

    private var themeTint: Color {
        switch item.occasionKey {
        case "mothers_day":
            return Color(red: 0.92, green: 0.45, blue: 0.62)
        case "fathers_day":
            return Color(red: 0.3, green: 0.52, blue: 0.82)
        default:
            return Color(red: 0.55, green: 0.45, blue: 0.85)
        }
    }
}

private struct OccasionFramePhotoCell: View {

    let photoId: String
    let tint: Color
    let onRemove: () -> Void

    var body: some View {
        PhotoThumbnailView(
            assetIdentifier: photoId,
            cornerRadius: 10,
            quality: .fast,
            cropContext: .frame
        )
        .aspectRatio(1, contentMode: .fit)
        .overlay(alignment: .topTrailing) {
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, tint.opacity(0.9))
                    .padding(6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove from frame")
        }
    }
}
