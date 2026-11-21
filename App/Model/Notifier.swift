import Foundation
import UserNotifications

@MainActor
final class Notifier {
    static let shared = Notifier()
    private let center = UNUserNotificationCenter.current()
    private let d = UserDefaults.standard

    /// "provider|windowId" keys the user asked to be notified about.
    private(set) var armed: Set<String> {
        get { Set(d.stringArray(forKey: "armedResetAlerts") ?? []) }
        set { d.set(Array(newValue), forKey: "armedResetAlerts") }
    }

    private var lowAlerted: Set<String> {
        get { Set(d.stringArray(forKey: "lowAlerted") ?? []) }
        set { d.set(Array(newValue), forKey: "lowAlerted") }
    }

    func requestAuthorization() async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    static func key(_ p: ProviderID, _ w: UsageWindow) -> String { "\(p.rawValue)|\(w.id)" }

    func isArmed(_ p: ProviderID, _ w: UsageWindow) -> Bool { armed.contains(Self.key(p, w)) }

    func toggleResetAlert(provider p: ProviderID, window w: UsageWindow) {
        let k = Self.key(p, w)
        if armed.contains(k) {
            armed.remove(k)
            center.removePendingNotificationRequests(withIdentifiers: ["reset.\(k)"])
        } else {
            armed.insert(k)
            Task {
                await requestAuthorization()
                schedule(p, w)
            }
        }
    }

    private func schedule(_ p: ProviderID, _ w: UsageWindow) {
        guard let at = w.resetsAt, at > .now else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(p.shortName) limit reset"
        content.body = "Your \(w.title.lowercased()) limit is available again."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, at.timeIntervalSinceNow + 5), repeats: false)
        center.add(UNNotificationRequest(identifier: "reset.\(Self.key(p, w))", content: content, trigger: trigger))
    }

    private func post(_ id: String, _ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    /// Called after each refresh to (re)schedule and fire notifications.
    func evaluate(old: [ProviderID: ProviderSnapshot], new: [ProviderID: ProviderSnapshot], providers: [ProviderID]) {
        let s = AppSettings.shared
        var armedNow = armed
        var low = lowAlerted

        for p in providers {
            guard let snap = new[p] else { continue }

            if s.notifyLoggedOut, snap.status == .loggedOut, old[p]?.status != .loggedOut, old[p] != nil {
                post("loggedout.\(p.rawValue)", "\(p.displayName) is signed out",
                     "Open Headroom to sign in again.")
            }

            for w in snap.windows {
                let k = Self.key(p, w)
                // Auto-arm exhausted limits if the user wants that globally.
                if s.notifyWhenAnyLimitResets, w.isExhausted { armedNow.insert(k) }
                if armedNow.contains(k) {
                    if w.isExhausted || (w.resetsAt ?? .distantPast) > .now {
                        schedule(p, w)
                    }
                    // The window reset (no longer used up and previous reset time passed) → disarm.
                    if let prev = old[p]?.window(id: w.id), let prevReset = prev.resetsAt,
                       prevReset <= .now, !w.isExhausted {
                        armedNow.remove(k)
                    }
                }
                // Low remaining alerts (once per window cycle).
                let lk = "\(k)|\(Int(w.resetsAt?.timeIntervalSince1970 ?? 0))"
                if s.lowThresholdAlerts, w.remainingFraction <= s.lowThreshold, !w.isExhausted, !low.contains(lk) {
                    low.insert(lk)
                    post("low.\(lk)", "\(p.shortName): \(Fmt.percent(w.remainingFraction)) left",
                         "\(w.title) – \(Fmt.resets(w.resetsAt).lowercased()).")
                }
            }

            // Banked reset expiry reminders, 24h before.
            if s.notifyResetExpiry {
                for r in snap.bankedResets {
                    guard let exp = r.expiresAt, exp.timeIntervalSinceNow > 24 * 3600 else { continue }
                    let content = UNMutableNotificationContent()
                    content.title = "\(p.shortName) banked reset expires tomorrow"
                    content.body = "\(r.title) expires \(exp.formatted(date: .abbreviated, time: .shortened)). Use it before it's gone."
                    let trigger = UNTimeIntervalNotificationTrigger(timeInterval: exp.timeIntervalSinceNow - 24 * 3600, repeats: false)
                    center.add(UNNotificationRequest(identifier: "expiry.\(p.rawValue).\(r.id)", content: content, trigger: trigger))
                }
            }
        }
        armed = armedNow
        // Keep the low-alert memory bounded.
        if low.count > 200 { low = Set(low.suffix(100)) }
        lowAlerted = low
        if s.notifyWhenAnyLimitResets || s.lowThresholdAlerts || s.notifyResetExpiry || !armedNow.isEmpty {
            Task { await requestAuthorization() }
        }
    }
}
