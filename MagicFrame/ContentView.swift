//
//  ContentView.swift
//  MagicFrame
//

import SwiftUI
import Photos

struct ContentView: View {

    @State private var statusText = "Ready"

    @State private var indexedPhotos: [IndexedPhoto] = []
    @State private var indexedEvents: [IndexedEvent] = []

    @State private var geocodeTimer: Timer?
    @State private var isGeocoding = false

    var body: some View {

        NavigationStack {

            VStack(spacing: 12) {

                // HEADER

                Text("Magic Frame")
                    .font(.largeTitle)
                    .bold()

                Text(statusText)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)

                // TOP BUTTON ROW

                ScrollView(.horizontal, showsIndicators: false) {

                    HStack(spacing: 10) {

                        Button("Index Photos") {

                            indexedEvents = []
                            indexedPhotos = []

                            statusText = "Starting photo sync..."

                            requestPhotoAccess()
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Sync Events") {

                            indexedEvents = []
                            indexedPhotos = []

                            PhotoDatabase.shared.syncEventsIncrementally()

                            PhotoDatabase.shared.debugEventPipeline()
                            PhotoDatabase.shared.debugLocationCounts()

                            indexedEvents =
                                PhotoDatabase.shared.getEvents()

                            statusText =
                                "Synced \(indexedEvents.count) events"
                        }
                        .buttonStyle(.bordered)
                        
                        Button("Build Covers") {

                            PhotoDatabase.shared.updateAllEventCoverPhotos()

                        }

                        .buttonStyle(.bordered)

                        

                        Button("Show Events") {

                            print("SHOW EVENTS BUTTON TAPPED")

                            PhotoDatabase.shared.debugEventPipeline()

                            PhotoDatabase.shared.debugLocationCounts()

                            PhotoDatabase.shared.debugSchema()

                            indexedEvents =
                                PhotoDatabase.shared.getEvents()

                            print(
                                "getEvents returned \(indexedEvents.count) events"
                            )

                            statusText =
                                "Showing \(indexedEvents.count) events"
                        }
                        .buttonStyle(.bordered)

                        Button("Show Recent Photos") {

                            indexedPhotos =
                                PhotoDatabase.shared.getRecentPhotos(
                                    limit: 100
                                )

                            statusText =
                                "Showing \(indexedPhotos.count) photos"
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.horizontal)
                }

                Divider()

                // EVENTS SECTION

                HStack {

                    Text("Events")
                        .font(.title2)
                        .bold()

                    Spacer()

                    Text("\(indexedEvents.count)")
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)

                List(indexedEvents, id: \.eventId) { event in

                    NavigationLink {
                        EventDetailView(event: event)

                    } label: {

                        HStack(alignment: .top, spacing: 12) {

                            // FUTURE COVER PHOTO PLACEHOLDER

                            if let coverPhotoId = event.coverPhotoId {

                                PhotoThumbnailView(
                                    assetIdentifier: coverPhotoId
                                )
                                .frame(width: 90, height: 90)
                                .clipped()
                                .cornerRadius(12)

                            } else {

                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.gray.opacity(0.2))
                                    .frame(width: 90, height: 90)
                            }
                            
                            VStack(
                                alignment: .leading,
                                spacing: 6
                            ) {

                                Text(event.name)
                                    .font(.headline)

                                if let city = event.city,
                                   let state = event.state {

                                    Text("\(city), \(state)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Text("\(event.photoCount) photos")
                                    .font(.caption)

                                if !event.people.isEmpty {

                                    Text(
                                        event.people.joined(separator: ", ")
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.blue)
                                    .lineLimit(2)
                                }

                                // FUTURE STORY EVENT FLAGS

                                HStack(spacing: 8) {

                                    Label(
                                        "Story",
                                        systemImage: "rectangle.stack"
                                    )
                                    .font(.caption2)
                                    .foregroundStyle(.orange)

                                    Label(
                                        "Favorite",
                                        systemImage: "heart.fill"
                                    )
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                                }
                            }

                            Spacer()
                        }
                        .padding(.vertical, 6)
                    }
                }
                .listStyle(.plain)

                Divider()

                // RECENT PHOTOS SECTION

                if !indexedPhotos.isEmpty {

                    VStack(alignment: .leading) {

                        Text("Recent Photos")
                            .font(.headline)
                            .padding(.horizontal)

                        ScrollView(.horizontal, showsIndicators: false) {

                            HStack(spacing: 12) {

                                ForEach(indexedPhotos, id: \.id) { photo in

                                    VStack(spacing: 6) {

                                        PhotoThumbnailView(
                                            assetIdentifier: photo.id
                                        )
                                        .frame(width: 140, height: 140)
                                        .clipped()
                                        .cornerRadius(14)

                                        Text("Score \(photo.qualityScore)")
                                            .font(.caption)

                                        if photo.isFavorite {

                                            Image(systemName: "heart.fill")
                                                .foregroundStyle(.red)
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                    .padding(.bottom)
                }
            }
        }
    }

    // MARK: - PHOTO ACCESS

    func requestPhotoAccess() {

        PHPhotoLibrary.requestAuthorization(
            for: .readWrite
        ) { status in

            DispatchQueue.main.async {

                switch status {

                case .authorized, .limited:

                    statusText =
                        "Access granted. Starting indexing..."

                    indexPhotos()

                    PhotoDatabase.shared.importPeopleFromAlbums()

                    PhotoDatabase.shared.rebuildEventPeople()

                    statusText =
                        "Finished indexing"

                case .denied:

                    statusText =
                        "Photo access denied"

                case .restricted:

                    statusText =
                        "Photo access restricted"

                default:

                    statusText =
                        "Unknown authorization status"
                }
            }
        }
    }

    // MARK: - PHOTO INDEXING

    func indexPhotos() {

        let startDate =
            Calendar.current.date(
                byAdding: .year,
                value: -100,
                to: Date()
            )!

        let options = PHFetchOptions()

        options.predicate =
            NSPredicate(
                format:
                    "creationDate >= %@ AND mediaType == %d",
                startDate as NSDate,
                PHAssetMediaType.image.rawValue
            )

        let assets =
            PHAsset.fetchAssets(with: options)

        var count = 0

        assets.enumerateObjects { asset, _, _ in

            let id =
                asset.localIdentifier

            let creationDate =
                ISO8601DateFormatter()
                    .string(
                        from:
                            asset.creationDate
                            ?? Date()
                    )

            let modificationDate =
                ISO8601DateFormatter()
                    .string(
                        from:
                            asset.modificationDate
                            ?? Date()
                    )

            let isScreenshot =
                asset.mediaSubtypes.contains(
                    .photoScreenshot
                )

            let width =
                asset.pixelWidth

            let height =
                asset.pixelHeight

            let aspectRatio =
                height == 0
                ? 0.0
                : Double(width) / Double(height)

            let orientation: String

            if width > height {

                orientation = "landscape"

            } else if height > width {

                orientation = "portrait"

            } else {

                orientation = "square"
            }

            var qualityScore = 50

            if width >= 3000 &&
                height >= 2000 {

                qualityScore += 20
            }

            if orientation == "landscape" {

                qualityScore += 15
            }

            if asset.isFavorite {

                qualityScore += 10
            }

            if isScreenshot {

                qualityScore -= 30
            }

            qualityScore =
                max(
                    0,
                    min(100, qualityScore)
                )

            PhotoDatabase.shared.upsertPhoto(

                id: id,

                creationDate: creationDate,

                modificationDate: modificationDate,

                mediaType:
                    asset.mediaType.rawValue,

                mediaSubtype:
                    Int(asset.mediaSubtypes.rawValue),

                width: width,

                height: height,

                isFavorite:
                    asset.isFavorite,

                isHidden:
                    asset.isHidden,

                latitude:
                    asset.location?.coordinate.latitude,

                longitude:
                    asset.location?.coordinate.longitude,

                isScreenshot:
                    isScreenshot,

                aspectRatio:
                    aspectRatio,

                orientation:
                    orientation,

                qualityScore:
                    qualityScore
            )

            count += 1

            DispatchQueue.main.async {

                statusText =
                    "Indexed \(count) photos"
            }
        }

        DispatchQueue.main.async {

            statusText =
                "Finished indexing \(count) photos"
        }
    }
}
