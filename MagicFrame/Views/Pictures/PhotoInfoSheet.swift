import SwiftUI

struct PhotoInfoSheet: View {
    let photoId: String

    @Environment(\.dismiss) private var dismiss
    @State private var detail: PhotoInfoDetail?
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let detail {
                    List {
                        captureSection(detail)
                        locationSection(detail)
                        mediaSection(detail)
                        librarySection(detail)
                        cameraSection(detail)
                        filenameAlbumsSection(detail)
                        peopleFacesSection(detail)
                        visionSection(detail)
                        ocrSection(detail)
                        eventsSection(detail)
                        technicalSection(detail)
                    }
                    .listStyle(.insetGrouped)
                } else {
                    ContentUnavailableView(
                        "Photo Unavailable",
                        systemImage: "photo",
                        description: Text("Couldn’t load details for this photo.")
                    )
                }
            }
            .navigationTitle("Photo Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task(id: photoId) {
                isLoading = true
                let loaded = await Task.detached(priority: .utility) {
                    AppDependencies.database.fetchPhotoInfoDetail(photoId: photoId)
                }.value
                guard !Task.isCancelled else { return }
                detail = loaded
                isLoading = false
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func captureSection(_ detail: PhotoInfoDetail) -> some View {
        Section("Capture") {
            infoRow(
                "Date & time",
                PhotoPreviewLocationFormatting.dateTimeLine(
                    from: detail.effectiveCreationDate ?? ""
                )
            )
            if let override = detail.captureDateOverride, !override.isEmpty {
                infoRow("Adjusted in MagicFrame", "Yes")
            }
            if let indexedAt = detail.indexedAt {
                infoRow(
                    "Indexed",
                    PhotoPreviewLocationFormatting.dateTimeLine(from: indexedAt)
                )
            }
        }
    }

    @ViewBuilder
    private func locationSection(_ detail: PhotoInfoDetail) -> some View {
        Section("Location") {
            infoRow("Summary", detail.locationLine)
            if let nickname = detail.nickname {
                infoRow("Nickname", nickname)
            }
            if let placeName = detail.placeName {
                infoRow("Place", placeName)
            }
            if let city = detail.city {
                infoRow("City", city)
            }
            if let state = detail.state {
                infoRow("State", state)
            }
            if let locationType = detail.locationType {
                infoRow("Type", locationType)
            }
            if let latitude = detail.latitude, let longitude = detail.longitude {
                infoRow("Coordinates", String(format: "%.5f, %.5f", latitude, longitude))
            }
        }
    }

    @ViewBuilder
    private func mediaSection(_ detail: PhotoInfoDetail) -> some View {
        Section("Media") {
            infoRow("Kind", detail.isVideo ? "Video" : "Photo")
            if detail.isScreenshot {
                infoRow("Screenshot", "Yes")
            }
            infoRow("Size", "\(detail.width) × \(detail.height)")
            if let orientation = detail.orientation {
                infoRow("Orientation", orientation)
            }
            if let qualityScore = detail.qualityScore {
                infoRow("Quality score", "\(qualityScore)")
            }
            if detail.isVideo, let duration = detail.duration {
                infoRow("Duration", formatDuration(duration))
            }
        }
    }

    @ViewBuilder
    private func librarySection(_ detail: PhotoInfoDetail) -> some View {
        Section("Library") {
            infoRow("Favorite", detail.isFavorite ? "Yes" : "No")
            infoRow("On Frame", detail.showOnFrame ? "Yes" : "No")
            infoRow("Hidden in event", detail.isHiddenInEvent ? "Yes" : "No")
            infoRow("Similar-group pick", detail.isSimilarGroupPick ? "Yes" : "No")
        }
    }

    @ViewBuilder
    private func cameraSection(_ detail: PhotoInfoDetail) -> some View {
        let hasCamera = detail.cameraMake != nil
            || detail.cameraModel != nil
            || detail.lensModel != nil
        if hasCamera {
            Section("Camera") {
                if let make = detail.cameraMake {
                    infoRow("Make", make)
                }
                if let model = detail.cameraModel {
                    infoRow("Model", model)
                }
                if let lens = detail.lensModel {
                    infoRow("Lens", lens)
                }
            }
        }
    }

    @ViewBuilder
    private func filenameAlbumsSection(_ detail: PhotoInfoDetail) -> some View {
        if detail.originalFilename != nil || !detail.albumTitles.isEmpty {
            Section("Filename & Albums") {
                if let filename = detail.originalFilename {
                    infoRow("Filename", filename)
                }
                if !detail.albumTitles.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Albums")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        FlowChips(titles: detail.albumTitles)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    @ViewBuilder
    private func peopleFacesSection(_ detail: PhotoInfoDetail) -> some View {
        Section("People & Faces") {
            infoRow("Face count", "\(detail.faceCount)")
            if let eyes = detail.faceEyesOpenScore {
                infoRow("Eyes open", percent(eyes))
            }
            if let smile = detail.faceSmileScore {
                infoRow("Smile", percent(smile))
            }
            if !detail.peopleNames.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("People")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    FlowChips(titles: detail.peopleNames)
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private func visionSection(_ detail: PhotoInfoDetail) -> some View {
        Section("Vision") {
            infoRow("Analyzed", detail.visionAnalyzed ? "Yes" : "No")
            if detail.visionTags.isEmpty {
                infoRow("Tags", detail.visionAnalyzed ? "None" : "Not scanned")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Tags")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    FlowChips(
                        titles: detail.visionTags.map {
                            "\($0.objectKey) · \($0.confidencePercent)%"
                        }
                    )
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private func ocrSection(_ detail: PhotoInfoDetail) -> some View {
        Section("Text in Photo") {
            if !detail.ocrScanned {
                infoRow("OCR", "Not scanned yet")
            } else if let text = detail.ocrFullText, !text.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recognized text")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(text)
                        .font(.body)
                        .textSelection(.enabled)
                    if detail.ocrObservationCount > 0 {
                        Text("\(detail.ocrObservationCount) line\(detail.ocrObservationCount == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 4)
            } else {
                infoRow("OCR", "Scanned — no text found")
            }
        }
    }

    @ViewBuilder
    private func eventsSection(_ detail: PhotoInfoDetail) -> some View {
        Section("Events") {
            if detail.events.isEmpty {
                infoRow("Linked events", "None")
            } else {
                ForEach(detail.events) { event in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(event.title)
                            .font(.body.weight(.semibold))
                        if event.tags.isEmpty {
                            Text("No tags")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            FlowChips(
                                titles: event.tags.map { "\($0.category): \($0.value)" }
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    @ViewBuilder
    private func technicalSection(_ detail: PhotoInfoDetail) -> some View {
        Section("Technical") {
            infoRow("Photo ID", detail.photoId)
            infoRow("Face recognition version", "\(detail.faceRecognitionVersion)")
            infoRow("Text recognition version", "\(detail.textRecognitionVersion)")
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private func percent(_ score: Double) -> String {
        "\(Int((score * 100).rounded()))%"
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let minutes = total / 60
        let secs = total % 60
        return String(format: "%d:%02d", minutes, secs)
    }
}

/// Simple wrapping chip row for tags / people / albums.
private struct FlowChips: View {
    let titles: [String]

    var body: some View {
        FlexibleChipWrap(titles: titles)
    }
}

private struct FlexibleChipWrap: View {
    let titles: [String]

    var body: some View {
        // LazyVGrid keeps layout simple without a custom Layout type.
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 72), spacing: 8, alignment: .leading)],
            alignment: .leading,
            spacing: 8
        ) {
            ForEach(titles, id: \.self) { title in
                Text(title)
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color(.secondarySystemFill), in: Capsule())
            }
        }
    }
}
