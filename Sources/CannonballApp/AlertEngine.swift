import Foundation
import AVFoundation
import UserNotifications
import CannonballCore

/// Speaks and notifies recommendations. One utterance at a time; Critical
/// Alerts (entitlement-gated) for time-sensitive items. Docs §2.5/§2.6.
public final class AlertEngine: NSObject {
    private let synthesizer = AVSpeechSynthesizer()
    private var criticalAlertsGranted = false

    public override init() {
        super.init()
        #if os(iOS)
        // .duckOthers so guidance rides over music without pausing it; the
        // audio background mode keeps the app alive while mounted.
        try? AVAudioSession.sharedInstance().setCategory(
            .playback, mode: .voicePrompt, options: [.duckOthers])
        #endif
    }

    public func requestAuthorization() async {
        let center = UNUserNotificationCenter.current()
        // .criticalAlert silently no-ops without the entitlement; fall back is
        // time-sensitive interruption level below.
        let granted = try? await center.requestAuthorization(
            options: [.alert, .sound, .criticalAlert])
        criticalAlertsGranted = granted ?? false
    }

    public func handle(_ stream: AsyncStream<Recommendation>) {
        Task {
            for await rec in stream {
                speak(rec.message)
                await notify(rec)
            }
        }
    }

    private func speak(_ text: String) {
        synthesizer.stopSpeaking(at: .word)   // newest recommendation wins
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.52
        utterance.preUtteranceDelay = 0.1
        synthesizer.speak(utterance)
    }

    private func notify(_ rec: Recommendation) async {
        let content = UNMutableNotificationContent()
        content.title = rec.isCritical ? "ACT NOW" : "Co-pilot"
        content.body = rec.message
        if rec.isCritical && criticalAlertsGranted {
            content.sound = .defaultCritical
            content.interruptionLevel = .critical
        } else {
            content.sound = .default
            content.interruptionLevel = rec.isCritical ? .timeSensitive : .active
        }
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: rec.id, content: content, trigger: nil))
    }
}
