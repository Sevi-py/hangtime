import Foundation

/// Cross-process pings between widgets/controls and the app (works across the sandbox).
public enum DarwinNotify {
    public static let refresh = "app.hangtime.refresh"

    public static func post(_ name: String) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(name as CFString), nil, nil, true)
    }

    public static func observe(_ name: String, _ handler: @escaping @Sendable () -> Void) {
        Box.handlers[name] = handler
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, cfName, _, _ in
            guard let n = cfName?.rawValue as String? else { return }
            Box.handlers[n]?()
        }, name as CFString, nil, .deliverImmediately)
    }

    private enum Box {
        nonisolated(unsafe) static var handlers: [String: @Sendable () -> Void] = [:]
    }
}
