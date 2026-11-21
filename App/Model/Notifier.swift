import Foundation
import UserNotifications

@MainActor
final class Notifier {
    static let shared = Notifier()
    private let center = UNUserNotificationCenter.current()
    private let d = UserDefaults.standard

    /// One-shot alerts: "provider|windowId" → the reset time (unix seconds) the user wants to hear about.
    /// Once that reset has happened the entry is removed, so it only fires for the *next* reset.
    private(set) var armed: [String: Double] {
        get { (d.dictionary(forKey: "armedResetAlertsV2") as? [String: Double]) ?? [:] }
        set { d.set(newValue, forKey: "armedResetAlertsV2") }
    }

    private var lowAlerted: Set<String> {
        get { Set(d.stringArray(forKey: "lowAlerted") ?? []) }
        set { d.set(Array(newValue), forKey: "lowAlerted") }
    }

    func requestAuthorization() async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    static func key(_ p: ProviderID, _ w: UsageWindow) -> String { "\(p.rawValue)|\(w.id)" }

    func isArmed(_ p: ProviderID, _ w: UsageWindow) -> Bool { armed[Self.key(p, w)] != nil }

    func toggleResetAlert(provider p: ProviderID, window w: UsageWindow) {
        let k = Self.key(p, w)
        if armed[k] != nil {
            armed.removeValue(forKey: k)
            center.removePendingNotificationRequests(withIdentifiers: ["reset.\(k)"])
        } else {
            armed[k] = w.resetsAt?.timeIntervalSince1970 ?? Date.now.addingTimeInterval(7 * 86400).timeIntervalSince1970
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
                // Global option: auto-arm (once) every limit that is used up.
                if s.notifyWhenAnyLimitResets, w.isExhausted, armedNow[k] == nil, let r = w.resetsAt {
                    armedNow[k] = r.timeIntervalSince1970
                }
                if let target = armedNow[k] {
                    if Date.now.timeIntervalSince1970 >= target + 30 {
                        // The reset we were waiting for has happened (the scheduled notification fired) → disarm.
                        armedNow.removeValue(forKey: k)
                    } else {
                        // Keep the notification in sync if the reset time moved (e.g. after a banked reset).
                        if let r = w.resetsAt, abs(r.timeIntervalSince1970 - target) > 60, r > .now {
                            armedNow[k] = r.timeIntervalSince1970
                        }
                        if !w.isExhausted && old[p]?.window(id: w.id)?.isExhausted == true {
                            // Freed up early (banked reset) – tell the user now and disarm.
                            center.removePendingNotificationRequests(withIdentifiers: ["reset.\(k)"])
                            post("reset.\(k).now", "\(p.shortName) limit available again", "Your \(w.title.lowercased()) limit was reset.")
                            armedNow.removeValue(forKey: k)
                        } else {
                            schedule(p, w)
                        }
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
                    content.body = "\(r.title) expires \(DateFmt.dateTime(exp)). Use it before it's gone."
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
