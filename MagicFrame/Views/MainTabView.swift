import SwiftUI

struct MainTabView: View {

    @ObservedObject var vm: LibraryViewModel

    var body: some View {
        TabView {
            NavigationStack {
                HomeView(vm: vm)
            }
            .environmentObject(vm)
            .tabItem {
                Label("Home", systemImage: "house.fill")
            }

            NavigationStack {
                DeveloperView(vm: vm)
            }
            .environmentObject(vm)
            .tabItem {
                Label("Settings", systemImage: "gearshape.fill")
            }
        }
    }
}
