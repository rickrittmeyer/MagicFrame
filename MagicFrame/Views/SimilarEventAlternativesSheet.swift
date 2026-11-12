import SwiftUI

/// Shown after rejecting an AI tag (e.g. Wedding) to offer similar classifications.
struct SimilarEventAlternativesSheet: View {

    let rejectedTagValue: String
    let alternatives: [SimilarEventTagAlternative]
    let onSelect: (SimilarEventTagAlternative) -> Void
    let onSkip: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(alternatives) { alternative in
                        Button {
                            onSelect(alternative)
                            dismiss()
                        } label: {
                            Text(alternative.possibleTagValue)
                                .foregroundStyle(.primary)
                        }
                    }
                } header: {
                    Text("Could this be something else?")
                } footer: {
                    Text("“\(rejectedTagValue)” was removed. Choose a better fit, or skip if none apply.")
                }

                Section {
                    Button("None of these") {
                        onSkip()
                        dismiss()
                    }
                }
            }
            .navigationTitle(rejectedTagValue)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onSkip()
                        dismiss()
                    }
                }
            }
        }
    }
}
