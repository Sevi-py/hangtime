import Foundation

/// Reads / writes the snapshot shared between the menu bar app and the widget extension.
public enum SharedStore {
    public static var appGroupID: String {
        (Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String) ?? "app.hangtime.shared"
    }

    public static var containerURL: URL {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            return url
        }
        // Fallback (unsigned debug builds): Application Support.
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hangtime", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    public static var stateURL: URL { containerURL.appendingPathComponent("state.json") }

    /// Group defaults let widgets read display preferences set in the app.
    public static var defaults: UserDefaults { UserDefaults(suiteName: appGroupID) ?? .standard }

    public static func load() -> SharedState? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(SharedState.self, from: data)
    }

    public static func save(_ state: SharedState) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }

    // Keys for group defaults shared with widgets.
    public enum Key {
        public static let showPaceMarker = "showPaceMarker"
        public static let colorByProvider = "colorByProvider"
        public static let historyMetric = "historyMetric"
        public static let heatmapPalette = "heatmapPalette"
        public static let zeroWhenBlocked = "zeroWhenBlocked"
    }
}
