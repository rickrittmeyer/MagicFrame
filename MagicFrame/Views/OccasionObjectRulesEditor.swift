import SwiftUI

struct OccasionObjectRulesEditor: View {

    let occasionId: Int
    @Binding var rules: [EditableObjectScoringRule]
    let onSave: ([EditableObjectScoringRule]) -> Void

    @State private var newObjectName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if rules.isEmpty {
                Text("No object rules yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach($rules) { $rule in
                    HStack(alignment: .center, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.displayName)
                                .font(.caption)
                            Text(rule.objectKey)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 0)

                        TextField(
                            "Score",
                            value: $rule.score,
                            format: .number.precision(.fractionLength(2))
                        )
                        .keyboardType(.decimalPad)
                        .frame(width: 56)
                        .font(.caption.monospacedDigit())

                        Button(role: .destructive) {
                            rules.removeAll { $0.id == rule.id }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack(spacing: 8) {
                TextField("Add object (e.g. christmas tree)", text: $newObjectName)
                    .font(.caption)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button("Add") {
                    addObject()
                }
                .font(.caption.weight(.semibold))
                .disabled(
                    OccasionObjectKeyFormatter.canonical(from: newObjectName) == nil
                )
            }

            Button("Save objects") {
                onSave(rules)
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.bordered)
        }
    }

    private func addObject() {
        guard let objectKey = OccasionObjectKeyFormatter.canonical(from: newObjectName) else {
            return
        }
        guard !rules.contains(where: { $0.objectKey == objectKey }) else {
            newObjectName = ""
            return
        }

        rules.append(
            EditableObjectScoringRule(
                occasionId: occasionId,
                objectKey: objectKey,
                score: 0.40
            )
        )
        newObjectName = ""
    }
}
