import SwiftUI

/// Apple Photos–style sheet: adjust the first-selected photo’s date; others shift by the same delta.
struct PhotoAdjustDateTimeSheet: View {
    let originalDate: Date
    let selectedCount: Int
    let onCancel: () -> Void
    let onAdjust: (_ adjustedDate: Date, _ timeZone: TimeZone) -> Void

    @State private var adjustedDate: Date
    @State private var timeZone: TimeZone
    @State private var isShowingTimeZonePicker = false

    init(
        originalDate: Date,
        selectedCount: Int,
        onCancel: @escaping () -> Void,
        onAdjust: @escaping (_ adjustedDate: Date, _ timeZone: TimeZone) -> Void
    ) {
        self.originalDate = originalDate
        self.selectedCount = selectedCount
        self.onCancel = onCancel
        self.onAdjust = onAdjust
        _adjustedDate = State(initialValue: originalDate)
        _timeZone = State(initialValue: .current)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summarySection
                    pickerSection
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Adjust Date & Time")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onCancel) {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Close")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Adjust") {
                        onAdjust(adjustedDate, timeZone)
                    }
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.accentColor, in: Capsule())
                    .foregroundStyle(.white)
                }
            }
            .navigationDestination(isPresented: $isShowingTimeZonePicker) {
                timeZonePicker
            }
        }
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Original")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(Self.displayString(originalDate, timeZone: timeZone))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            HStack {
                Text("Adjusted")
                Spacer()
                Text(Self.displayString(adjustedDate, timeZone: timeZone))
                    .multilineTextAlignment(.trailing)
            }
            Text(
                "The original date and time of your first selected photo is shown above. Adjust it to the correct time, and all \(selectedCount) selected photo\(selectedCount == 1 ? "" : "s") will be time-shifted accordingly."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var pickerSection: some View {
        VStack(spacing: 0) {
            DatePicker(
                "Date",
                selection: $adjustedDate,
                displayedComponents: [.date]
            )
            .datePickerStyle(.graphical)
            .labelsHidden()
            .environment(\.timeZone, timeZone)

            Divider()

            DatePicker(
                "Time",
                selection: $adjustedDate,
                displayedComponents: [.hourAndMinute]
            )
            .environment(\.timeZone, timeZone)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            Button {
                isShowingTimeZonePicker = true
            } label: {
                HStack {
                    Text("Time Zone")
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(Self.gmtOffsetLabel(for: timeZone))
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var timeZonePicker: some View {
        List {
            ForEach(Self.sortedTimeZones, id: \.identifier) { zone in
                Button {
                    timeZone = zone
                    isShowingTimeZonePicker = false
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(zone.identifier.replacingOccurrences(of: "_", with: " "))
                            Text(Self.gmtOffsetLabel(for: zone))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if zone.identifier == timeZone.identifier {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
        }
        .navigationTitle("Time Zone")
        .navigationBarTitleDisplayMode(.inline)
    }

    static func displayString(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "MMM d, yyyy 'at' h:mm:ss a"
        return formatter.string(from: date)
    }

    static func gmtOffsetLabel(for timeZone: TimeZone, at date: Date = Date()) -> String {
        let seconds = timeZone.secondsFromGMT(for: date)
        let sign = seconds >= 0 ? "+" : "-"
        let absSeconds = abs(seconds)
        let hours = absSeconds / 3600
        let minutes = (absSeconds % 3600) / 60
        return String(format: "GMT%@%02d:%02d", sign, hours, minutes)
    }

    private static let sortedTimeZones: [TimeZone] = {
        TimeZone.knownTimeZoneIdentifiers
            .compactMap(TimeZone.init(identifier:))
            .sorted { lhs, rhs in
                let lo = lhs.secondsFromGMT()
                let ro = rhs.secondsFromGMT()
                if lo != ro { return lo < ro }
                return lhs.identifier < rhs.identifier
            }
    }()
}
