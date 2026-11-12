import SwiftUI

struct PeopleLandingView: View {

    @ObservedObject var vm: LibraryViewModel

    @State private var namingCluster: PersonClusterRecord?
    @State private var mergingCluster: PersonClusterRecord?
    @State private var showResetFaceRecognitionConfirm = false

    private let clusterColumns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                scanControls

                namedPeopleSection

                unknownClustersSection
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("People")
        .navigationBarTitleDisplayMode(.large)
        .task {
            vm.repairFaceRecognitionProgressIfNeeded()
            vm.resumeFaceRecognitionProgressMonitoringIfNeeded()
            await vm.refreshPeopleLandingItems()
            await vm.refreshUnnamedFaceClusters()
            // Existing libraries likely still have over-merged clusters from the old loose thresholds.
            if vm.unnamedFaceClusters.contains(where: { $0.faceCount >= 200 }) {
                await vm.rebuildFaceClustersTapped()
            }
        }
        .sheet(item: $namingCluster) { cluster in
            PersonNamingSheet(
                title: "Add Name",
                onCancel: { namingCluster = nil },
                onSave: { displayName, firstName, lastName, maidenName in
                    vm.nameFaceCluster(
                        clusterId: cluster.clusterId,
                        displayName: displayName,
                        firstName: firstName,
                        lastName: lastName,
                        maidenName: maidenName
                    )
                    namingCluster = nil
                }
            )
        }
        .sheet(item: $mergingCluster) { cluster in
            NavigationStack {
                List(vm.peopleLandingItems) { person in
                    Button {
                        vm.mergeFaceCluster(
                            clusterId: cluster.clusterId,
                            intoPersonId: person.personId
                        )
                        mergingCluster = nil
                    } label: {
                        Text(person.displayName)
                    }
                }
                .navigationTitle("Merge into…")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { mergingCluster = nil }
                    }
                }
            }
        }
    }

    private var scanControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            faceRecognitionProgressBanner

            if vm.isFaceRecognitionScanning {
                Button("Cancel face scan", role: .destructive) {
                    vm.cancelFaceRecognitionScanTapped()
                }
            }

            Button("Rebuild clusters") {
                Task { await vm.rebuildFaceClustersTapped() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                vm.isFaceRecognitionScanning
                    || vm.isMaintainingEvents
                    || vm.isSyncingEvents
                    || vm.isIndexingPhotos
            )

            Button("Reset all face data…", role: .destructive) {
                showResetFaceRecognitionConfirm = true
            }
            .disabled(
                vm.isFaceRecognitionScanning
                    || vm.isMaintainingEvents
                    || vm.isSyncingEvents
                    || vm.isIndexingPhotos
            )
            .confirmationDialog(
                "Reset all face recognition?",
                isPresented: $showResetFaceRecognitionConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete faces, clusters & face names", role: .destructive) {
                    Task { await vm.resetAllFaceRecognitionDataTapped() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "This deletes detected faces, clusters, and people names created from face recognition. Photos themselves are kept. Faces are detected again when you run Picture Searches with face detect on, or open events. Then tap Rebuild clusters before naming anyone."
                )
            }

            Text(
                "Faces are detected from Picture Search results and when you open events — not from a library-wide bulk scan. After enough faces accumulate, tap Rebuild clusters. Vision’s feature-print is not true face ID; use Merge into person when the same person still appears more than once."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var faceRecognitionProgressBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Scan progress")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if vm.isFaceRecognitionScanning {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            HStack(alignment: .top, spacing: 12) {
                progressStat(
                    title: "Photos",
                    value: "\(vm.faceRecognitionScannedCount.formatted()) of \(vm.faceRecognitionTotalCount.formatted())"
                )
                progressStat(
                    title: "Faces",
                    value: vm.faceRecognitionFacesDetectedCount.formatted()
                )
                progressStat(
                    title: "Clusters",
                    value: vm.faceRecognitionClustersIdentifiedCount.formatted()
                )
            }

            if vm.faceRecognitionTotalCount > 0 {
                ProgressView(
                    value: Double(vm.faceRecognitionScannedCount),
                    total: Double(max(vm.faceRecognitionTotalCount, 1))
                )
            }

            if vm.faceRecognitionRemainingCount > 0 {
                Text("\(vm.faceRecognitionRemainingCount.formatted()) photos remaining")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if vm.faceRecognitionTotalCount > 0 {
                Text("All indexed photos have been scanned")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
    }

    private func progressStat(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var namedPeopleSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Named people")
                .font(.title3.weight(.semibold))

            if vm.isLoadingPeopleLanding && vm.peopleLandingItems.isEmpty {
                ProgressView("Loading people…")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            } else if vm.peopleLandingItems.isEmpty {
                Text("No named people yet. Add a name to a face below.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(vm.peopleLandingItems) { person in
                        NavigationLink {
                            PersonPhotosBrowserView(person: person)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "person.crop.circle.fill")
                                    .font(.title)
                                    .foregroundStyle(Color(red: 0.9, green: 0.45, blue: 0.55))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(person.displayName)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    if let detail = personDetailLine(person) {
                                        Text(detail)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 10)
                        }
                        if person.id != vm.peopleLandingItems.last?.id {
                            Divider()
                        }
                    }
                }
                .padding(.horizontal, 12)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    @ViewBuilder
    private var unknownClustersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add names")
                .font(.title3.weight(.semibold))

            if vm.isLoadingFaceClusters && vm.unnamedFaceClusters.isEmpty {
                ProgressView("Loading faces…")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else if vm.isFaceRecognitionScanning {
                Text("Face scan running — avatars paused to save memory. Come back when idle, then Rebuild clusters.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if vm.unnamedFaceClusters.isEmpty {
                Text("No unnamed faces. Run a face scan first.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: clusterColumns, spacing: 20) {
                    ForEach(vm.unnamedFaceClusters) { cluster in
                        unknownClusterCell(cluster)
                    }
                }
            }
        }
    }

    private func unknownClusterCell(_ cluster: PersonClusterRecord) -> some View {
        VStack(spacing: 8) {
            Button {
                namingCluster = cluster
            } label: {
                if let photoId = cluster.representativePhotoId {
                    FaceCircleAvatar(
                        photoId: photoId,
                        faceBoundingBox: cluster.faceBoundingBox,
                        size: 96
                    )
                } else {
                    Circle()
                        .fill(Color(.secondarySystemFill))
                        .frame(width: 96, height: 96)
                        .overlay {
                            Image(systemName: "person.crop.circle.badge.questionmark")
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Add Name") { namingCluster = cluster }
                if !vm.peopleLandingItems.isEmpty {
                    Button("Merge into person…") { mergingCluster = cluster }
                }
                Button("Ignore", role: .destructive) {
                    vm.ignoreFaceCluster(clusterId: cluster.clusterId)
                }
            }

            Button("Add Name") {
                namingCluster = cluster
            }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.bordered)
            .controlSize(.small)

            Text(clusterCountLabel(cluster))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func clusterCountLabel(_ cluster: PersonClusterRecord) -> String {
        let photos = max(cluster.photoCount, 0)
        if photos > 0 {
            return "\(photos) photo\(photos == 1 ? "" : "s")"
        }
        let faces = cluster.faceCount
        return "\(faces) face\(faces == 1 ? "" : "s")"
    }

    private func personDetailLine(_ person: PeopleRepository.PersonRecord) -> String? {
        var parts: [String] = []
        if let first = person.firstName, let last = person.lastName {
            parts.append("\(first) \(last)")
        }
        if let maiden = person.maidenName, !maiden.isEmpty {
            parts.append("née \(maiden)")
        }
        guard !parts.isEmpty else { return nil }
        let line = parts.joined(separator: " · ")
        return line == person.displayName ? nil : line
    }
}

private struct PersonPhotosBrowserView: View {
    let person: PeopleRepository.PersonRecord
    @State private var photoIds: [String] = []
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading photos…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if photoIds.isEmpty {
                ContentUnavailableView(
                    "No Photos",
                    systemImage: "person.crop.rectangle",
                    description: Text("No photos linked to \(person.displayName) yet.")
                )
            } else {
                PictureBrowserView(
                    title: "\(person.displayName) Photos",
                    photoIds: photoIds,
                    sortOptions: [.dateTaken],
                    usesNavigationTitle: true,
                    enablesVideoFilter: true
                )
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task {
            isLoading = true
            photoIds = await Task.detached(priority: .utility) {
                PhotoDatabase.shared.fetchPhotoIdsForPerson(personId: person.personId)
            }.value
            isLoading = false
        }
    }
}
