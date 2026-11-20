import SwiftUI

struct EventLibraryRowView: View {

    let event: IndexedEvent
    var slideshowPhotoIds: [String] = []
    var gameCoverScoreBoard: GameCoverScoreBoard? = nil
    var gameSuggestedName: String? = nil
    var slideshowQuality: PhotoThumbnailView.Quality = .fast
    var isSelecting: Bool = false
    var isSelected: Bool = false
    /// On-frame video asset for safe muted inline playback.
    var onFrameVideoId: String? = nil
    var allowsInlineVideoPlayback: Bool = false

    @EnvironmentObject private var videoPlayback: EventListVideoPlaybackController

    private let cornerRadius: CGFloat = 5
    /// Full-width banner uses 4:3 so height scales with row width.
    private let photoAspectRatio: CGFloat = 4.0 / 3.0

    private var isPlayingInlineVideo: Bool {
        allowsInlineVideoPlayback
            && onFrameVideoId != nil
            && videoPlayback.playingEventId == event.eventId
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            titleLine

            if !event.isEverydayPhotos {
                EventSlideshowRotatorView(
                    photoIds: displaySlideshowPhotoIds,
                    aspectRatio: photoAspectRatio,
                    cornerRadius: cornerRadius,
                    thumbnailQuality: slideshowQuality,
                    coverScoreBoard: gameCoverScoreBoard,
                    onFrameVideoId: onFrameVideoId,
                    isPlayingInlineVideo: isPlayingInlineVideo
                )

                locationLine
            }

            HStack(alignment: .center, spacing: 12) {
                if event.photoCount > 0 {
                    Label("\(event.photoCount)", systemImage: "camera")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("\(event.photoCount) photos")
                }

                if event.videoCount > 0 {
                    Label("\(event.videoCount)", systemImage: "video")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("\(event.videoCount) videos")
                }

                if !event.people.isEmpty {
                    Text(event.people.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.blue)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(2)
                } else {
                    Spacer(minLength: 0)
                }

                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .accessibilityLabel(isSelected ? "Selected" : "Not selected")
                }
            }
        }
        .padding(12)
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(Color(white: 0.35), lineWidth: 2)
        }
        .onScrollVisibilityChange(threshold: 0.9) { visible in
            guard onFrameVideoId != nil else { return }
            videoPlayback.setCandidate(eventId: event.eventId, visible: visible)
        }
        .onDisappear {
            videoPlayback.setCandidate(eventId: event.eventId, visible: false)
        }
    }

    private var displaySlideshowPhotoIds: [String] {
        if !slideshowPhotoIds.isEmpty {
            return slideshowPhotoIds
        }
        if let coverPhotoId = event.coverPhotoId, !coverPhotoId.isEmpty {
            return [coverPhotoId]
        }
        if let onFrameVideoId, !onFrameVideoId.isEmpty {
            return [onFrameVideoId]
        }
        return []
    }

    @ViewBuilder
    private var titleLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let gameTitle = gameSuggestedName,
               event.usesSuggestedName {
                Text(gameTitle)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let title = event.listTitleText {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(event.usesSuggestedName ? .secondary : .primary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let gameTitle = gameSuggestedName {
                Text(gameTitle)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer(minLength: 0)
            }

            if let dateText = event.displayDateText, !event.isEverydayPhotos {
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
    var coverScoreBoard: GameCoverScoreBoard? = nil
    var onFrameVideoId: String? = nil
    var isPlayingInlineVideo: Bool = false

    private let photoHold: Duration = .seconds(2)
    private let crossfadeDuration: TimeInterval = 0.5

    @State private var currentIndex = 0
    @State private var previousIndex: Int?

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                if isPlayingInlineVideo, let onFrameVideoId {
                    EventListMutedLoopPlayer(
                        assetIdentifier: onFrameVideoId,
                        isActive: true
                    )
                } else if photoIds.isEmpty {
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

            if let coverScoreBoard {
                GameCoverScoreBoardView(board: coverScoreBoard)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.55))
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
