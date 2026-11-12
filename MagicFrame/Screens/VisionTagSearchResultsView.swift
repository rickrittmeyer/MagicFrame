import SwiftUI

struct VisionTagSearchResultsView: View {

    @State private var query = ""
    @State private var allTags: [VisionTagName] = []
    @State private var matches: [VisionTagPhotoMatch] = []
    @State private var activeSearchText = ""
    @State private var didCommitSearch = false
    @State private var selectedPhotoIndex: Int?
    @FocusState private var isQueryFocused: Bool

    private let suggestionLimit = 20

    var body: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            Divider()

            if showsSuggestions {
                suggestionList
            } else {
                resultsBody
            }
        }
        .background(Color(.systemBackground))
        .navigationTitle("Search Vision Tag")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            allTags = AppDependencies.database.fetchDistinctVisionTagNames()
            isQueryFocused = true
        }
        .fullScreenCover(isPresented: isPreviewPresented) {
            if let selectedPhotoIndex {
                FetchedPhotoPreview(
                    photoIds: matches.map(\.photoId),
                    initialPhotoId: matches[selectedPhotoIndex].photoId
                )
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Vision tag", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($isQueryFocused)
                .submitLabel(.search)
                .onSubmit {
                    submitTypedQuery()
                }
                .onChange(of: query) { _, newValue in
                    if didCommitSearch, newValue != activeSearchText {
                        didCommitSearch = false
                    }
                }

            if !query.isEmpty {
                Button {
                    query = ""
                    didCommitSearch = false
                    matches = []
                    activeSearchText = ""
                    isQueryFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    private var suggestionList: some View {
        List {
            if allTags.isEmpty {
                Text("No vision tags yet. Run Tag Photos with Vision Tag first.")
                    .foregroundStyle(.secondary)
            } else if filteredTags.isEmpty {
                Text("No tags match “\(query)”.")
                    .foregroundStyle(.secondary)
            } else {
                Section(
                    query.isEmpty
                        ? "All vision tags"
                        : "Matching tags"
                ) {
                    ForEach(filteredTags) { tag in
                        Button {
                            selectTag(tag)
                        } label: {
                            HStack {
                                Text(tag.objectKey)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text("\(tag.photoCount)")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    @ViewBuilder
    private var resultsBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(headerText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                if matches.isEmpty {
                    ContentUnavailableView(
                        "No Matching Photos",
                        systemImage: "tag.slash",
                        description: Text(
                            "No indexed photos have a Vision tag matching “\(activeSearchText)”."
                        )
                    )
                    .padding(.top, 24)
                } else {
                    FetchedPhotoGrid(photoIds: matches.map(\.photoId)) { photoId in
                        selectedPhotoIndex = matches.firstIndex { $0.photoId == photoId }
                    }
                }
            }
        }
    }

    private var filteredTags: [VisionTagName] {
        let needle = VisionTagName.normalized(query)
        let matches: [VisionTagName]
        if needle.isEmpty {
            matches = allTags
        } else {
            let prefixMatches = allTags.filter { $0.normalized.hasPrefix(needle) }
            let prefixKeys = Set(prefixMatches.map(\.objectKey))
            let containsMatches = allTags.filter {
                !prefixKeys.contains($0.objectKey) && $0.normalized.contains(needle)
            }
            matches = prefixMatches + containsMatches
        }
        return Array(matches.prefix(suggestionLimit))
    }

    private var showsSuggestions: Bool {
        !didCommitSearch
    }

    private var headerText: String {
        let photoLabel = matches.count == 1 ? "photo" : "photos"
        return "\(matches.count) \(photoLabel) for “\(activeSearchText)”"
    }

    private var isPreviewPresented: Binding<Bool> {
        Binding(
            get: { selectedPhotoIndex != nil },
            set: { isPresented in
                if !isPresented {
                    selectedPhotoIndex = nil
                }
            }
        )
    }

    private func selectTag(_ tag: VisionTagName) {
        query = tag.objectKey
        isQueryFocused = false
        didCommitSearch = true
        activeSearchText = tag.objectKey
        matches = AppDependencies.database.searchPhotosByExactVisionTag(tag.objectKey, limit: 500)
    }

    private func submitTypedQuery() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let exactTag = allTags.first(where: {
            $0.objectKey.compare(trimmed, options: .caseInsensitive) == .orderedSame
        }) {
            selectTag(exactTag)
            return
        }

        isQueryFocused = false
        didCommitSearch = true
        activeSearchText = trimmed
        matches = AppDependencies.database.searchPhotosByVisionTag(trimmed, limit: 500)
    }
}
