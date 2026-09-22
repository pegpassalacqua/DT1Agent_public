import Charts
import SwiftUI

/// Tapping a calendar day opens this: the full-day glucose curve, the
/// day's TIR bar, and every meal/dose logged that day (fetched from the
/// server, so any past day works — not just the 48 h local cache).
struct DayDetailView: View {
    let day: String // "2026-07-13"
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var state

    @State private var points: [ChartPoint] = []
    @State private var meals: [MealPoint] = []
    @State private var doses: [DosePoint] = []
    @State private var loading = true
    @State private var failed = false

    private var tir: (low: Double, inRange: Double, high: Double)? {
        guard !points.isEmpty else { return nil }
        let total = Double(points.count)
        let range = state.targetRange
        let low = Double(points.count { $0.value < range.lowerBound })
        let high = Double(points.count { $0.value > range.upperBound })
        return (low / total * 100, (total - low - high) / total * 100, high / total * 100)
    }

    private var title: String {
        guard let date = ISO.date(day + "T12:00:00Z") as Date?,
              date != .distantPast
        else { return day }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView("Loading day…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if failed {
                    VStack(spacing: 8) {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("Could not load this day.")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    content
                }
            }
            .background(Color.appBackground)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let t = tir {
                    VStack(spacing: 6) {
                        HStack {
                            Text("In range \(Int(t.inRange.rounded()))%")
                                .font(.subheadline.bold())
                                .foregroundStyle(.green)
                            Spacer()
                            if t.low >= 0.5 {
                                Text("Low \(Int(t.low.rounded()))%")
                                    .font(.caption).foregroundStyle(.red)
                            }
                            Spacer()
                            if t.high >= 0.5 {
                                Text("High \(Int(t.high.rounded()))%")
                                    .font(.caption).foregroundStyle(.orange)
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

                chart

                eventList
            }
            .padding()
        }
    }

    private var chart: some View {
        Chart {
            ForEach(points) { p in
                LineMark(x: .value("Time", p.date), y: .value("mg/dL", p.value))
                    .foregroundStyle(.teal)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    .interpolationMethod(.monotone)
            }
            ForEach(meals) { m in
                PointMark(x: .value("Time", m.date), y: .value("mg/dL", 50.0))
                    .foregroundStyle(.orange)
                    .symbol(.triangle)
            }
            ForEach(doses.filter { $0.type != "basal" }) { d in
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
        .chartYScale(domain: 40...max(260, (points.map(\.value).max() ?? 260) + 20))
        .frame(height: 220)
    }

    private enum DayEvent: Identifiable {
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

    private var events: [DayEvent] {
        (meals.map(DayEvent.meal) + doses.map(DayEvent.dose))
            .sorted { $0.date < $1.date } // chronological within the day
    }

    private var eventList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Records for the day")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)
            if events.isEmpty {
                Text("No records on this day.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(events) { event in
                HStack {
                    switch event {
                    case .meal(let m):
                        Image(systemName: "fork.knife").foregroundStyle(.orange)
                        Text(m.description ?? String(localized: "Meal"))
                        Spacer()
                        Text(verbatim: "\(Int(m.carbsG)) g").foregroundStyle(.secondary)
                    case .dose(let d):
                        Image(systemName: "syringe").foregroundStyle(.blue)
                        Text(DoseKind.label(d.type))
                        Spacer()
                        Text(String(format: "%.1f U", d.units)).foregroundStyle(.secondary)
                    }
                    Text(event.date.formatted(date: .omitted, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
                Divider()
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.cardBackground)
        )
    }

    private func load() async {
        loading = true
        do {
            let detail = try await APIClient.day(day)
            points = detail.readings.map {
                ChartPoint(id: $0.id, date: ISO.date($0.measuredAt), value: $0.valueMgDl)
            }
            meals = detail.meals.map {
                MealPoint(id: $0.id, date: ISO.date($0.eatenAt),
                          carbsG: $0.carbsG, fpu: $0.fpu,
                          proteinG: $0.proteinG, fatG: $0.fatG, fiberG: $0.fiberG,
                          description: $0.description)
            }
            doses = detail.doses.map {
                DosePoint(id: $0.id, date: ISO.date($0.injectedAt),
                          units: $0.units, type: $0.type)
            }
        } catch {
            failed = true
        }
        loading = false
    }
}
