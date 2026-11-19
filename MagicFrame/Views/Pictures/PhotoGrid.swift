import SwiftUI

struct PhotoGridSection: Identifiable {
    let id: String
    let items: [EventPhotoDisplayItem]
}

/// The photo grid used everywhere a set of pictures is shown.
/// Trip days and other groupings are section headers above this same grid.
struct PhotoGrid<Header: View, Menu: View>: View {
    let sections: [PhotoGridSection]
    var isSelecting: Bool
    var selectedPhotoIds: Set<String>
    var allowsContextMenu: Bool
    /// When false, section headers still render but do not pin (e.g. under a sticky controls bar).
    var pinsSectionHeaders: Bool
    let onTap: (EventPhotoDisplayItem) -> Void
    @ViewBuilder let sectionHeader: (PhotoGridSection) -> Header
    @ViewBuilder let contextMenu: (EventPhotoDisplayItem) -> Menu

    @State private var playingVideoId: String?

    private let gridSpacing: CGFloat = 2
    private let onFrameBorderColor = Color(red: 0.29, green: 0.55, blue: 0.86)
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: gridSpacing), count: 3)
    }

    init(
        sections: [PhotoGridSection],
        isSelecting: Bool = false,
        selectedPhotoIds: Set<String> = [],
        allowsContextMenu: Bool = true,
        pinsSectionHeaders: Bool = true,
        onTap: @escaping (EventPhotoDisplayItem) -> Void,
        @ViewBuilder sectionHeader: @escaping (PhotoGridSection) -> Header,
        @ViewBuilder contextMenu: @escaping (EventPhotoDisplayItem) -> Menu
    ) {
        self.sections = sections
        self.isSelecting = isSelecting
        self.selectedPhotoIds = selectedPhotoIds
        self.allowsContextMenu = allowsContextMenu
        self.pinsSectionHeaders = pinsSectionHeaders
        self.onTap = onTap
        self.sectionHeader = sectionHeader
        self.contextMenu = contextMenu
    }

    var body: some View {
        LazyVStack(
            alignment: .leading,
            spacing: 20,
            pinnedViews: pinsSectionHeaders ? [.sectionHeaders] : []
        ) {
            ForEach(sections) { section in
                Section {
                    LazyVGrid(columns: columns, spacing: gridSpacing) {
                        ForEach(section.items) { item in
                            cell(item)
                        }
                    }
                } header: {
                    sectionHeader(section)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(section.id)
                }
            }
        }
        .onChange(of: isSelecting) { _, selecting in
            if selecting {
                playingVideoId = nil
            }
        }
    }

    @ViewBuilder
    private func cell(_ item: EventPhotoDisplayItem) -> some View {
        let photo = item.representative
        let isSelected = selectedPhotoIds.contains(photo.id)
        let core = cellBody(item: item, photo: photo, isSelected: isSelected)

        if allowsContextMenu, !isSelecting {
            core.contextMenu {
                contextMenu(item)
            }
        } else {
            core
        }
    }

    private func cellBody(
        item: EventPhotoDisplayItem,
        photo: IndexedPhoto,
        isSelected: Bool
    ) -> some View {
        ZStack {
            if playingVideoId == photo.id, !isSelecting {
                InlineVideoPlayer(assetIdentifier: photo.id)
                    .aspectRatio(1, contentMode: .fill)
                    .clipped()
            } else {
                Group {
                    if item.isStack {
                        PhotoGridStackCell(
                            representative: photo,
                            extraCount: item.extraCount
                        )
                    } else {
                        PhotoThumbnailView(
                            assetIdentifier: photo.id,
                            cornerRadius: 0,
                            quality: .high,
                            showsVideoBadge: false,
                            isVideo: photo.isVideo
                        )
                        .id(photo.id)
                        .aspectRatio(1, contentMode: .fill)
                        .clipped()
                    }
                }
                .overlay {
                    if photo.showOnFrame {
                        RoundedRectangle(cornerRadius: 0)
                            .strokeBorder(Color.black.opacity(0.55), lineWidth: 1)
                        RoundedRectangle(cornerRadius: 0)
                            .strokeBorder(onFrameBorderColor, lineWidth: 5)
                            .padding(1)
                    }
                }
                .overlay {
                    if isSelecting {
                        RoundedRectangle(cornerRadius: 0)
                            .strokeBorder(
                                isSelected ? Color.accentColor : Color.white.opacity(0.6),
                                lineWidth: isSelected ? 3 : 1
                            )
                        RoundedRectangle(cornerRadius: 0)
                            .fill(isSelected ? Color.accentColor.opacity(0.25) : Color.black.opacity(0.12))
                    }
                }
                .overlay {
                    if photo.isHiddenInEvent {
                        RoundedRectangle(cornerRadius: 0)
                            .fill(Color.black.opacity(0.35))
                    }
                }
                .overlay(alignment: .topLeading) {
                    if !isSelecting, photo.isHiddenInEvent || photo.isFavorite {
                        HStack(spacing: 2) {
                            if photo.isHiddenInEvent {
                                Image(systemName: "eye.slash")
                                    .font(.caption2)
                                    .foregroundStyle(.white)
                                    .padding(5)
                                    .background(.black.opacity(0.35), in: Circle())
                            }
                            if photo.isFavorite {
                                Image(systemName: "heart.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.white)
                                    .padding(5)
                                    .background(.black.opacity(0.35), in: Circle())
                            }
                        }
                        .padding(4)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if isSelecting {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(
                                isSelected ? Color.white : Color.white.opacity(0.9),
                                isSelected ? Color.accentColor : Color.black.opacity(0.35)
                            )
                            .padding(6)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    onTap(item)
                }

                if !isSelecting, photo.isVideo {
                    Button {
                        playingVideoId = photo.id
                    } label: {
                        VideoPlayIcon(size: 36)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Play video")
                }
            }
        }
    }
}

extension PhotoGrid where Header == EmptyView {
    init(
        items: [EventPhotoDisplayItem],
        isSelecting: Bool = false,
        selectedPhotoIds: Set<String> = [],
        allowsContextMenu: Bool = true,
        onTap: @escaping (EventPhotoDisplayItem) -> Void,
        @ViewBuilder contextMenu: @escaping (EventPhotoDisplayItem) -> Menu
    ) {
        self.init(
            sections: [PhotoGridSection(id: "photos", items: items)],
            isSelecting: isSelecting,
            selectedPhotoIds: selectedPhotoIds,
            allowsContextMenu: allowsContextMenu,
            onTap: onTap,
            sectionHeader: { _ in EmptyView() },
            contextMenu: contextMenu
        )
    }
}

/// Loads indexed photos, groups similar shots, and shows the shared photo grid.
struct FetchedPhotoGrid: View {
    let photoIds: [String]
    var onOpen: (String) -> Void

    @State private var items: [EventPhotoDisplayItem] = []

    var body: some View {
        PhotoGrid(
            items: items,
            allowsContextMenu: false,
            onTap: { item in
                onOpen(item.representative.id)
            },
            contextMenu: { _ in
                EmptyView()
            }
        )
        .task(id: photoIds) {
            let ids = photoIds
            let records = AppDependencies.database.fetchPhotosForBrowser(photoIds: ids)
            let photos = records.map(\.photo).sorted { $0.creationDate < $1.creationDate }
            items = Array(EventSimilarPhotoGrouper.displayItems(from: photos).reversed())
            let refined = await EventSimilarPhotoGrouper.refinedDisplayItems(from: photos)
            guard !Task.isCancelled else { return }
            items = Array(refined.reversed())
        }
    }
}

private struct PhotoGridStackCell: View {
    let representative: IndexedPhoto
    let extraCount: Int

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                if extraCount >= 2 {
                    stackLayer(offset: CGSize(width: 8, height: -8), opacity: 0.35)
                }
                if extraCount >= 1 {
                    stackLayer(offset: CGSize(width: 4, height: -4), opacity: 0.55)
                }

                PhotoThumbnailView(
                    assetIdentifier: representative.id,
                    cornerRadius: 0,
                    quality: .high,
                    showsVideoBadge: false,
                    isVideo: representative.isVideo
                )
            }
            .aspectRatio(1, contentMode: .fill)
            .clipped()

            if extraCount > 0 {
                Text("+\(extraCount)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(6)
            }
        }
    }

    private func stackLayer(offset: CGSize, opacity: Double) -> some View {
        RoundedRectangle(cornerRadius: 0)
            .fill(Color(.secondarySystemFill))
            .overlay {
                RoundedRectangle(cornerRadius: 0)
                    .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
            }
            .aspectRatio(1, contentMode: .fill)
            .offset(offset)
            .opacity(opacity)
    }
}
