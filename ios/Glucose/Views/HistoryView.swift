import Charts
import SwiftUI

/// Glucose curve with meal and insulin markers overlaid.
/// Consumes pre-parsed points from AppState; the visible window is cached
/// and downsampled so pinch/tab switches stay fluid.
struct HistoryView: View {
    @Environment(AppState.self) private var state
    @State private var hours: Double = 12
    @State private var baseHours: Double = 12
    @State private var visible: [ChartPoint] = []
    @State private var tir: (low: Double, inRange: Double, high: Double)?
    @State private var editing: EditableRecord?

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Picker("Period", selection: $hours) {
                    Text("6 h").tag(6.0)
                    Text("12 h").tag(12.0)
                    Text("24 h").tag(24.0)
                    Text("48 h").tag(48.0)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                if let tir {
                    tirBar(tir)
                        .padding(.horizontal)
                }

                chart
                    .padding(.horizontal)
                    // Pinch to zoom the time window: spread fingers = fewer
                    // hours (zoom in), pinch = more hours (zoom out).
                    .gesture(
                        MagnificationGesture()
                            .onChanged { scale in
                                hours = min(48, max(2, baseHours / scale))
                            }
                            .onEnded { _ in baseHours = hours }
                    )

                Text("last \(Int(hours)) h · pinch to adjust")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                eventList
            }
            .background(Color.appBackground)
            .navigationTitle("History")
            .refreshable { await state.refresh() }
            .onAppear { rebuildVisible() }
            .onChange(of: hours) { _, _ in rebuildVisible() }
            .onChange(of: state.chartPoints) { _, _ in rebuildVisible() }
            .onChange(of: state.targetRange) { _, _ in rebuildVisible() }
            .sheet(item: $editing) { record in
                EditRecordView(record: record).presentationCornerRadius(28)
            }
        }
    }

    private var since: Date { Date().addingTimeInterval(-hours * 3600) }

    /// Filter + downsample + time-in-range once per change — never during render.
    private func rebuildVisible() {
        let windowed = state.chartPoints.filter { $0.date >= since }
        visible = downsample(windowed, to: 180)

        // TIR uses ALL readings in the window (not the downsampled set).
        if windowed.isEmpty {
            tir = nil
        } else {
            let total = Double(windowed.count)
            let range = state.targetRange
            let low = Double(windowed.count { $0.value < range.lowerBound })
            let high = Double(windowed.count { $0.value > range.upperBound })
            tir = (low: low / total * 100,
                   inRange: (total - low - high) / total * 100,
                   high: high / total * 100)
        }
    }

    /// Stacked % bar: below / in range (70–180) / above, for the window.
    private func tirBar(_ t: (low: Double, inRange: Double, high: Double)) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text("In range \(Int(t.inRange.rounded()))%")
                    .font(.subheadline.bold())
                    .foregroundStyle(.green)
                Spacer()
                if t.low >= 0.5 {
                    Text("Low \(Int(t.low.rounded()))%")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Spacer()
                if t.high >= 0.5 {
                    Text("High \(Int(t.high.rounded()))%")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            // Segment order mirrors the labels: in-range | low | high.
            GeometryReader { geo in
                HStack(spacing: 2) {
                    Capsule().fill(.green)
                        .frame(width: max(4, geo.size.width * t.inRange / 100))
                    if t.low >= 0.5 {
                        Capsule().fill(.red)
                            .frame(width: geo.size.width * t.low / 100)
                    }
                    if t.high >= 0.5 {
                        Capsule().fill(.orange)
                            .frame(width: geo.size.width * t.high / 100)
                    }
                }
            }
            .frame(height: 8)
        }
    }

    /// Keeps at most `maxCount` evenly spaced points (plus the newest one).
    private func downsample(_ pts: [ChartPoint], to maxCount: Int) -> [ChartPoint] {
        guard pts.count > maxCount else { return pts }
        let step = Double(pts.count) / Double(maxCount)
        var out = (0..<maxCount).map { pts[Int(Double($0) * step)] }
        if let last = pts.last, out.last?.id != last.id { out.append(last) }
        return out
    }

    private var chart: some View {
        Chart {
            ForEach(visible) { p in
                LineMark(x: .value("Time", p.date), y: .value("mg/dL", p.value))
                    .foregroundStyle(.teal)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    // Monotone: rounds corners without overshooting the
                    // measured values — the curve never invents data.
                    .interpolationMethod(.monotone)
            }
            ForEach(state.mealPoints.filter { $0.date >= since }) { m in
                PointMark(x: .value("Time", m.date), y: .value("mg/dL", 50.0))
                    .foregroundStyle(.orange)
                    .symbol(.triangle)
            }
            ForEach(state.dosePoints.filter { $0.date >= since && $0.type != "basal" }) { d in
                PointMark(x: .value("Time", d.date), y: .value("mg/dL", 44.0))
                    .foregroundStyle(.blue)
                    .symbol(.diamond)
            }
            RuleMark(y: .value("Low", state.targetRange.lowerBound))
                .lineStyle(StrokeStyle(dash: [4]))
                .foregroundStyle(.red.opacity(0.4))
            RuleMark(y: .value("High", state.targetRange.upperBound))
                .lineStyle(StrokeStyle(dash: [4]))
                .foregroundStyle(.orange.opacity(0.4))
        }
        .chartYScale(domain: 40...max(260, (visible.map(\.value).max() ?? 260) + 20))
        .frame(height: 260)
    }

    /// Meals and doses merged into one strictly chronological feed.
    private enum HistoryEvent: Identifiable {
        case meal(MealPoint)
        case dose(DosePoint)

        var id: String {
            switch self {
            case .meal(let m): "m\(m.id)"
            case .dose(let d): "d\(d.id)"
            }
        }

        var date: Date {
            switch self {
            case .meal(let m): m.date
            case .dose(let d): d.date
            }
        }
    }

    /// The list always shows the full 48 h of cached records, independent
    /// of the chart's zoom window.
    private var events: [HistoryEvent] {
        let merged = state.mealPoints.map(HistoryEvent.meal)
            + state.dosePoints.map(HistoryEvent.dose)
        return merged.sorted { $0.date > $1.date } // newest first
    }

    private func editable(_ event: HistoryEvent) -> EditableRecord {
        switch event {
        case .meal(let m): .meal(m)
        case .dose(let d): .dose(d)
        }
    }

    private func delete(_ event: HistoryEvent) async {
        switch event {
        case .meal(let m): try? await APIClient.deleteMeal(id: m.id)
        case .dose(let d): try? await APIClient.deleteDose(id: d.id)
        }
        await state.refresh()
    }

    /// "13:05" for today, "yesterday 13:05" for yesterday, date otherwise.
    private func timeLabel(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(date) { return time }
        if Calendar.current.isDateInYesterday(date) { return String(localized: "yesterday \(time)") }
        return date.formatted(.dateTime.day().month(.abbreviated)) + " \(time)"
    }

    private var eventList: some View {
        List {
            Section("Last 48 h") {
                ForEach(events) { event in
                    Group {
                        switch event {
                        case .meal(let m):
                            HStack {
                                Image(systemName: "fork.knife").foregroundStyle(.orange)
                                Text(m.description ?? String(localized: "Meal"))
                                Spacer()
                                Text(verbatim: "\(Int(m.carbsG)) g")
                                    .foregroundStyle(.secondary)
                                Text(timeLabel(m.date))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        case .dose(let d):
                            HStack {
                                Image(systemName: "syringe").foregroundStyle(.blue)
                                Text(DoseKind.label(d.type))
                                Spacer()
                                Text(String(format: "%.1f U", d.units))
                                    .foregroundStyle(.secondary)
                                Text(timeLabel(d.date))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { editing = editable(event) }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            Task { await delete(event) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button {
                            editing = editable(event)
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}
