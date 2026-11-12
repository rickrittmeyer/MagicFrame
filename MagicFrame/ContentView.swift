//
//  ContentView.swift
//  MagicFrame
//

import SwiftUI

struct ContentView: View {

    @StateObject private var vm = LibraryViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        MainTabView(vm: vm)
            .fullScreenCover(isPresented: $vm.showHomeOnboarding) {
                Group {
                    if #available(iOS 26.0, *) {
                        HomeOnboardingView {
                            vm.homeOnboardingCompleted()
                        }
                        .interactiveDismissDisabled()
                    }
                }
            }
            .onAppear {
                vm.onAppear()
                AppDependencies.container.visionJobCoordinator.startIfNeeded()
            }
            .task(id: vm.isStartupComplete) {
                guard vm.isStartupComplete else { return }
                await vm.loadEventsForUIIfNeeded()
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
