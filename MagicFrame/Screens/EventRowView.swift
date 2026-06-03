import SwiftUI

struct EventRowConfiguration {
    var thumbnailSize: CGFloat
    var cornerRadius: CGFloat
    var showLocation: Bool
    var showFrameActions: Bool
    var showDisclosureIndicator: Bool
    var showCoverThumbnail: Bool
    var textSpacing: CGFloat

    static let library = EventRowConfiguration(
        thumbnailSize: 90,
        cornerRadius: 12,
        showLocation: true,
        showFrameActions: true,
        showDisclosureIndicator: false,
        showCoverThumbnail: true,
        textSpacing: 6
    )

    static let locationDetail = EventRowConfiguration(
        thumbnailSize: 64,
        cornerRadius: 10,
        showLocation: false,
        showFrameActions: false,
        showDisclosureIndicator: true,
        showCoverThumbnail: false,
        textSpacing: 4
    )
}

struct EventRowView: View {

    let event: IndexedEvent
    var configuration: EventRowConfiguration = .library
    var onToggleFrame: (() -> Void)?
    var onHide: (() -> Void)?
    var onEventUpdated: ((Int) -> Void)?

    var body: some View {
        if configuration.showFrameActions {
            libraryRow
        } else {
            compactRow
        }
    }

    private var libraryRow: some View {
        NavigationLink {
            EventDetailView(
                event: event,
                onEventUpdated: onEventUpdated
            )
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    if configuration.showCoverThumbnail {
                        coverThumbnail
                    }

                    HStack(spacing: 8) {
                        EventIconButton(
                            systemImage: event.showOnFrame
                                ? "rectangle.inset.filled.and.play.fill"
                                : "rectangle.on.rectangle",
                            hintText: event.showOnFrame
                                ? "Remove from Frame"
                                : "Add to Frame",
                            tint: event.showOnFrame ? .green : .red
                        ) {
                            onToggleFrame?()
                        }

                        EventIconButton(
                            systemImage: "eye.slash",
                            hintText: "Hide",
                            tint: .secondary
                        ) {
                            onHide?()
                        }
                    }
                }

                eventDetailsColumn
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var compactRow: some View {
        NavigationLink {
            EventDetailView(
                event: event,
                onEventUpdated: onEventUpdated
            )
        } label: {
            HStack(alignment: .top, spacing: 12) {
                if configuration.showCoverThumbnail {
                    coverThumbnail
                }

                eventDetailsColumn
                    .foregroundStyle(.primary)

                Spacer(minLength: 0)

                if configuration.showDisclosureIndicator {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var coverThumbnail: some View {
        Group {
            if configuration.showCoverThumbnail,
               let coverPhotoId = event.coverPhotoId {
                PhotoThumbnailView(assetIdentifier: coverPhotoId)
            } else {
                RoundedRectangle(cornerRadius: configuration.cornerRadius)
                    .fill(Color.secondary.opacity(0.15))
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(
            width: configuration.thumbnailSize,
            height: configuration.thumbnailSize
        )
        .clipShape(RoundedRectangle(cornerRadius: configuration.cornerRadius))
    }

    private var eventDetailsColumn: some View {
        VStack(alignment: .leading, spacing: configuration.textSpacing) {
            Text(event.name)
                .font(.headline)

            if configuration.showLocation,
               let locationText = event.locationDisplayText {
                Text(locationText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Text("\(event.photoCount) photos")
                .font(.caption)
                .foregroundStyle(configuration.showDisclosureIndicator ? .secondary : .primary)

            if !event.people.isEmpty {
                Text(event.people.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.blue)
                    .lineLimit(2)
            }

            if !configuration.showDisclosureIndicator {
                Spacer(minLength: 0)
            }
        }
    }
}
