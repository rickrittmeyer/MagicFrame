import AVFoundation
import Photos
import SwiftUI

/// Grants at most one event-row muted video playback slot at a time.
@MainActor
final class EventListVideoPlaybackController: ObservableObject {
    @Published private(set) var playingEventId: Int?

    private var visibleCandidates: Set<Int> = []
    private var isPlaybackAllowed = false

    func setPlaybackAllowed(_ allowed: Bool) {
        guard isPlaybackAllowed != allowed else { return }
        isPlaybackAllowed = allowed
        recompute()
    }

    func setCandidate(eventId: Int, visible: Bool) {
        if visible {
            visibleCandidates.insert(eventId)
        } else {
            visibleCandidates.remove(eventId)
        }
        recompute()
    }

    func clear() {
        visibleCandidates.removeAll()
        playingEventId = nil
        isPlaybackAllowed = false
    }

    private func recompute() {
        guard isPlaybackAllowed, !visibleCandidates.isEmpty else {
            playingEventId = nil
            return
        }
        if let playingEventId, visibleCandidates.contains(playingEventId) {
            return
        }
        playingEventId = visibleCandidates.sorted().first
    }
}

/// Muted looping cover player for a single event-list row. Tear down when inactive.
struct EventListMutedLoopPlayer: View {
    let assetIdentifier: String
    var isActive: Bool

    @State private var player: AVPlayer?
    @State private var loopObserver: NSObjectProtocol?
    @State private var failed = false

    var body: some View {
        ZStack {
            Color.black

            if let player, isActive, !failed {
                InlinePlayerLayer(player: player, videoGravity: .resizeAspectFill)
            } else if failed {
                Image(systemName: "video.slash")
                    .font(.title2)
                    .foregroundStyle(.white)
            } else {
                PhotoThumbnailView(
                    assetIdentifier: assetIdentifier,
                    cornerRadius: 0,
                    enforceSquareAspect: false,
                    quality: .fast,
                    showsVideoBadge: true,
                    isVideo: true
                )
            }
        }
        .task(id: "\(assetIdentifier)|\(isActive)") {
            if isActive {
                await activate()
            } else {
                deactivate()
            }
        }
        .onDisappear {
            deactivate()
        }
    }

    @MainActor
    private func activate() async {
        failed = false
        if player != nil {
            player?.isMuted = true
            player?.play()
            return
        }

        let assets = PHAsset.fetchAssets(
            withLocalIdentifiers: [assetIdentifier],
            options: nil
        )
        guard let asset = assets.firstObject, asset.mediaType == .video else {
            failed = true
            return
        }

        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .fastFormat

        let item: AVPlayerItem? = await withCheckedContinuation { continuation in
            var didResume = false
            PHImageManager.default().requestPlayerItem(
                forVideo: asset,
                options: options
            ) { item, info in
                let isCancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !didResume else { return }
                if isCancelled {
                    didResume = true
                    continuation.resume(returning: nil)
                    return
                }
                guard !isDegraded else { return }
                didResume = true
                continuation.resume(returning: item)
            }
        }

        guard !Task.isCancelled, let item else {
            if !Task.isCancelled { failed = true }
            return
        }

        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.actionAtItemEnd = .none

        let observer = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak player] _ in
            player?.seek(to: .zero)
            player?.play()
        }

        loopObserver = observer
        self.player = player
        player.play()
    }

    @MainActor
    private func deactivate() {
        if let loopObserver {
            NotificationCenter.default.removeObserver(loopObserver)
            self.loopObserver = nil
        }
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }
}
