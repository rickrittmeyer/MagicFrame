import AVFoundation
import Photos
import SwiftUI
import UIKit

enum PhotoAssetKind {
    private static let lock = NSLock()
    private static var videoByIdentifier: [String: Bool] = [:]

    static func isVideo(assetIdentifier: String) -> Bool {
        lock.lock()
        let cached = videoByIdentifier[assetIdentifier]
        lock.unlock()
        if let cached { return cached }

        let assets = PHAsset.fetchAssets(
            withLocalIdentifiers: [assetIdentifier],
            options: nil
        )
        guard let asset = assets.firstObject else { return false }
        let isVideo = asset.mediaType == .video
        lock.lock()
        videoByIdentifier[assetIdentifier] = isVideo
        lock.unlock()
        return isVideo
    }
}

struct VideoPlayIcon: View {
    var size: CGFloat

    var body: some View {
        Image(systemName: "play.circle.fill")
            .font(.system(size: size))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, .black.opacity(0.45))
            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            .accessibilityLabel("Video")
    }
}

struct VideoPlayBadge: View {
    let assetIdentifier: String
    var iconSize: CGFloat = 44

    @State private var isVideo = false

    var body: some View {
        Group {
            if isVideo {
                VideoPlayIcon(size: iconSize)
            }
        }
        .task(id: assetIdentifier) {
            isVideo = PhotoAssetKind.isVideo(assetIdentifier: assetIdentifier)
        }
    }
}

/// Centers the play icon and sizes it to the photo. Taps pass through to the photo.
struct VideoPlayBadgeOverlay: View {
    let assetIdentifier: String
    var maxIconSize: CGFloat = 72

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            if side > 24 {
                VideoPlayBadge(
                    assetIdentifier: assetIdentifier,
                    iconSize: min(maxIconSize, max(22, side * 0.34))
                )
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .allowsHitTesting(false)
    }
}

struct VideoPlayButton: View {
    let assetIdentifier: String
    var iconSize: CGFloat = 44
    let onPlay: () -> Void

    @State private var isVideo = false

    var body: some View {
        Group {
            if isVideo {
                Button(action: onPlay) {
                    VideoPlayIcon(size: iconSize)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Play video")
            }
        }
        .task(id: assetIdentifier) {
            isVideo = PhotoAssetKind.isVideo(assetIdentifier: assetIdentifier)
        }
    }
}

struct InlineVideoPlayer: View {
    let assetIdentifier: String

    @State private var player: AVPlayer?
    @State private var failed = false
    @State private var isPlaying = false

    var body: some View {
        ZStack {
            Color.black

            if let player {
                InlinePlayerLayer(player: player)
                if !isPlaying {
                    VideoPlayIcon(size: 44)
                        .allowsHitTesting(false)
                }
            } else if failed {
                Image(systemName: "video.slash")
                    .font(.title2)
                    .foregroundStyle(.white)
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            togglePlayback()
        }
        .task(id: assetIdentifier) {
            await load()
        }
        .onDisappear {
            player?.pause()
            player = nil
            isPlaying = false
        }
    }

    private func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    private func load() async {
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
        options.deliveryMode = .automatic

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

        guard let item else {
            failed = true
            return
        }

        let player = AVPlayer(playerItem: item)
        self.player = player
        player.play()
        isPlaying = true
    }
}

struct InlinePlayerLayer: UIViewRepresentable {
    let player: AVPlayer
    var videoGravity: AVLayerVideoGravity = .resizeAspect

    func makeUIView(context: Context) -> InlinePlayerHostView {
        let view = InlinePlayerHostView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = videoGravity
        return view
    }

    func updateUIView(_ uiView: InlinePlayerHostView, context: Context) {
        uiView.playerLayer.player = player
        uiView.playerLayer.videoGravity = videoGravity
    }
}

final class InlinePlayerHostView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
