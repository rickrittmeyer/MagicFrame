import SwiftUI

struct MilestonePersonPickerSheet: View {

    let kind: MilestonePersonPickerKind
    let items: [MilestonePersonPickerItem]
    var titleOverride: String? = nil
    let onSelect: (MilestonePersonPickerItem) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    ContentUnavailableView(
                        "No People Found",
                        systemImage: "person.crop.circle.badge.questionmark",
                        description: Text(kind.emptyDescription)
                    )
                } else {
                    List(items) { item in
                        Button {
                            onSelect(item)
                            dismiss()
                        } label: {
                            HStack {
                                Text(item.name)
                                    .foregroundStyle(.primary)

                                Spacer()

                                if kind == .birthday,
                                   let birthMonthDay = item.birthMonthDayDisplay {
                                    Text(birthMonthDay)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(titleOverride ?? kind.navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
}
