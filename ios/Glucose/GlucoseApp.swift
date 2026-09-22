import SwiftUI

@main
struct GlucoseApp: App {
    @State private var state = AppState()
    @StateObject private var alarms = AlarmManager()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Must happen before the app finishes launching, per BGTaskScheduler docs.
        BackgroundScheduler.register()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .tint(.teal) // one accent everywhere — tabs, sheets, buttons, links
                .environment(state)
                .environmentObject(alarms)
                .onAppear {
                    state.startAutoRefresh()
                    alarms.start() // background keep-alive + alarm polling
                    PollingService.shared.requestNotificationPermission()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task { await state.refresh() }
                    } else if phase == .background {
                        BackgroundScheduler.scheduleNext()
                    }
                }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var alarms: AlarmManager

    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Home", systemImage: "house") }
            HistoryView()
                .tabItem { Label("History", systemImage: "chart.xyaxis.line") }
            StreakCalendarView()
                .tabItem { Label("Progress", systemImage: "flame") }
        }
        // High / forecast: a discreet banner, dismissed with a tap.
        .overlay(alignment: .top) {
            if let alert = alarms.calmAlert {
                CalmAlertBanner(alert: alert) { alarms.dismissCalm() }
                    .padding(.horizontal)
            }
        }
        // A low takes over the whole screen until acknowledged.
        .fullScreenCover(
            isPresented: Binding(
                get: { alarms.activeAlert != nil },
                set: { if !$0 { alarms.acknowledge() } }
            )
        ) {
            AlarmView()
        }
    }
}

/// High and forecast alarms: informative, not alarming.
struct CalmAlertBanner: View {
    let alert: AlertEvent
    let dismiss: () -> Void

    private var isForecast: Bool { alert.type == "forecast" }
    private var predictsLow: Bool { alert.reason == "forecast_low" }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isForecast ? "chart.line.uptrend.xyaxis" : "arrow.up.circle")
                .font(.title3)
                .foregroundStyle(predictsLow ? Color.red : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Group {
                    if !isForecast {
                        Text("High glucose")
                    } else if predictsLow {
                        Text("Forecast below target")
                    } else {
                        Text("Forecast above target")
                    }
                }
                    .font(.subheadline.bold())
                Group {
                    if isForecast {
                        Text("Forecast \(Int(alert.valueMgDl)) mg/dL")
                    } else {
                        Text("\(Int(alert.valueMgDl)) mg/dL · last injection over 2 h ago")
                    }
                }
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption.bold())
                    .padding(8)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Full-screen takeover while the low alarm is sounding.
struct AlarmView: View {
    @EnvironmentObject var alarms: AlarmManager

    var body: some View {
        if let alert = alarms.activeAlert {
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: alert.type == "low"
                      ? "arrow.down.heart.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 64))
                Text(alert.type == "low" ? "LOW GLUCOSE" : "HIGH GLUCOSE")
                    .font(.largeTitle.bold())
                Text(verbatim: "\(Int(alert.valueMgDl)) mg/dL")
                    .font(.system(size: 72, weight: .heavy, design: .rounded))
                Spacer()
                Button {
                    alarms.acknowledge()
                } label: {
                    Text("Stop alarm")
                        .font(.title2.bold())
                        .frame(maxWidth: .infinity)
                        .padding()
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(alert.type == "low" ? Color.red : Color.orange)
                .padding()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(.white)
            .background(alert.type == "low" ? Color.red : Color.orange)
        }
    }
}
