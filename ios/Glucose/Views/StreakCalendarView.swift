import SwiftUI

/// Progress tab: streak counter + month calendar colored by whether each
/// day met the time-in-range goal. The goal (% of readings in 70–180) lives
/// in Settings — changing it recomputes everything instantly, since the
/// server ships raw daily percentages and the goal is applied here.
struct StreakCalendarView: View {
    @Environment(AppState.self) private var state
    @AppStorage("tirGoalPct") private var goalPct = 70.0
    @State private var monthAnchor = Date()
    @State private var selectedDay: SelectedDay?
    /// Opening on today's month shows an empty grid on the 1st of a month.
    /// Jump to the newest month that actually has data — once, not on every
    /// refresh, so manual month navigation isn't undone.
    @State private var pickedInitialMonth = false

    private struct SelectedDay: Identifiable {
        let id: String // "2026-07-13"
    }

    /// One slot in the month grid — either a leading blank or a real day.
    /// Built explicitly with stable ids: `ForEach` over a *changing* range
    /// (the old `0..<leading`) makes SwiftUI reuse cells across months, which
    /// silently blanked the first days when navigating.
    private struct CalendarCell: Identifiable {
        let id: String
        let day: Int?      // nil = blank padding cell
        let key: String?   // "yyyy-MM-dd", nil for blanks
        let isToday: Bool
        let isFuture: Bool
    }

    /// "August 2026", in the user's language.
    private var monthTitle: String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("LLLLyyyy")
        // Only the first letter: .capitalized would give "Setembro De 2026".
        let s = f.string(from: monthAnchor)
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    /// Blanks + every day of `monthAnchor`'s month, in display order.
    private var monthCells: [CalendarCell] {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: monthAnchor)
        guard let firstOfMonth = cal.date(from: comps),
              let range = cal.range(of: .day, in: .month, for: firstOfMonth)
        else { return [] }

        // Monday-first column offset (weekday: 1=Sun ... 7=Sat).
        let leading = (cal.component(.weekday, from: firstOfMonth) + 5) % 7
        let todayKey = Self.dayFormatter.string(from: Date())
        let now = Date()
        let monthTag = Self.dayFormatter.string(from: firstOfMonth)

