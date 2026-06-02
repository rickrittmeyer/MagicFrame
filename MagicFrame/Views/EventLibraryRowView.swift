import SwiftUI

struct EventLibraryRowView: View {

    let event: IndexedEvent
    var slideshowPhotoIds: [String] = []
    var showsHiddenBadge: Bool = false
    var onHide: (() -> Void)? = nil
    var onUnhide: (() -> Void)? = nil

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

            EventSlideshowRotatorView(
                photoIds: displaySlideshowPhotoIds,
                aspectRatio: photoAspectRatio,
                cornerRadius: cornerRadius
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
        if !slideshowPhotoIds.isEmpty {
            return slideshowPhotoIds
        }

        if let coverPhotoId = event.coverPhotoId {
            return [coverPhotoId]
        }

        return []
    }

    @ViewBuilder
    private var titleLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let onHide {
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

    private let photoHold: Duration = .seconds(2)
    private let crossfadeDuration: TimeInterval = 0.5

    @State private var currentIndex = 0

    var body: some View {
        Group {
            if photoIds.isEmpty {
                placeholder
            } else if photoIds.count == 1 {
                slideshowPhoto(photoIds[0])
            } else {
                ZStack {
                    ForEach(Array(photoIds.enumerated()), id: \.element) { index, photoId in
                        slideshowPhoto(photoId)
                            .opacity(index == currentIndex ? 1 : 0)
                    }
                }
                .animation(.easeInOut(duration: crossfadeDuration), value: currentIndex)
                .task(id: photoIds) {
                    await runRotation()
                }
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(aspectRatio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    @ViewBuilder
    private func slideshowPhoto(_ photoId: String) -> some View {
        PhotoThumbnailView(
            assetIdentifier: photoId,
            cornerRadius: 0,
            enforceSquareAspect: false,
            quality: .high,
            cropContext: .eventList
        )
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

            currentIndex = (currentIndex + 1) % photoIds.count
        }
    }
}
