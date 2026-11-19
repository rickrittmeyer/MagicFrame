import SwiftUI

/// Review near-identical library copies found by AI Assist; hide or delete chosen photos.
struct EventDuplicatesReviewSheet: View {
    let matches: [EventPhotoDuplicateMatch]
    let onCancel: () -> Void
    let onHide: (_ photoIds: [String]) -> Void
    let onDelete: (_ photoIds: [String]) -> Void

    @State private var selectedPhotoIds: Set<String> = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(
                        "Near-identical copies found in your library (re-imports or screenshots). Select photos to hide from their event or delete from Magic Frame and Apple Photos."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)

                    Button("Select All Photos with Later Creation Date") {
                        selectPhotosWithLaterCreationDate()
                    }
                    .disabled(laterCreationDatePhotoIds.isEmpty)
                }

                ForEach(matches) { match in
                    Section {
                        matchRow(match)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Duplicates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close", action: onCancel)
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Hide") {
                        onHide(Array(selectedPhotoIds))
                    }
                    .disabled(selectedPhotoIds.isEmpty)

                    Spacer()

                    Button("Delete", role: .destructive) {
                        onDelete(Array(selectedPhotoIds))
                    }
                    .disabled(selectedPhotoIds.isEmpty)
                }
            }
        }
    }

    private var laterCreationDatePhotoIds: Set<String> {
        Set(matches.compactMap(\.photoIdWithLaterCreationDate))
    }

    private func selectPhotosWithLaterCreationDate() {
        selectedPhotoIds = laterCreationDatePhotoIds
    }

    @ViewBuilder
    private func matchRow(_ match: EventPhotoDuplicateMatch) -> some View {
        HStack(alignment: .top, spacing: 12) {
            sideColumn(side: match.eventSide, caption: "This event")
            Image(systemName: "arrow.left.arrow.right")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 40)
            sideColumn(side: match.librarySide, caption: "Library copy")
        }
        .padding(.vertical, 4)
    }

    private func sideColumn(side: EventPhotoDuplicateSideInfo, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            selectableThumb(photoId: side.photoId, caption: caption)
            metaBlock(side)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func selectableThumb(photoId: String, caption: String) -> some View {
        let isSelected = selectedPhotoIds.contains(photoId)
        return Button {
            if isSelected {
                selectedPhotoIds.remove(photoId)
            } else {
                selectedPhotoIds.insert(photoId)
            }
        } label: {
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    PhotoThumbnailView(assetIdentifier: photoId, cornerRadius: 8)
                        .frame(maxWidth: .infinity)
                        .frame(height: 110)
                        .clipped()
                        .overlay {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.accentColor, lineWidth: 3)
                            }
                        }

                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(isSelected ? Color.white : Color.secondary, Color.accentColor)
                        .padding(4)
                }
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private func metaBlock(_ side: EventPhotoDuplicateSideInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            labeledValue("Date", side.dateTimeLine)
            labeledValue("Location", side.locationLine)
            labeledValue("Event", side.eventLine)
        }
        .font(.caption)
    }

    private func labeledValue(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
