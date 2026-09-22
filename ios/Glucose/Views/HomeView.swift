import Charts
import SwiftUI

/// Home: the at-a-glance decision screen. Hero card with the current value,
/// IOB/COB stat cards, 12 h gradient chart, and one-tap action cards.
/// Fast: no decorative animations beyond snappy number transitions.
struct HomeView: View {
    @Environment(AppState.self) private var state
    @Environment(\.colorScheme) private var scheme
    @State private var showTreatment = false
    @State private var showExercise = false
    @State private var showRescue = false
    @State private var showSettings = false
    @State private var confirmDiscardPending = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if state.isOffline {
                        Label(
                            state.lastSync.map {
                                String(localized: "No connection to LibreLinkUp — last successful request at \($0.formatted(date: .omitted, time: .shortened))")
                            } ?? String(localized: "No connection to LibreLinkUp"),
                            systemImage: "wifi.slash"
                        )
                        .font(.footnote.bold())
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                    }
                    if !state.pendingOps.isEmpty {
                        Button {
                            confirmDiscardPending = true
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(state.pendingOps.count) record(s) waiting to sync")
                                        .font(.footnote.bold())
                                    Text("They sync on their own once online · tap to discard")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .foregroundStyle(.teal)
                            .padding(10)
                            .background(.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                    }
                    BasalReminderCard()
                    heroCard
                    HStack(spacing: 12) {
                        statCard(icon: "syringe", title: "Active insulin",
                                 value: String(format: "%.1f U", state.status?.iobUnits ?? 0),
                                 color: .blue)
                        statCard(icon: "fork.knife", title: "Active carbs",
                                 value: String(format: "%.0f g", state.status?.cobG ?? 0),
                                 color: .orange)
                    }
                    chartCard
                    quickActions
                    if let err = state.lastError {
                        Label(err, systemImage: "wifi.exclamationmark")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 12)
            }
            .background(Color.appBackground)
            .navigationTitle("DT1 Agent")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .refreshable { await state.refreshLive() }
            .confirmationDialog(
                "Discard \(state.pendingOps.count) record(s) waiting to sync? They will not be saved.",
                isPresented: $confirmDiscardPending, titleVisibility: .visible
            ) {
                Button("Discard", role: .destructive) { state.discardPendingOps() }
            }
            .sheet(isPresented: $showSettings) { SettingsView().presentationCornerRadius(28) }
            .sheet(isPresented: $showTreatment) { TreatmentView().presentationCornerRadius(28) }
            .sheet(isPresented: $showExercise) { ExerciseLogView().presentationCornerRadius(28) }
            .sheet(isPresented: $showRescue) { RescueView().presentationCornerRadius(28) }
        }
    }

    // MARK: hero

    private var heroCard: some View {
        let reading = state.status?.reading
        let color: Color = reading.map { glucoseColor($0.valueMgDl, range: state.targetRange) } ?? .gray

        return VStack(spacing: 6) {
            HStack {
                Text("NOW")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                if state.liveRefreshing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("updating…")
                            .font(.caption.bold())
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.thinMaterial, in: Capsule())
                } else {
                    // Computed from the reading itself so it stays honest offline.
                    Text(reading.map { String(localized: "\(max(0, Int(-$0.date.timeIntervalSinceNow / 60))) min ago") } ?? "—")
                        .font(.caption.bold().monospacedDigit())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.thinMaterial, in: Capsule())
                }
            }

            HStack(alignment: .center, spacing: 16) {
                Text(reading != nil ? "\(Int(reading!.valueMgDl))" : "—")
                    .font(.system(size: 84, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: reading?.valueMgDl)

                if let t = reading?.trend, let trend = Trend(rawValue: t) {
                    Image(systemName: trend.symbol)
                        .font(.system(size: 30, weight: .heavy))
                        .foregroundStyle(color)
                        .frame(width: 56, height: 56)
                        .background(color.opacity(0.15), in: Circle())
                } else {
                    // No reading yet (or tap target discoverability even
                    // once there is one) — an explicit "pull now" affordance,
                    // since the whole card is also tappable.
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.system(size: 30, weight: .heavy))
                        .foregroundStyle(color)
                        .frame(width: 56, height: 56)
                        .background(color.opacity(0.15), in: Circle())
                }
            }

            Group {
                if reading != nil {
                    Text("mg/dL · target \(Int(state.status?.targetMgDl ?? 110))")
                } else if state.isConfigured {
                    Text("Loading…")
                } else {
                    Text("Set up LibreLinkUp in Settings")
                }
            }
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(LinearGradient(
                    colors: [color.opacity(scheme == .dark ? 0.30 : 0.18),
                             color.opacity(scheme == .dark ? 0.10 : 0.05)],
                    startPoint: .top, endPoint: .bottom
                ))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(color.opacity(0.2), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        // Tap the value card -> pull a fresh reading from LibreLinkUp now.
        .onTapGesture {
            Task { await state.refreshLive() }
        }
    }

    // MARK: stat cards

    private func statCard(icon: String, title: LocalizedStringKey, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.caption.bold())
                .foregroundStyle(color)
            Text(value)
                .font(.title2.bold().monospacedDigit())
                .contentTransition(.numericText())
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.cardBackground)
        )
    }

    // MARK: chart

    private var chartCard: some View {
        let points = state.home12h
        let lastId = points.last?.id

        return VStack(alignment: .leading, spacing: 10) {
            Text("Last 12 h")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            Chart(points) { p in
                LineMark(x: .value("Time", p.date), y: .value("mg/dL", p.value))
                    .foregroundStyle(.teal)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    // Monotone: rounds corners without overshooting the
                    // measured values — the curve never invents data.
                    .interpolationMethod(.monotone)
                if p.id == lastId {
                    PointMark(x: .value("Time", p.date), y: .value("mg/dL", p.value))
                        .foregroundStyle(glucoseColor(p.value, range: state.targetRange))
                        .symbolSize(90)
                }
                RuleMark(y: .value("Low", state.targetRange.lowerBound))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                    .foregroundStyle(.red.opacity(0.35))
                RuleMark(y: .value("High", state.targetRange.upperBound))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                    .foregroundStyle(.orange.opacity(0.35))
            }
            .chartYScale(domain: 40...max(260, (points.map(\.value).max() ?? 260) + 20))
            .frame(height: 150)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.cardBackground)
        )
    }

    // MARK: actions

    private var quickActions: some View {
        VStack(spacing: 12) {
            // The one flow for everything: food + suggested dose + register.
            actionCard("Treatment", icon: "cross.case.fill", color: .teal, solid: true) {
                showTreatment = true
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                actionCard("Exercise", icon: "figure.run", color: .green) { showExercise = true }
                actionCard("Low", icon: "exclamationmark.triangle.fill", color: .red, solid: true) {
                    showRescue = true
                }
            }
        }
    }

    private func actionCard(
        _ title: LocalizedStringKey, icon: String, color: Color, solid: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 38, height: 38)
                    .background(
                        solid ? .white.opacity(0.25) : color.opacity(0.18),
                        in: Circle()
                    )
                Text(title)
                    .font(.headline)
                Spacer(minLength: 0)
            }
            .foregroundStyle(solid ? .white : color)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 62)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(solid
                          ? AnyShapeStyle(color)
                          : AnyShapeStyle(color.opacity(scheme == .dark ? 0.22 : 0.12)))
            )
        }
        .buttonStyle(.plain)
    }
}

