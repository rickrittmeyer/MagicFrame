import SwiftUI

struct VisionClassificationDebugView: View {

    @ObservedObject var vm: LibraryViewModel

    @State private var photos: [IndexedPhoto] = []
    @State private var selectedPhotoId: String?
    @State private var classifications: [VisionClassification] = []
    @State private var objectMatches: [PhotoObjectDetection] = []
    @State private var objectKeys: [String] = []
    @State private var isAnalyzing = false
    @State private var statusMessage = "Pick a photo to inspect Vision labels."

    var body: some View {
        List {
            Section {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(
                    "Runs Apple Vision image classification on an indexed photo and prints the top labels to the Xcode console. Also shows which Christmas object rules would match."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let selectedPhotoId {
                Section("Selected photo") {
                    HStack(spacing: 12) {
                        PhotoThumbnailView(
                            assetIdentifier: selectedPhotoId,
                            cornerRadius: 8,
                            quality: .fast
                        )
                        .frame(width: 72, height: 72)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(selectedPhotoId)
                                .font(.caption2.monospaced())
                                .lineLimit(2)
                            Button("Log Vision labels") {
                                analyzeSelectedPhoto()
                            }
                            .font(.caption.weight(.semibold))
                            .disabled(isAnalyzing)
                        }
                    }
                }
            }

            if !classifications.isEmpty {
                Section("Top Vision labels") {
                    ForEach(classifications) { classification in
                        HStack {
                            Text(classification.identifier)
                                .font(.caption.monospaced())
                            Spacer()
                            Text(percentText(classification.confidence))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if !objectKeys.isEmpty {
                Section("Christmas object matches") {
                    if objectMatches.isEmpty {
                        Text("No matches for current rules: \(objectKeys.joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(objectMatches, id: \.objectKey) { match in
                            HStack {
                                Text(OccasionObjectKeyFormatter.displayName(from: match.objectKey))
                                    .font(.caption)
                                Spacer()
                                Text(percentText(match.confidence))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section("Recent indexed photos") {
                if photos.isEmpty {
                    Text("No indexed photos yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(photos, id: \.id) { photo in
                        Button {
                            selectedPhotoId = photo.id
                            classifications = []
                            objectMatches = []
                            statusMessage = "Selected photo. Tap “Log Vision labels” to analyze."
                        } label: {
                            HStack(spacing: 12) {
                                PhotoThumbnailView(
                                    assetIdentifier: photo.id,
                                    cornerRadius: 6,
                                    quality: .fast
                                )
                                .frame(width: 56, height: 56)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(photo.creationDate)
                                        .font(.caption)
                                    Text(photo.id)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer(minLength: 0)

                                if selectedPhotoId == photo.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle("Vision labels")
        .onAppear {
            photos = vm.database.getRecentPhotos(limit: 50)
            objectKeys = vm.christmasObjectKeysForVisionDebug()
        }
    }

    private func analyzeSelectedPhoto() {
        guard let selectedPhotoId else { return }

        isAnalyzing = true
        statusMessage = "Analyzing Vision labels…"

        Task {
            let results = await vm.analyzeVisionLabels(
                assetIdentifier: selectedPhotoId,
                objectKeys: objectKeys
            )

            await MainActor.run {
                classifications = results.classifications
                objectMatches = results.objectMatches
                isAnalyzing = false
                statusMessage = results.statusMessage
            }
        }
    }

    private func percentText(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }
}
