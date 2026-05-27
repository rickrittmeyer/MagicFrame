///
//  EventDetailView.swift
//  MagicFrame
//

import SwiftUI

struct EventDetailView: View {

    let event: IndexedEvent

    @State private var photos: [IndexedPhoto] = []

    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                Text(event.name)
                    .font(.largeTitle)
                    .bold()

                if let placeName = event.placeName {
                    Text(placeName)
                        .font(.headline)
                }

                if let city = event.city,
                   let state = event.state {
                    Text("\(city), \(state)")
                        .foregroundStyle(.secondary)
                }

                Text("\(event.photoCount) photos")
                    .font(.subheadline)

                if !event.people.isEmpty {
                    Text(event.people.joined(separator: ", "))
                        .foregroundStyle(.blue)
                }

                Divider()

                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(photos, id: \.id) { photo in
                        VStack(spacing: 6) {
                            PhotoThumbnailView(assetIdentifier: photo.id)
                                .aspectRatio(1, contentMode: .fill)
                                .clipped()
                                .cornerRadius(12)

                            Text("Score \(photo.qualityScore)")
                                .font(.caption2)

                            if photo.isFavorite {
                                Image(systemName: "heart.fill")
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Event")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            photos = PhotoDatabase.shared.getPhotosForEvent(
                eventId: event.eventId
            )
        }
    }
}
