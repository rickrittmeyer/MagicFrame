//
//  ContentView.swift
//  MagicFrame
//

import SwiftUI

struct ContentView: View {

    @StateObject private var vm = LibraryViewModel()
    @Environment(\.scenePhase) private var scenePhase

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

                    Button {
                        vm.toggleShowHiddenEvents()
                    } label: {
                        Image(systemName: vm.showHiddenEvents ? "eye.slash" : "eye.fill")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(vm.showHiddenEvents ? "Show visible events" : "Show hidden events")

                    Text(vm.isIndexingPhotos ? "…" : "\(vm.events.count)")
                        .foregroundStyle(.secondary)
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
    }
}
