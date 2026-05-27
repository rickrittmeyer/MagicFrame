//
//  PhotoThumbnailView.swift
//  MagicFrame
//
//  Created by Rick Rittmeyer on 5/23/26.
//

import SwiftUI
import Photos

struct PhotoThumbnailView: View {
    let assetIdentifier: String

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .foregroundStyle(.gray.opacity(0.3))
            }
        }
        .frame(width: 70, height: 70)
        .clipped()
        .cornerRadius(8)
        .onAppear {
            loadThumbnail()
        }
    }

    private func loadThumbnail() {
        let assets = PHAsset.fetchAssets(
            withLocalIdentifiers: [assetIdentifier],
            options: nil
        )

        guard let asset = assets.firstObject else { return }

        let manager = PHImageManager.default()

        let options = PHImageRequestOptions()
        options.deliveryMode = .fastFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true

        manager.requestImage(
            for: asset,
            targetSize: CGSize(width: 140, height: 140),
            contentMode: .aspectFill,
            options: options
        ) { result, _ in
            DispatchQueue.main.async {
                self.image = result
            }
        }
    }
}
