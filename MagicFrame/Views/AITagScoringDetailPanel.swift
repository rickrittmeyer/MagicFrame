import SwiftUI

struct AITagScoringDetailPanel: View {

    let detail: AITagScoringDetail
    let editorRevision: Int
    let onDismiss: (() -> Void)?
    let onSaveDateScoring: ((OccasionDateScoringEdit) -> Void)?
    let onSaveObjectScoring: (([EditableObjectScoringRule]) -> Void)?

    @State private var anchorDate = Date()
    @State private var windowDaysBefore = 0
    @State private var windowDaysAfter = 0
    @State private var usesThanksgivingRelativeStart = false
    @State private var windowDaysAfterThanksgiving = 0
    @State private var objectRules: [EditableObjectScoringRule] = []
    @State private var didInitializeEditors = false

    private static let dateDisplayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    init(
        detail: AITagScoringDetail,
        editorRevision: Int = 0,
        onDismiss: (() -> Void)? = nil,
        onSaveDateScoring: ((OccasionDateScoringEdit) -> Void)? = nil,
        onSaveObjectScoring: (([EditableObjectScoringRule]) -> Void)? = nil
    ) {
        self.detail = detail
        self.editorRevision = editorRevision
        self.onDismiss = onDismiss
        self.onSaveDateScoring = onSaveDateScoring
        self.onSaveObjectScoring = onSaveObjectScoring
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Holiday scorecard")
                        .font(.subheadline.weight(.semibold))

                    Text("\(detail.tagCategory): \(detail.tagLabel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if let onDismiss {
                    Button("Close", action: onDismiss)
                        .font(.caption)
                }
            }

