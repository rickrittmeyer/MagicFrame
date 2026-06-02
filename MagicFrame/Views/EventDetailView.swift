import SwiftUI
import Photos

struct EventDetailView: View {

    @StateObject private var vm: EventDetailViewModel
    @State private var selectedPhotoIndex: Int?
    @State private var isConfirmingHideEvent = false
    @State private var isShowingAttributePicker = false
    @State private var attributePickerField: EventAttributeField?
    @FocusState private var isNameFieldFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(
        event: IndexedEvent,
        onEventUpdated: ((Int) -> Void)? = nil,
        onEventHidden: ((Int) -> Void)? = nil,
        onEventUnhidden: ((Int) -> Void)? = nil
    ) {
        _vm = StateObject(
            wrappedValue: EventDetailViewModel(
                event: event,
                onEventUpdated: onEventUpdated,
                onEventHidden: onEventHidden,
                onEventUnhidden: onEventUnhidden
            )
        )
    }

    private let gridSpacing: CGFloat = 2
    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: gridSpacing),
            count: 3
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                nameSection
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                eventMetaSection
                    .padding(.horizontal, 16)

                photoGridHeader

                photoGrid
            }
        }
        .background(Color(.systemBackground))
        .navigationTitle("Event")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if vm.isSelectingPhotos {
                    Button("Cancel") {
                        vm.cancelPhotoSelection()
                    }
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                if vm.isSelectingPhotos {
                    Text("\(vm.selectedPhotoCount) selected")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 16) {
                        Button("Select") {
                            vm.beginPhotoSelection()
                        }

                        Menu {
                            Button(vm.showHiddenPhotos ? "Hide Hidden Photos" : "Show Hidden Photos") {
                                vm.toggleShowHiddenPhotos()
                            }

                            if vm.isUserHidden {
                                Button("Unhide Event") {
                                    vm.unhideEvent()
                                }
                            } else {
                                Button("Hide Event", role: .destructive) {
                                    isConfirmingHideEvent = true
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .accessibilityLabel("More options")
                    }
                }
            }

            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    isNameFieldFocused = false
                    vm.saveEventName()
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if vm.isSelectingPhotos {
                photoSelectionBar
            }
        }
        .onAppear {
            vm.loadPhotos()
            vm.loadClassificationOptions()
        }
        .confirmationDialog(
            "Hide Event",
            isPresented: $isConfirmingHideEvent,
            titleVisibility: .visible
        ) {
            Button("Hide Event", role: .destructive) {
                vm.hideEvent()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This event will now be hidden. You can find this Event again by selecting Show Hidden Events."
            )
        }
        .alert(
            customOptionAlertTitle,
            isPresented: $vm.isAddingCustomOption
        ) {
            TextField("Name", text: $vm.newCustomOptionName)
            Button("Add") {
                vm.saveCustomOption()
            }
            Button("Cancel", role: .cancel) {
                vm.cancelAddingCustomOption()
            }
        } message: {
            Text(vm.customOptionField?.addCustomPrompt ?? "")
        }
        .fullScreenCover(isPresented: isFullscreenPresented) {
            EventPhotoFullscreenView(
                viewModel: vm,
                initialDisplayIndex: selectedPhotoIndex ?? 0,
                onDismiss: {
                    selectedPhotoIndex = nil
                    if vm.displayRepresentatives.isEmpty {
                        dismiss()
                    }
                }
            )
        }
        .sheet(isPresented: $isShowingAttributePicker) {
            EventAttributePickerSheet(
                viewModel: vm,
                selectedField: $attributePickerField,
                onDismiss: {
                    isShowingAttributePicker = false
                    attributePickerField = nil
                },
                onAddCustom: { field in
                    isShowingAttributePicker = false
                    attributePickerField = nil
                    vm.beginAddingCustomOption(for: field)
                }
            )
        }
    }

    private var isFullscreenPresented: Binding<Bool> {
        Binding(
            get: { selectedPhotoIndex != nil },
            set: { isPresented in
                if !isPresented {
                    selectedPhotoIndex = nil
                }
            }
        )
    }

    private var customOptionAlertTitle: String {
        if let field = vm.customOptionField {
            return "Add \(field.menuTitle)"
        }
        return "Add Option"
    }

    /// Tag control on the left; attribute chips flow in the remaining width above the photo grid.
    private var photoGridHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                attributePickerField = nil
                isShowingAttributePicker = true
            } label: {
                Image(systemName: "tag")
                    .font(.body.weight(.medium))
                    .frame(width: 36, height: 36)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Tags")

            selectedAttributeChips
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var selectedAttributeChips: some View {
        let selections = EventAttributeField.allCases.compactMap { field -> (EventAttributeField, String)? in
            guard let value = vm.selection(for: field)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else {
                return nil
            }
            return (field, value)
        }

        if !selections.isEmpty {
            FlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(selections, id: \.0.id) { field, value in
                    selectedAttributeChip(field: field, value: value)
                }
            }
        }
    }

    private func selectedAttributeChip(field: EventAttributeField, value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: field.iconName)
                .font(.caption.weight(.medium))
                .frame(width: 24, height: 24)
                .background(Color.accentColor.opacity(0.15))
                .clipShape(Circle())

            Text(value)
                .font(.subheadline)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(.secondarySystemBackground))
        .clipShape(Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(field.menuTitle): \(value)")
    }

    private var eventMetaSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let locationId = vm.event.locationId {
                NavigationLink {
                    LocationDetailView(locationId: locationId) {
                        vm.refreshEvent()
                    }
                } label: {
                    locationSummary(showChevron: true)
                }
                .buttonStyle(.plain)
            } else if vm.event.locationTitleLine != nil || vm.event.cityStateLine != nil {
                locationSummary(showChevron: false)
            }

            HStack(spacing: 12) {
                if vm.collapsedSimilarPhotoCount > 0 {
                    Text("\(vm.photoCount) photos · \(vm.visiblePhotoCount) shown")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(vm.photoCount) photos")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !vm.event.people.isEmpty {
                    Text(vm.event.people.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.blue)
                        .lineLimit(2)
                }
            }
        }
    }

    @ViewBuilder
    private func locationSummary(showChevron: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                if let locationTitle = vm.event.locationTitleLine {
                    Text(locationTitle)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                }

                if let cityState = vm.event.cityStateLine {
                    Text(cityState)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            if showChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
        }
        .contentShape(Rectangle())
    }

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Event name")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Spacer()

                if let status = vm.nameSaveStatus {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(status == "Saved" ? .green : .red)
                }
            }

            TextField("Event name", text: $vm.eventName)
                .font(.title2.bold())
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.words)
                .focused($isNameFieldFocused)
                .submitLabel(.done)
                .onSubmit {
                    isNameFieldFocused = false
                    vm.saveEventName()
                }
                .onChange(of: vm.eventName) { _, newValue in
                    if newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        != vm.suggestedName {
                        vm.markNameAsUserEdited()
                    }
                }

            if let suggestedName = vm.suggestedName,
               vm.showSuggestion {
                HStack(alignment: .center, spacing: 12) {
                    Text("Suggested: \(suggestedName)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button("Use suggestion") {
                        vm.applySuggestedName()
                    }
                    .font(.subheadline)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var photoSelectionBar: some View {
        HStack(spacing: 12) {
            Button("Add to Frame") {
                vm.setSelectedPhotosOnFrame(true)
            }
            .buttonStyle(.borderedProminent)
            .disabled(vm.selectedPhotoCount == 0)

            Button("Remove from Frame") {
                vm.setSelectedPhotosOnFrame(false)
            }
            .buttonStyle(.bordered)
            .disabled(vm.selectedPhotoCount == 0)

            Button("Hide", role: .destructive) {
                if vm.hideSelectedPhotos() {
                    dismiss()
                }
            }
            .buttonStyle(.bordered)
            .disabled(vm.selectedPhotoCount == 0)
        }
        .font(.subheadline)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private func tripSectionHeader(_ section: TripPhotoDisplaySection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Day \(section.section.dayNumber)")
                .font(.headline)

            TextField("Day name", text: vm.tripChildEventNameBinding(subEventId: section.section.subEventId))
                .font(.subheadline)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                .onSubmit {
                    vm.saveTripChildEventName(subEventId: section.section.subEventId)
                }
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var photoGrid: some View {
        if vm.event.isTripContainer, !vm.tripPhotoDisplaySections.isEmpty {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(vm.tripPhotoDisplaySections) { section in
                    VStack(alignment: .leading, spacing: 10) {
                        tripSectionHeader(section)

                        LazyVGrid(columns: columns, spacing: gridSpacing) {
                            ForEach(Array(section.displayItems.enumerated()), id: \.element.id) { _, item in
                                displayItemCell(
                                    item,
                                    index: displayIndex(for: item, in: section)
                                )
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
        } else {
            LazyVGrid(columns: columns, spacing: gridSpacing) {
                ForEach(Array(vm.photoDisplayItems.enumerated()), id: \.element.id) { index, item in
                    displayItemCell(item, index: index)
                }
            }
        }
    }

    private func displayIndex(for item: EventPhotoDisplayItem, in section: TripPhotoDisplaySection) -> Int {
        var index = 0
        for tripSection in vm.tripPhotoDisplaySections {
            if tripSection.id == section.id {
                if let itemIndex = tripSection.displayItems.firstIndex(where: { $0.id == item.id }) {
                    return index + itemIndex
                }
            }
            index += tripSection.displayItems.count
        }
        return 0
    }

    @ViewBuilder
    private func displayItemCell(_ item: EventPhotoDisplayItem, index: Int) -> some View {
        let photo = item.representative
        let isSelected = vm.selectedPhotoIds.contains(photo.id)

        Button {
            if vm.isSelectingPhotos {
                vm.toggleDisplayItemSelection(item)
            } else {
                selectedPhotoIndex = index
            }
        } label: {
            Group {
                if item.isStack {
                    SimilarPhotoStackCell(
                        representative: photo,
                        extraCount: item.extraCount
                    )
                } else {
                    PhotoThumbnailView(
                        assetIdentifier: photo.id,
                        cornerRadius: 0,
                        quality: .high
                    )
                    .aspectRatio(1, contentMode: .fill)
                    .clipped()
                }
            }
            .overlay {
                if photo.showOnFrame {
                    RoundedRectangle(cornerRadius: 0)
                        .strokeBorder(Color.green, lineWidth: 3)
                }
            }
            .overlay {
                if vm.isSelectingPhotos {
                    RoundedRectangle(cornerRadius: 0)
                        .strokeBorder(isSelected ? Color.accentColor : Color.white.opacity(0.6), lineWidth: isSelected ? 3 : 1)
                    RoundedRectangle(cornerRadius: 0)
                        .fill(isSelected ? Color.accentColor.opacity(0.25) : Color.black.opacity(0.12))
                }
            }
            .overlay {
                if photo.isHiddenInEvent {
                    RoundedRectangle(cornerRadius: 0)
                        .fill(Color.black.opacity(0.35))
                }
            }
            .overlay(alignment: .topLeading) {
                if photo.isHiddenInEvent, !vm.isSelectingPhotos {
                    Image(systemName: "eye.slash")
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(.black.opacity(0.35), in: Circle())
                        .padding(4)
                }
            }
            .overlay(alignment: .topTrailing) {
                if vm.isSelectingPhotos {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.9), isSelected ? Color.accentColor : Color.black.opacity(0.35))
                        .padding(6)
                } else if photo.isFavorite {
                    Image(systemName: "heart.fill")
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(.black.opacity(0.35), in: Circle())
                        .padding(4)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if photo.showOnFrame, !vm.isSelectingPhotos {
                    Image(systemName: "play.rectangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                        .padding(5)
                        .background(.black.opacity(0.35), in: Circle())
                        .padding(4)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !vm.isSelectingPhotos {
                Button(photo.showOnFrame ? "Remove from Frame" : "Add to Frame") {
                    vm.togglePhotoOnFrame(
                        photoId: photo.id,
                        in: item.isStack ? item.group : nil
                    )
                }

                Button("Hide") {
                    if vm.hideDisplayItem(item) {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if x > 0, x + size.width > maxWidth {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }

            lineHeight = max(lineHeight, size.height)
            x += size.width + spacing
        }

        return CGSize(width: maxWidth, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }

            subview.place(
                at: CGPoint(x: x, y: y),
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )

            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

private struct EventAttributePickerSheet: View {

    @ObservedObject var viewModel: EventDetailViewModel
    @Binding var selectedField: EventAttributeField?
    let onDismiss: () -> Void
    let onAddCustom: (EventAttributeField) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if let field = selectedField {
                    attributeOptionsList(for: field)
                } else {
                    attributeCategoryList
                }
            }
            .navigationTitle(selectedField?.menuTitle ?? "Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(selectedField == nil ? "Done" : "Back") {
                        if selectedField != nil {
                            selectedField = nil
                        } else {
                            onDismiss()
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var attributeCategoryList: some View {
        List(EventAttributeField.allCases) { field in
            Button {
                if field == .tripType {
                    viewModel.setSelection("Trip", for: .tripType)
                    onDismiss()
                } else {
                    selectedField = field
                }
            } label: {
                HStack {
                    Label(field.menuTitle, systemImage: field.iconName)
                    Spacer()
                    if field == .tripType,
                       viewModel.selection(for: .tripType) != nil {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func attributeOptionsList(for field: EventAttributeField) -> some View {
        List {
            if let current = viewModel.selection(for: field) {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: field.iconName)
                            .foregroundStyle(.secondary)
                        Text(current)
                    }
                }
            }

            Section {
                Button("Unset", role: .destructive) {
                    viewModel.setSelection(nil, for: field)
                    onDismiss()
                }
            }

            if !viewModel.options(for: field).isEmpty {
                Section {
                    ForEach(viewModel.options(for: field), id: \.self) { option in
                        Button(option) {
                            viewModel.setSelection(option, for: field)
                            onDismiss()
                        }
                    }
                }
            }

            if field.allowsCustomOptions {
                Section {
                    Button("Add custom...") {
                        onAddCustom(field)
                    }
                }
            }
        }
    }
}

private struct SimilarPhotoStackCell: View {

    let representative: IndexedPhoto
    let extraCount: Int
    let cornerRadius: CGFloat

    init(
        representative: IndexedPhoto,
        extraCount: Int,
        cornerRadius: CGFloat = 0
    ) {
        self.representative = representative
        self.extraCount = extraCount
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                if extraCount >= 2 {
                    stackLayer(offset: CGSize(width: 8, height: -8), opacity: 0.35)
                }
                if extraCount >= 1 {
                    stackLayer(offset: CGSize(width: 4, height: -4), opacity: 0.55)
                }

                PhotoThumbnailView(
                    assetIdentifier: representative.id,
                    cornerRadius: cornerRadius,
                    quality: .high
                )
            }
            .aspectRatio(1, contentMode: .fill)
            .clipped()

            if extraCount > 0 {
                Text("+\(extraCount)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(6)
            }
        }
    }

    private func stackLayer(offset: CGSize, opacity: Double) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color(.secondarySystemFill))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
            }
            .aspectRatio(1, contentMode: .fill)
            .offset(offset)
            .opacity(opacity)
    }
}

private struct SimilarPhotoGroupPickerView: View {

    let group: SimilarPhotoGroup
    @Binding var selectedPhotoIds: Set<String>
    let onDone: () -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var previewPhotoId: String?

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 2),
        count: 3
    )

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Choose the best shot\(group.photos.count == 1 ? "" : "s") to show. Other similar photos stay in this burst.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)

                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(group.photos, id: \.id) { photo in
                            photoCell(photo)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .navigationTitle("Similar Photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        onDone()
                        dismiss()
                    }
                }
            }
            .fullScreenCover(isPresented: isPreviewPresented) {
                if let photoId = previewPhotoId {
                    SimilarPhotoPreviewView(
                        photoIds: group.photos.map(\.id),
                        initialPhotoId: photoId
                    )
                }
            }
        }
        .onAppear {
            if selectedPhotoIds.isEmpty {
                selectedPhotoIds = [group.autoBestPhoto().id]
            }
        }
    }

    private var isPreviewPresented: Binding<Bool> {
        Binding(
            get: { previewPhotoId != nil },
            set: { isPresented in
                if !isPresented {
                    previewPhotoId = nil
                }
            }
        )
    }

    private func photoCell(_ photo: IndexedPhoto) -> some View {
        let isSelected = selectedPhotoIds.contains(photo.id)

        return Button {
            toggleSelection(for: photo.id)
        } label: {
            PhotoThumbnailView(
                assetIdentifier: photo.id,
                cornerRadius: 0,
                quality: .high
            )
            .aspectRatio(1, contentMode: .fill)
            .clipped()
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 0)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                    RoundedRectangle(cornerRadius: 0)
                        .fill(Color.accentColor.opacity(0.18))
                }
            }
            .overlay(alignment: .topTrailing) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, isSelected ? Color.accentColor : Color.black.opacity(0.35))
                    .padding(6)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Preview") {
                previewPhotoId = photo.id
            }
        }
    }

    private func toggleSelection(for photoId: String) {
        if selectedPhotoIds.contains(photoId) {
            if selectedPhotoIds.count > 1 {
                selectedPhotoIds.remove(photoId)
            }
        } else {
            selectedPhotoIds.insert(photoId)
        }
    }
}

private struct SimilarPhotoPreviewView: View {

    let photoIds: [String]
    let initialPhotoId: String

    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex: Int = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $currentIndex) {
                ForEach(Array(photoIds.enumerated()), id: \.offset) { index, photoId in
                    SimilarPhotoPreviewPage(assetIdentifier: photoId)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))
            .ignoresSafeArea()

            VStack {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.35))
                    }
                    .padding(.trailing, 16)
                    .padding(.top, 8)
                }
                Spacer()
            }
        }
        .onAppear {
            currentIndex = photoIds.firstIndex(of: initialPhotoId) ?? 0
        }
    }
}

private struct SimilarPhotoPreviewPage: View {

    let assetIdentifier: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            loadFullImage()
        }
    }

    private func loadFullImage() {
        let assets = PHAsset.fetchAssets(
            withLocalIdentifiers: [assetIdentifier],
            options: nil
        )

        guard let asset = assets.firstObject else { return }

        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .none
        options.isNetworkAccessAllowed = true

        PHImageManager.default().requestImage(
            for: asset,
            targetSize: PHImageManagerMaximumSize,
            contentMode: .aspectFit,
            options: options
        ) { result, _ in
            DispatchQueue.main.async {
                self.image = result
            }
        }
    }
}
