import Foundation
import UserNotifications
import CannonballCore

/// Delivers recommendations as notifications — Critical Alerts
/// (entitlement-gated) for time-sensitive items, time-sensitive interruption
/// otherwise. Docs §2.5/§2.6.
public final class AlertEngine: NSObject {
    private var criticalAlertsGranted = false

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
                await notify(rec)
            }
        }
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
