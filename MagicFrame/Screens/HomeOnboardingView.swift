import SwiftUI
import MapKit

struct HomeOnboardingView: View {

    @StateObject private var vm = HomeOnboardingViewModel()
    @State private var mapPosition: MapCameraPosition = .automatic
    let onComplete: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    headerSection
                    mapSection
                    addressSection
                    homeDetailsSection
                    continueButton
                }
                .padding()
            }
            .navigationTitle("Set Your Home")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                vm.onAppear()
            }
            .onChange(of: vm.mapFocusToken) { _, _ in
                syncMapPositionToViewModel()
            }
        }
    }

    private func syncMapPositionToViewModel() {
        guard let coordinate = vm.pinCoordinate else { return }
        mapPosition = .region(
            MKCoordinateRegion(center: coordinate, span: vm.mapSpan)
        )
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Where do you live?")
                .font(.title2.bold())

            Text(
                "Magic Frame uses your home to tell local photos apart from trips. "
                + "Set this before importing photos so events group correctly the first time."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    private var mapSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Map(position: $mapPosition, interactionModes: .all)
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .onMapCameraChange(frequency: .onEnd) { context in
                        vm.updatePinFromMapRegion(context.region)
                    }

                if vm.isLocating {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.ultraThinMaterial)
                    ProgressView("Finding your location…")
                }

                if vm.pinCoordinate != nil {
                    Image(systemName: "mappin.circle.fill")
                        .font(.title)
                        .foregroundStyle(.red)
                        .shadow(radius: 2)
                        .allowsHitTesting(false)
                }
            }

            HStack {
                Button("Use My Location") {
                    vm.centerOnCurrentLocation()
                }
                .buttonStyle(.bordered)
                .disabled(vm.isLocating)

                Spacer()

                Text(vm.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }

            if let resolvedAddress = vm.resolvedAddress {
                Text(resolvedAddress)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
            } else if vm.isLocating {
                Text("Waiting for GPS…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Search your home address if the map is not on your house.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var addressSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Search by address")
                .font(.subheadline.weight(.semibold))

            HStack(spacing: 8) {
                TextField("115 Cromdale Ct, city, state", text: $vm.addressQuery)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()

                Button("Search") {
                    vm.searchAddress()
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.isSearching)
            }
        }
    }

    private var homeDetailsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Nickname (optional)", text: $vm.nickname)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.words)

            DatePicker(
                "Moved in",
                selection: $vm.homeStartDate,
                displayedComponents: .date
            )

            if let errorMessage = vm.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var continueButton: some View {
        Button {
            Task {
                guard await vm.saveCurrentHome() else { return }
                onComplete()
            }
        } label: {
            if vm.isSaving {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else {
                Text("Continue & Import Photos")
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!vm.canContinue)
    }
}
