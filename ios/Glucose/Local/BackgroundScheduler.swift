import Foundation
import BackgroundTasks

/// Opportunistic background polling. iOS does not allow a third-party app
/// to run a real 5-minute timer while backgrounded/closed — BGAppRefresh
/// is "whenever iOS feels like it", typically minutes to a few hours
/// depending on usage patterns. That's acceptable here specifically
/// because LibreLinkUp's /graph endpoint always returns the last ~12h:
/// as long as SOME background wake happens inside any 12h window, the
/// on-device history has no gap. Only a device that goes untouched (app
/// never opened, never backgrounded) for longer than that can lose data —
/// same ceiling every non-Apple-Watch LibreLinkUp companion app has
/// without running its own always-on server.
enum BackgroundScheduler {
    /// Must match BGTaskSchedulerPermittedIdentifiers in project.yml.
    static let refreshTaskId = (Bundle.main.bundleIdentifier ?? "dt1agent") + ".refresh"

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskId, using: nil) { task in
            handle(task as! BGAppRefreshTask)
        }
    }

    static func scheduleNext() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60) // iOS floor is ~15 min
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handle(_ task: BGAppRefreshTask) {
        scheduleNext() // always queue the next one, win or lose

        let work = Task { @MainActor in
            do {
                try await PollingService.shared.pollOnce()
                task.setTaskCompleted(success: true)
            } catch {
                task.setTaskCompleted(success: false)
            }
        }
        task.expirationHandler = { work.cancel() }
    }
}
