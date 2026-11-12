import SwiftUI

struct HomeView: View {

    @ObservedObject var vm: LibraryViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if vm.showsBackgroundWorkBanner {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(vm.backgroundWorkBannerText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HomeCategoryGridView(vm: vm)

                if vm.archivePhotoCount > 0 {
                    NavigationLink {
                        ArchiveBatchesView(
                            vm: ArchiveBatchesViewModel(libraryViewModel: vm)
                        )
                    } label: {
                        Label("Archive (\(vm.archivePhotoCount))", systemImage: "archivebox")
                            .font(.subheadline)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .navigationTitle("Home")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            vm.clearEventsTabFocus()
        }
        .task {
            await vm.refreshHomeCategoryCounts()
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text("Magic Frame")
                .font(.system(size: 32, weight: .bold, design: .serif))
                .frame(maxWidth: .infinity)

            Text("Your memories. Beautifully displayed.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 4)
    }
}
