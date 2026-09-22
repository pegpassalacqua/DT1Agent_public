import AVFoundation
import Foundation
import SwiftUI

/// Phone-fired alarms without APNs (works with a free developer account).
///
/// A silent audio loop keeps the app alive in the background (the same
/// approach xDrip4iOS uses). Audio *playback* ignores the hardware mute
/// switch, so both alarm kinds are heard even on silent:
///   - Low: loud looping tone + full-screen takeover until acknowledged —
///     a 3 a.m. hypo alarm must actually wake you.
///   - High / forecast: one soft chime and a discreet banner — these are
///     meant to inform, not to stress.
/// The 60 s heartbeat also drives the actual LibreLinkUp fetch (every 5th
/// tick); BackgroundScheduler covers the case where iOS suspended the app.
@MainActor
final class AlarmManager: ObservableObject {
    @Published var activeAlert: AlertEvent?   // low only — full screen
    @Published var calmAlert: AlertEvent?     // high / forecast — banner

    private let engine = AVAudioEngine()
    private let silentPlayer = AVAudioPlayerNode()
    private let alarmPlayer = AVAudioPlayerNode()
    private let chimePlayer = AVAudioPlayerNode()
    private var pollLoopTask: Task<Void, Never>?
    private var tick = 0

    // "Already handled" is tracked by the alert's time, not its id: ids
    // used to come from the server and now from a local counter that
    // restarted at 1, so an id comparison against the old stored value
    // (up to ~2028) kept new alarms silent for days.
    private var lastSeenLowAt: Double {
        get { UserDefaults.standard.double(forKey: "lastSeenLowAlertAt") }
        set { UserDefaults.standard.set(newValue, forKey: "lastSeenLowAlertAt") }
    }
    private var lastSeenCalmAt: Double {
        get { UserDefaults.standard.double(forKey: "lastSeenCalmAlertAt") }
        set { UserDefaults.standard.set(newValue, forKey: "lastSeenCalmAlertAt") }
    }

    func start() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)

            let format = engine.outputNode.inputFormat(forBus: 0)
            for player in [silentPlayer, alarmPlayer, chimePlayer] {
                engine.attach(player)
                engine.connect(player, to: engine.mainMixerNode, format: format)
            }
            try engine.start()

            scheduleLoop(player: silentPlayer, buffer: makeBuffer(format: format, amplitude: 0))
            silentPlayer.play()
        } catch {
            print("AlarmManager audio setup failed: \(error)")
        }

        PollingService.shared.inAppSoundAvailable = { [weak self] in self?.engine.isRunning ?? false }
        PollingService.shared.onAlertFired = { [weak self] in
            Task { await self?.checkAlerts() }
        }

        pollLoopTask?.cancel()
        // Task.sleep, not Timer: a plain Timer runs in .default run loop
        // mode and STOPS firing while the user is touching/scrolling the
        // screen — silently starving the one thing that actually fetches
        // fresh LibreLinkUp data during exactly the moments the app is
        // being actively used. An async sleep loop keeps going regardless.
        pollLoopTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { break }
                await self?.poll()
            }
        }
        Task {
            // Failures are recorded by PollingService and shown in the UI.
            _ = try? await PollingService.shared.pollOnce() // immediate fetch on launch, like poller.js
            await poll()
        }
    }

    func poll() async {
        tick += 1
        if tick % 5 == 0 { // every ~5 min — LibreLinkUp itself only updates that often
            _ = try? await PollingService.shared.pollOnce()
        }
        await checkAlerts()
    }

    /// Newest-first scan of the last hour's fired alerts.
    func checkAlerts() async {
        guard let alerts = try? await APIClient.alerts(hours: 1) else { return }

        if let low = alerts.first(where: {
            $0.type == "low" && $0.fired == 1 && ISO.date($0.createdAt).timeIntervalSince1970 > lastSeenLowAt
        }), activeAlert?.id != low.id {
            activeAlert = low
            startAlarmSound()
        }

        if let calm = alerts.first(where: {
            $0.type != "low" && $0.fired == 1 && ISO.date($0.createdAt).timeIntervalSince1970 > lastSeenCalmAt
        }) {
            // Chime once, no acknowledgment needed — the banner stays until
            // dismissed; the next alert only comes after the 30 min refire.
            lastSeenCalmAt = ISO.date(calm.createdAt).timeIntervalSince1970
            calmAlert = calm
            playChime()
        }
    }

    /// User acknowledged the low: silence and never re-ring for this event.
    /// A new low alert (the 15 min refire) will ring again.
    func acknowledge() {
        if let alert = activeAlert {
            lastSeenLowAt = max(lastSeenLowAt, ISO.date(alert.createdAt).timeIntervalSince1970)
        }
        activeAlert = nil
        alarmPlayer.stop()
    }

    func dismissCalm() {
        calmAlert = nil
    }

    private func startAlarmSound() {
        guard engine.isRunning else { return }
        let format = engine.outputNode.inputFormat(forBus: 0)
        alarmPlayer.stop()
        scheduleLoop(player: alarmPlayer, buffer: makeBuffer(format: format, amplitude: 0.9))
        alarmPlayer.play()
    }

    private func playChime() {
        guard engine.isRunning else { return }
        let format = engine.outputNode.inputFormat(forBus: 0)
        chimePlayer.stop()
        chimePlayer.scheduleBuffer(makeChimeBuffer(format: format), at: nil, options: [], completionHandler: nil)
        chimePlayer.play()
    }

    /// One-second buffer: silence (amplitude 0) or an urgent two-tone beep.
    private func makeBuffer(format: AVAudioFormat, amplitude: Float) -> AVAudioPCMBuffer {
        let sampleRate = Float(format.sampleRate)
        let frames = AVAudioFrameCount(sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames

        for frame in 0..<Int(frames) {
            let t = Float(frame) / sampleRate
            var sample: Float = 0
            if amplitude > 0 {
                // 0.0–0.2 s at 880 Hz, 0.25–0.45 s at 660 Hz, then a pause.
                if t < 0.2 {
                    sample = sin(2 * .pi * 880 * t) * amplitude
                } else if t > 0.25 && t < 0.45 {
                    sample = sin(2 * .pi * 660 * t) * amplitude
                }
            }
            for channel in 0..<Int(format.channelCount) {
                buffer.floatChannelData?[channel][frame] = sample
            }
        }
        return buffer
    }

    /// Soft rising three-note chime (C5–E5–G5), bell-like: 20 ms fade-in so
    /// there is no click, then a gentle exponential decay. Played once.
    private func makeChimeBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer {
        let sampleRate = Float(format.sampleRate)
        let notes: [Float] = [523.25, 659.25, 783.99]
        let spacing: Float = 0.28
        let ring: Float = 1.0
        let frames = AVAudioFrameCount((spacing * Float(notes.count - 1) + ring) * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames

        for frame in 0..<Int(frames) {
            let t = Float(frame) / sampleRate
            var sample: Float = 0
            for (i, freq) in notes.enumerated() {
                let local = t - Float(i) * spacing
                guard local >= 0, local < ring else { continue }
                let fadeIn = min(1, local / 0.02)
                let decay = exp(-local * 4.5)
                sample += sin(2 * .pi * freq * local) * fadeIn * decay * 0.22
            }
            for channel in 0..<Int(format.channelCount) {
                buffer.floatChannelData?[channel][frame] = sample
            }
        }
        return buffer
    }

    private func scheduleLoop(player: AVAudioPlayerNode, buffer: AVAudioPCMBuffer) {
        player.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
    }
}
