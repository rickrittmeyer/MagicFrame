import SwiftUI

struct EventLibraryRowView: View {

    let event: IndexedEvent
    var slideshowPhotoIds: [String] = []
    var slideshowQuality: PhotoThumbnailView.Quality = .high
    var showsHiddenBadge: Bool = false
    var onHide: (() -> Void)? = nil
    var onUnhide: (() -> Void)? = nil
    var onConfirmAIAttributeTag: ((EventAttributeTag) -> Void)? = nil
    var onRemoveAIAttributeTag: ((EventAttributeTag) -> Void)? = nil

    @State private var isConfirmingHideEvent = false

    private let cornerRadius: CGFloat = 5
    /// Full-width banner uses 4:3 so height scales with row width.
    private let photoAspectRatio: CGFloat = 4.0 / 3.0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsHiddenBadge {
                if let onUnhide {
                    Button(action: onUnhide) {
                        Label("Hidden", systemImage: "eye.slash")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Unhide event")
                } else {
                    Label("Hidden", systemImage: "eye.slash")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            titleLine

            if !event.libraryAttributeTags.isEmpty {
                FlowLayout(spacing: 8, lineSpacing: 8) {
                    ForEach(event.libraryAttributeTags) { tag in
                        EventAttributeTagChip(
                            tag: tag,
                            showsCategoryIcon: true,
                            onConfirmAI: tag.isAIDerived
                                ? { onConfirmAIAttributeTag?(tag) }
                                : nil,
                            onRemoveAI: tag.isAIDerived
                                ? { onRemoveAIAttributeTag?(tag) }
                                : nil
                        )
                    }
                }
            }

            EventSlideshowRotatorView(
                photoIds: displaySlideshowPhotoIds,
                aspectRatio: photoAspectRatio,
                cornerRadius: cornerRadius,
                thumbnailQuality: slideshowQuality
            )

            locationLine

            HStack(alignment: .top, spacing: 12) {
                Label("\(event.photoCount)", systemImage: "camera")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !event.people.isEmpty {
                    Text(event.people.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.blue)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(2)
                }
            }
        }
        .padding(12)
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(Color(white: 0.35), lineWidth: 2)
        }
        .confirmationDialog(
            "Hide Event",
            isPresented: $isConfirmingHideEvent,
            titleVisibility: .visible
        ) {
            Button("Hide Event", role: .destructive) {
                onHide?()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This event will now be hidden. You can find this Event again by selecting Show Hidden Events."
            )
        }
    }

    private var displaySlideshowPhotoIds: [String] {
        slideshowPhotoIds
    }

    @ViewBuilder
    private var titleLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if onHide != nil {
                Button {
                    isConfirmingHideEvent = true
                } label: {
                    Image(systemName: "eye.slash")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Hide event")
            }

            if let title = event.listTitleText {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(event.usesSuggestedName ? .secondary : .primary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer(minLength: 0)
            }

            if let dateText = event.displayDateText {
                Text(dateText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    @ViewBuilder
    private var locationLine: some View {
        if event.locationTitleLine != nil || event.cityStateLine != nil {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let locationTitle = event.locationTitleLine {
                    Text(locationTitle)
                        .font(.subheadline)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Spacer(minLength: 0)
                }

                if let cityState = event.cityStateLine {
                    Text(cityState)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
    }
}

private struct EventSlideshowRotatorView: View {

    let photoIds: [String]
    let aspectRatio: CGFloat
    let cornerRadius: CGFloat
    var thumbnailQuality: PhotoThumbnailView.Quality = .high

    private let photoHold: Duration = .seconds(2)
    private let crossfadeDuration: TimeInterval = 0.5

    @State private var currentIndex = 0
    @State private var previousIndex: Int?

    var body: some View {
        Group {
            if photoIds.isEmpty {
                placeholder
            } else if photoIds.count == 1 || thumbnailQuality == .fast {
                slideshowPhoto(photoIds[0])
            } else {
                ZStack {
                    ForEach(visibleSlideIndices, id: \.self) { index in
                        slideshowPhoto(photoIds[index])
                            .opacity(index == currentIndex ? 1 : 0)
                            .zIndex(index == currentIndex ? 1 : 0)
                    }
                }
                .animation(.easeInOut(duration: crossfadeDuration), value: currentIndex)
                .onChange(of: photoIds) { _, _ in
                    currentIndex = 0
                    previousIndex = nil
                }
                .onChange(of: thumbnailQuality) { _, _ in
                    currentIndex = 0
                    previousIndex = nil
                }
                .task(id: rotationTaskKey) {
                    await runRotation()
                }
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(aspectRatio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    private var rotationTaskKey: String {
        let photoKey = photoIds.joined(separator: "|")
        return "\(photoKey)|\(thumbnailQuality)"
    }

    private var visibleSlideIndices: [Int] {
        var indices: [Int] = [currentIndex]
        if let previousIndex, previousIndex != currentIndex {
            indices.append(previousIndex)
        }
        return indices
    }

    @ViewBuilder
    private func slideshowPhoto(_ photoId: String) -> some View {
        PhotoThumbnailView(
            assetIdentifier: photoId,
            cornerRadius: 0,
            enforceSquareAspect: false,
            quality: thumbnailQuality
        )
        .id("\(photoId)|\(thumbnailQuality)")
    }

    @ViewBuilder
    private var placeholder: some View {
        Rectangle()
            .fill(Color(.systemGray5))
            .overlay {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
    }

    @MainActor
    private func runRotation() async {
        guard photoIds.count > 1 else { return }

        while !Task.isCancelled {
            try? await Task.sleep(for: photoHold)
            guard !Task.isCancelled else { return }

            let outgoing = currentIndex
            let incoming = (currentIndex + 1) % photoIds.count

            previousIndex = outgoing
            withAnimation(.easeInOut(duration: crossfadeDuration)) {
                currentIndex = incoming
            }

            try? await Task.sleep(for: .seconds(crossfadeDuration + 0.05))
            guard !Task.isCancelled else { return }

            if currentIndex == incoming {
                previousIndex = nil
            }
        }
    }
}
