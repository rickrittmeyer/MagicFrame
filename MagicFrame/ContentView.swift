//
//  ContentView.swift
//  MagicFrame
//

import SwiftUI

struct ContentView: View {

    @StateObject private var vm = LibraryViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var isSelectingEvents = false
    @State private var selectedEventIds: Set<Int> = []
    @State private var isConfirmingEventDeletion = false
    @State private var isAskingEventPhotoLibraryDelete = false
    @State private var pendingEventDeleteCount = 0
    @State private var pendingEventPictureCount = 0
    @State private var pendingEventPhotoIds: [String] = []
    @State private var photoLibraryError: String?

    var body: some View {

        NavigationStack {

            VStack(spacing: 12) {

                Text("Magic Frame")
                    .font(.largeTitle)
                    .bold()

                Text(vm.statusText)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                if vm.showsBackgroundWorkBanner {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Working in background — events update as grouping finishes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)
                }

                HStack {
                    if vm.archivePhotoCount > 0 {
                        NavigationLink {
                            ArchiveBatchesView(
                                vm: ArchiveBatchesViewModel(libraryViewModel: vm)
                            )
                        } label: {
                            Text("Archive (\(vm.archivePhotoCount))") 
                        }
                        .buttonStyle(.bordered)
                    }

                    Spacer()

                    NavigationLink("Developer") {
                        DeveloperView(vm: vm)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal)

                Divider()

                HStack {
                    Text(vm.showHiddenEvents ? "Hidden Events" : "Events")
                        .font(.title2)
                        .bold()

                    Spacer()

                    if isSelectingEvents {
                        Button("Cancel") {
                            cancelEventSelection()
                        }
                        Text("\(selectedEventIds.count) selected")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Button {
                            vm.toggleShowHiddenEvents()
                        } label: {
                            Image(systemName: vm.showHiddenEvents ? "eye.slash" : "eye.fill")
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel(vm.showHiddenEvents ? "Show visible events" : "Show hidden events")

                        Button {
                            isSelectingEvents = true
                            selectedEventIds = []
                        } label: {
                            Image(systemName: "checkmark.circle")
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Select")

                        Text(vm.isIndexingPhotos ? "…" : "\(vm.events.count)")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal)

                EventsLibraryView(
                    eventSections: vm.eventSections,
                    emptyHint: vm.eventsEmptyHint,
                    isBusy: vm.showsEventsLoadingPlaceholder,
                    showsHiddenEvents: vm.showHiddenEvents,
                    onEventUpdated: { eventId in
                        vm.refreshEvent(eventId: eventId)
                    },
                    onEventHidden: { eventId in
                        vm.hideEvent(eventId: eventId)
                    },
                    onEventUnhidden: { eventId in
                        vm.unhideEvent(eventId: eventId)
                    },
                    scrollTarget: vm.eventListScrollTarget,
                    onScrollTargetHandled: {
                        vm.acknowledgeEventListScroll()
                    },
                    isSelecting: isSelectingEvents,
                    selectedEventIds: selectedEventIds,
                    onToggleSelection: { eventId in
                        if selectedEventIds.contains(eventId) {
                            selectedEventIds.remove(eventId)
                        } else {
                            selectedEventIds.insert(eventId)
                        }
                    }
                )
                .frame(maxHeight: .infinity)
                .allowsHitTesting(!vm.hidesEventsList)

                Divider()

                if !vm.recentPhotos.isEmpty {
                    VStack(alignment: .leading) {
                        Text("Recent Photos")
                            .font(.headline)
                            .padding(.horizontal)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(vm.recentPhotos, id: \.id) { photo in
                                    VStack(spacing: 6) {
                                        PhotoThumbnailView(assetIdentifier: photo.id)
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
        .fullScreenCover(isPresented: $vm.showHomeOnboarding) {
            HomeOnboardingView {
                vm.homeOnboardingCompleted()
            }
            .interactiveDismissDisabled()
        }
        .onAppear {
            vm.onAppear()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                vm.cancelEventSync()
            default:
                break
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isSelectingEvents {
                eventSelectionBar
            }
        }
        .confirmationDialog(
            "Delete Events",
            isPresented: $isConfirmingEventDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                isAskingEventPhotoLibraryDelete = true
            }
            Button("Cancel", role: .cancel) {
                pendingEventPhotoIds = []
            }
        } message: {
            Text(SelectionDeleteCopy.eventListConfirmation(
                eventCount: pendingEventDeleteCount,
                pictureCount: pendingEventPictureCount
            ))
        }
        .confirmationDialog(
            "Delete from Photos?",
            isPresented: $isAskingEventPhotoLibraryDelete,
            titleVisibility: .visible
        ) {
            Button("Delete from Photos", role: .destructive) {
                finishEventDeletion(alsoDeleteFromPhotos: true)
            }
            Button("Keep in Photos", role: .cancel) {
                finishEventDeletion(alsoDeleteFromPhotos: false)
            }
        } message: {
            Text("Also delete these pictures from the Photos library?")
        }
        .alert(
            "Couldn’t Delete from Photos",
            isPresented: Binding(
                get: { photoLibraryError != nil },
                set: { if !$0 { photoLibraryError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(photoLibraryError ?? "")
        }
    }

    private var eventSelectionBar: some View {
        let selected = vm.events.filter { selectedEventIds.contains($0.eventId) }
        let frameOn = !selected.isEmpty && selected.allSatisfy(\.showOnFrame)
        let favoriteOn = !selected.isEmpty && selected.allSatisfy(\.isFavorite)
        let hiddenOn = !selected.isEmpty && selected.allSatisfy(\.isUserHidden)
        return SelectionFooterBar(
            isEnabled: !selectedEventIds.isEmpty,
            isFrameOn: frameOn,
            favoriteIcon: favoriteOn ? "heart.fill" : "heart",
            favoriteCaption: favoriteOn ? "Unfav" : "Fav",
            hideIcon: hiddenOn ? "eye.slash" : "eye",
            hideCaption: hiddenOn ? "Unhide" : "Hide",
            onFrame: {
                vm.setEventsOnFrame(eventIds: selectedEventIds, show: !frameOn)
            },
            onFavorite: {
                vm.setEventsFavorite(eventIds: selectedEventIds, isFavorite: !favoriteOn)
            },
            onHide: {
                vm.setEventsHidden(eventIds: selectedEventIds, hidden: !hiddenOn)
                let visible = Set(vm.events.map(\.eventId))
                selectedEventIds.formIntersection(visible)
            },
            onDelete: { beginEventDeletion() }
        ) {
            Button("Move all Pictures in Event to Everyday Photos") {}
            Button("Merge Events") {}
        }
    }

    private func cancelEventSelection() {
        isSelectingEvents = false
        selectedEventIds = []
    }

    private func beginEventDeletion() {
        let ids = selectedEventIds
        pendingEventDeleteCount = ids.count
        pendingEventPhotoIds = vm.photoIdsInEvents(ids, includeHidden: true)
        pendingEventPictureCount = pendingEventPhotoIds.count
        isConfirmingEventDeletion = true
    }

    private func finishEventDeletion(alsoDeleteFromPhotos: Bool) {
        let photoIds = pendingEventPhotoIds
        let eventIds = selectedEventIds
        pendingEventPhotoIds = []
        vm.deleteEvents(eventIds: eventIds)
        cancelEventSelection()
        if alsoDeleteFromPhotos {
            Task {
                if let error = await PhotoLibraryDeletion.deleteAssets(localIdentifiers: photoIds) {
                    photoLibraryError = error
                }
            }
        }
    }
}