            if let statusNote = detail.statusNote {
                Text(statusNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let occasionName = detail.occasionName,
               let scoringYear = detail.scoringYear {
                Text("\(occasionName) · \(scoringYear)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let unavailableReason = detail.unavailableReason {
                Text(unavailableReason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if detail.dateScoringBreakdown != nil || detail.supportsDateScoringEdits {
                dateScoringSection
            }

            if detail.hasScoreBreakdown {
                scoreComponentsSection
            }

            if detail.supportsObjectScoringEdits, onSaveObjectScoring != nil,
               let occasionId = detail.occasionId {
                objectScoringEditorSection(occasionId: occasionId)
            }

            if !detail.scoringRules.isEmpty {
                scoringRulesSection
            }

            if !detail.tunableSettings.isEmpty {
                tunableSettingsSection
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .onAppear {
            initializeEditorsIfNeeded()
        }
        .onChange(of: detail.id) { _, _ in
            didInitializeEditors = false
            initializeEditorsIfNeeded()
        }
        .onChange(of: editorRevision) { _, _ in
            didInitializeEditors = false
            initializeEditorsIfNeeded()
        }
    }

    private var dateScoringSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Date scoring")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if let breakdown = detail.dateScoringBreakdown {
                dateInfoRow("Anchor date", value: formatISO(breakdown.anchorDateISO))
                if let thanksgivingDateISO = detail.thanksgivingDateISO {
                    dateInfoRow("Thanksgiving", value: formatISO(thanksgivingDateISO))
                }
                dateInfoRow("Window", value: "\(formatISO(breakdown.windowStartISO)) – \(formatISO(breakdown.windowEndISO))")
                dateInfoRow("Event range", value: "\(formatISO(breakdown.eventRangeStartISO)) – \(formatISO(breakdown.eventRangeEndISO))")
                dateInfoRow("Event midpoint", value: formatISO(breakdown.eventMidpointISO))
                dateInfoRow("Days from anchor", value: "\(breakdown.dayOffset)")
                dateInfoRow("Window span", value: "\(breakdown.windowSpanDays) days")
                dateInfoRow("Decay span", value: "\(breakdown.decaySpan) days")

                if breakdown.overlapsWindow {
                    Text(
                        breakdown.dayOffset == 0
                            ? "Formula: 1.00 on anchor day"
                            : "Formula: 1.00 − (\(breakdown.dayOffset) ÷ \(breakdown.decaySpan)) = \(format(breakdown.computedDateScore))"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                } else {
                    Text("Event midpoint is outside the scoring window, so date score is 0.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if detail.supportsDateScoringEdits, onSaveDateScoring != nil {
                Divider()

                Text("Edit date scoring")
                    .font(.caption.weight(.medium))

                DatePicker(
                    "Christmas anchor",
                    selection: $anchorDate,
                    displayedComponents: .date
                )
                .font(.caption)

                if detail.occasionKey == "christmas" {
                    Toggle("Window starts after Thanksgiving", isOn: $usesThanksgivingRelativeStart)
                        .font(.caption)

                    if usesThanksgivingRelativeStart {
                        Stepper(
                            "Days after Thanksgiving: \(windowDaysAfterThanksgiving)",
                            value: $windowDaysAfterThanksgiving,
                            in: 0...30
                        )
                        .font(.caption)

                        Stepper(
                            "Days after Christmas (end): \(windowDaysAfter)",
                            value: $windowDaysAfter,
                            in: 0...60
                        )
                        .font(.caption)
                    } else {
                        Stepper(
                            "Days before anchor: \(windowDaysBefore)",
                            value: $windowDaysBefore,
                            in: 0...60
                        )
                        .font(.caption)

                        Stepper(
                            "Days after anchor: \(windowDaysAfter)",
                            value: $windowDaysAfter,
                            in: 0...60
                        )
                        .font(.caption)
                    }
                } else {
                    Stepper(
                        "Days before: \(windowDaysBefore)",
                        value: $windowDaysBefore,
                        in: 0...60
                    )
                    .font(.caption)

                    Stepper(
                        "Days after: \(windowDaysAfter)",
                        value: $windowDaysAfter,
                        in: 0...60
                    )
                    .font(.caption)
                }

                Text("Applies to all events for this holiday. This event is re-scored when you save.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Button("Save date scoring") {
                    onSaveDateScoring?(
                        OccasionDateScoringEdit(
                            anchorDate: anchorDate,
                            windowDaysBefore: windowDaysBefore,
                            windowDaysAfter: windowDaysAfter,
                            usesThanksgivingRelativeStart: usesThanksgivingRelativeStart,
                            windowDaysAfterThanksgiving: windowDaysAfterThanksgiving
                        )
                    )
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
            }
        }
    }

    private var scoreComponentsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Score components")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text("Raw signals (before weights)")
                .font(.caption2)
                .foregroundStyle(.secondary)

            scoreRow("Date score", value: detail.dateScore)
            textSignalScoreBlock
            objectSignalScoreBlock
            scoreRow("Weekend boost", value: detail.weekendScore)

            if let weighted = detail.weightedBreakdown {
                Divider()

                Text("Weighted base (\(weighted.selectedFormula == .postObject ? "post-object" : "pre-object"))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                scoreRow(
                    "Date × \(format(weighted.dateWeight))",
                    value: weighted.weightedDateContribution
                )
                scoreRow(
                    "Text × \(format(weighted.textWeight))",
                    value: weighted.weightedTextContribution
                )
                if weighted.objectWeight > 0 {
                    scoreRow(
                        "Object × \(format(weighted.objectWeight))",
                        value: weighted.weightedObjectContribution
                    )
                }

                scoreRow("Base score", value: weighted.baseScore, emphasized: true)

                if weighted.postObjectBase != nil,
                   weighted.preObjectBase != weighted.baseScore {
                    Text(
                        String(
                            format: "Pre-object base was %.2f; post-object base was %.2f — higher value used.",
                            weighted.preObjectBase,
                            weighted.postObjectBase ?? weighted.baseScore
                        )
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                scoreRow(
                    "Total score",
                    value: weighted.totalScore,
                    note: weighted.weekendScore > 0
                        ? "min(1.00, base + weekend)"
                        : nil,
                    emphasized: true
                )

                Text(weighted.formulaSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                scoreRow(
                    "Base score",
                    value: detail.baseScore,
                    note: baseScoreFormulaNote
                )
                scoreRow("Total score", value: detail.totalScore, emphasized: true)
            }

            if let confidence = detail.confidence {
                HStack {
                    Text("Confidence")
                        .font(.caption)
                    Spacer()
                    Text(confidence)
                        .font(.caption.weight(.medium))
                }
            }

            if let phase = detail.appliedPhase {
                HStack {
                    Text("Applied phase")
                        .font(.caption)
                    Spacer()
                    Text(phase == .preObject ? "Pre-object" : "Post-object")
                        .font(.caption.weight(.medium))
                }
            }
        }
    }

    private var baseScoreFormulaNote: String {
        if detail.objectRecognitionCompleted,
           (detail.objectScore ?? 0) > 0,
           detail.objectWeight > 0 {
            return "date × \(format(detail.dateWeight)) + text × \(format(detail.textWeight)) + object × \(format(detail.objectWeight))"
        }
        return "date × \(format(detail.dateWeight)) + text × \(format(detail.textWeight))"
    }

    @ViewBuilder
    private func objectScoringEditorSection(occasionId: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Object scoring")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(
                "Objects for this holiday. Saved rules are scanned on candidate events (pre-object score ≥ 0.45). "
                    + "Saving clears prior scans so new objects are picked up on re-open."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)

            OccasionObjectRulesEditor(
                occasionId: occasionId,
                rules: $objectRules,
                onSave: { savedRules in
                    onSaveObjectScoring?(savedRules)
                }
            )
        }
    }

    @ViewBuilder
    private var objectSignalScoreBlock: some View {
        if let objectSignalScore = detail.objectScore {
            VStack(alignment: .leading, spacing: 6) {
                scoreRow("Object score", value: objectSignalScore)

                if !detail.objectRecognitionCompleted {
                    Text("Object weight is 0 until object recognition runs on this event.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if (detail.objectScore ?? 0) <= 0 {
                    Text(
                        "Object scan completed but no configured objects met the confidence threshold. "
                            + "Metadata-only AI holiday tags are removed after scan."
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                if detail.objectScoringRules.isEmpty {
                    Text("No object rules configured for this holiday.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if detail.matchedObjectRules.isEmpty {
                    Text("No configured objects detected on this event yet.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(detail.matchedObjectRules) { rule in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                                .padding(.top, 1)

                            Text(rule.displayLabel)
                                .font(.caption)

                            Spacer(minLength: 0)

                            Text(rule.contributionLabel)
                                .font(.caption.monospacedDigit())
                        }
                    }

                    if detail.objectSignalWasCapped {
                        Text(
                            "Matched object contributions total \(format(detail.objectSignalRawTotal)); capped at 1.00 for object score."
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var textSignalScoreBlock: some View {
        if let textSignalScore = detail.albumScore {
            VStack(alignment: .leading, spacing: 6) {
                scoreRow("Text signal score", value: textSignalScore)

                if detail.matchedTextSignalRules.isEmpty {
                    Text("No filename, photo title, or album title rules matched.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(detail.matchedTextSignalRules) { rule in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                                .padding(.top, 1)

                            Text(rule.displayLabel)
                                .font(.caption)

                            Spacer(minLength: 0)

                            Text(String(format: "+%.2f", rule.score))
                                .font(.caption.monospacedDigit())
                        }
                    }

                    if detail.textSignalWasCapped {
                        Text(
                            "Matched rules total \(format(detail.textSignalRawTotal)); capped at 1.00 for text signal score."
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var scoringRulesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("All configured rules")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text("All text and object rules for this holiday. Matched rules are itemized above.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            ForEach(detail.scoringRules) { rule in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: rule.matched ? "checkmark.circle.fill" : "circle")
                        .font(.caption)
                        .foregroundStyle(rule.matched ? .green : .secondary)
                        .padding(.top, 1)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(rule.displayLabel)
                            .font(.caption)
                        Text(String(format: "+%.2f when matched", rule.score))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var tunableSettingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tunable values")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(detail.tunableSettings) { setting in
                HStack {
                    Text(setting.label)
                        .font(.caption)
                    Spacer()
                    Text(setting.value)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func initializeEditorsIfNeeded() {
        guard !didInitializeEditors else { return }
        windowDaysBefore = detail.windowDaysBefore ?? 0
        windowDaysAfter = detail.windowDaysAfter ?? 0
        usesThanksgivingRelativeStart = detail.usesThanksgivingRelativeStart
        windowDaysAfterThanksgiving = detail.windowDaysAfterThanksgiving ?? 0
        if let occasionId = detail.occasionId {
            objectRules = detail.objectScoringRules.map {
                EditableObjectScoringRule(
                    occasionId: occasionId,
                    objectKey: $0.signalValue,
                    score: $0.score
                )
            }
        }

        if let anchorDateISO = detail.anchorDateISO,
           let parsed = EventDateParser.parseDate(anchorDateISO) {
            anchorDate = parsed
        } else if let scoringYear = detail.scoringYear {
            var components = DateComponents()
            components.year = scoringYear
            components.month = 12
            components.day = 25
            anchorDate = Calendar.current.date(from: components) ?? Date()
        }

        didInitializeEditors = true
    }

    @ViewBuilder
    private func dateInfoRow(_ label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption)
            Spacer()
            Text(value)
                .font(.caption.monospacedDigit())
                .multilineTextAlignment(.trailing)
        }
    }

    @ViewBuilder
    private func scoreRow(
        _ label: String,
        value: Double?,
        note: String? = nil,
        emphasized: Bool = false
    ) -> some View {
        if let value {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(label)
                        .font(emphasized ? .caption.weight(.semibold) : .caption)
                    Spacer()
                    Text(format(value))
                        .font(emphasized ? .caption.weight(.semibold) : .caption.monospacedDigit())
                }
                if let note {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func formatISO(_ iso: String) -> String {
        guard let date = EventDateParser.parseDate(iso) else { return iso }
        return Self.dateDisplayFormatter.string(from: date)
    }

    private func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