/// Daily basal reminder: appears every day from 05:00 until confirmed.
/// Confirming logs the configured basal dose, plays a quick success
/// animation, and hides until tomorrow. Logging a basal via the Treatment
/// flow also counts as done.
struct BasalReminderCard: View {
    @Environment(AppState.self) private var state
    @AppStorage("basalUnits") private var basalUnits = 0.0 // 0 = reminder off
    @AppStorage("lastBasalDay") private var lastBasalDay = ""
    @State private var success = false
    @State private var saving = false

    private var todayKey: String { LocalDay.formatter.string(from: Date()) }

    private var pending: Bool {
        guard basalUnits > 0 else { return false }
        guard Calendar.current.component(.hour, from: Date()) >= 5 else { return false }
        guard lastBasalDay != todayKey else { return false }
        // A basal logged today through any flow also dismisses the reminder.
        let loggedToday = state.dosePoints.contains {
            $0.type == "basal" && Calendar.current.isDateInToday($0.date)
        }
        return !loggedToday
    }

    var body: some View {
        if pending || success {
            HStack(spacing: 12) {
                if success {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.green)
                        .transition(.scale.combined(with: .opacity))
                    Text("Basal logged — good morning!")
                        .font(.headline)
                    Spacer()
                } else {
                    Image(systemName: "syringe.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.indigo)
                        .frame(width: 40, height: 40)
                        .background(.indigo.opacity(0.18), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Morning basal")
                            .font(.headline)
                        Text("\(basalUnits, specifier: "%.0f") U — have you injected it?")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        Task { await confirm() }
                    } label: {
                        if saving {
                            ProgressView()
                        } else {
                            Image(systemName: "checkmark")
                                .font(.headline)
                                .frame(width: 44, height: 44)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.indigo)
                    .clipShape(Circle())
                    .disabled(saving)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(success ? Color.green.opacity(0.15) : Color.indigo.opacity(0.12))
            )
            .transition(.scale(scale: 0.9).combined(with: .opacity))
        }
    }

    private func confirm() async {
        saving = true
        try? await APIClient.logInsulin(units: basalUnits, type: "basal")
        await state.refresh()
        saving = false
        withAnimation(.snappy) { success = true }
        try? await Task.sleep(for: .seconds(1.2))
        withAnimation(.snappy) {
            lastBasalDay = todayKey
            success = false
        }
    }
}