        var cells = (0..<leading).map {
            CalendarCell(id: "blank-\(monthTag)-\($0)", day: nil, key: nil,
                         isToday: false, isFuture: false)
        }
        for day in range {
            guard let date = cal.date(byAdding: .day, value: day - 1, to: firstOfMonth)
            else { continue }
            let key = Self.dayFormatter.string(from: date)
            cells.append(CalendarCell(id: key, day: day, key: key,
                                      isToday: key == todayKey, isFuture: date > now))
        }
        return cells
    }

    /// Monday-first, matching the `leading` offset computed below. The
    /// symbols come Sunday-first, in the user's language.
    private static let weekdayInitials: [String] = {
        let symbols = Calendar.current.shortStandaloneWeekdaySymbols
        return Array(symbols[1...]) + [symbols[0]]
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        // Fixed locale: this formats lookup keys, not user-facing text.
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Fast lookup: "2026-07-13" -> pct in range.
    private var pctByDay: [String: Double] {
        Dictionary(uniqueKeysWithValues: state.dailyTIR.map { ($0.day, $0.pctInRange) })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    streakCards
                    calendarCard
                    goalCard
                }
                .padding(.horizontal)
                .padding(.bottom, 12)
            }
            .background(Color.appBackground)
            .navigationTitle("Progress")
            .refreshable { await state.refresh() }
            .onAppear { jumpToLatestMonthWithData() }
            .onChange(of: state.dailyTIR) { _, _ in jumpToLatestMonthWithData() }
            .sheet(item: $selectedDay) { sel in
                DayDetailView(day: sel.id).presentationCornerRadius(28)
            }
        }
    }

    // MARK: streaks

    private var streaks: (current: Int, best: Int) {
        let byDay = pctByDay
        let cal = Calendar.current

        func met(_ date: Date) -> Bool? {
            guard let pct = byDay[Self.dayFormatter.string(from: date)] else { return nil }
            return pct >= goalPct
        }

        // Current: count back from today (today counts only while it's meeting
        // the goal; a not-yet-met today doesn't break yesterday's streak).
        var current = 0
        var cursor = Date()
        if met(cursor) == true { current += 1 }
        while true {
            guard let prev = cal.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
            if met(cursor) == true { current += 1 } else { break }
        }

        // Best: longest run across all data.
        var best = 0
        var run = 0
        for entry in state.dailyTIR.sorted(by: { $0.day < $1.day }) {
            if entry.pctInRange >= goalPct {
                run += 1
                best = max(best, run)
            } else {
                run = 0
            }
        }
        return (current, max(best, current))
    }

    private var streakCards: some View {
        let s = streaks
        return HStack(spacing: 12) {
            statCard(icon: "flame.fill", title: "Current streak",
                     value: "\(s.current)", unit: s.current == 1 ? "day" : "days",
                     color: .orange)
            statCard(icon: "trophy.fill", title: "Best streak",
                     value: "\(s.best)", unit: s.best == 1 ? "day" : "days",
                     color: .yellow)
        }
    }

    private func statCard(icon: String, title: LocalizedStringKey, value: String,
                          unit: LocalizedStringKey, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.caption.bold())
                .foregroundStyle(color)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(unit)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.cardBackground)
        )
    }

    // MARK: calendar

    private var calendarCard: some View {
        let cal = Calendar.current
        let byDay = pctByDay
        let cells = monthCells
        // Fixed 7-per-row chunks: a plain VStack of HStacks renders every
        // cell eagerly, unlike LazyVGrid which can skip offscreen ones.
        let rows = stride(from: 0, to: cells.count, by: 7).map {
            Array(cells[$0..<min($0 + 7, cells.count)])
        }

        return VStack(spacing: 12) {
            HStack {
                Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
                Spacer()
                Text(monthTitle)
                    .font(.headline)
                Spacer()
                Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(cal.isDate(monthAnchor, equalTo: Date(), toGranularity: .month))
            }

            VStack(spacing: 8) {
                HStack(spacing: 0) {
                    ForEach(Array(Self.weekdayInitials.enumerated()), id: \.offset) { _, d in
                        Text(d)
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 0) {
                        ForEach(row) { cell in
                            Group {
                                if let day = cell.day, let key = cell.key {
                                    let pct = byDay[key]
                                    dayCell(day, pct: pct, isToday: cell.isToday,
                                            isFuture: cell.isFuture)
                                        .contentShape(Circle())
                                        .onTapGesture {
                                            // Only days with data open the detail sheet.
                                            if pct != nil { selectedDay = SelectedDay(id: key) }
                                        }
                                } else {
                                    Color.clear.frame(height: 38)
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                        // Pad the last row so its cells keep the same width.
                        if row.count < 7 {
                            ForEach(0..<(7 - row.count), id: \.self) { _ in
                                Color.clear.frame(maxWidth: .infinity, minHeight: 38)
                            }
                        }
                    }
                }
            }

            HStack(spacing: 14) {
                legend(color: .green, label: "≥ \(Int(goalPct))%")
                legend(color: .orange, label: "below")
                legend(color: Color.secondary.opacity(0.3), label: "no data")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.cardBackground)
        )
    }

    /// Every day of the month renders a readable number — days without data
    /// (including future ones) previously used a near-invisible 0.06 fill,
    /// which made a fresh month look like it was missing days.
    private func dayCell(_ day: Int, pct: Double?, isToday: Bool, isFuture: Bool) -> some View {
        ZStack {
            if let pct {
                Circle().fill(pct >= goalPct ? Color.green : Color.orange)
            } else if !isFuture {
                Circle().fill(Color.secondary.opacity(0.18))
            }
            Text("\(day)")
                .font(.caption.bold())
                .foregroundStyle(
                    pct != nil ? Color.white
                        : (isFuture ? Color.secondary.opacity(0.55) : Color.secondary)
                )
        }
        .frame(height: 38)
        .overlay {
            if isToday {
                Circle().strokeBorder(.teal, lineWidth: 2)
            }
        }
    }

    private func legend(color: Color, label: LocalizedStringKey) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
        }
    }

    /// On the 1st of a month the current month is nearly empty — land on the
    /// newest month that has readings instead. Runs only once per session.
    private func jumpToLatestMonthWithData() {
        guard !pickedInitialMonth,
              let latest = state.dailyTIR.map(\.day).max(),
              let date = Self.dayFormatter.date(from: latest)
        else { return }
        pickedInitialMonth = true
        monthAnchor = date
    }

    private func shiftMonth(_ delta: Int) {
        if let next = Calendar.current.date(byAdding: .month, value: delta, to: monthAnchor) {
            monthAnchor = next
        }
    }

    // MARK: goal

    private var goalCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Daily goal", systemImage: "target")
                .font(.caption.bold())
                .foregroundStyle(.teal)
            HStack {
                Text("In range at least")
                Spacer()
                Text("\(Int(goalPct))%")
                    .font(.title3.bold().monospacedDigit())
                    .foregroundStyle(.teal)
            }
            Slider(value: $goalPct, in: 40...95, step: 5)
            Text("Changing the goal recalculates the calendar and streak instantly. The usual clinical reference is 70%.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.cardBackground)
        )
    }
}
