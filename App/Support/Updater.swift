import Foundation
import AppKit
import WidgetKit

/// Checks GitHub Releases for a newer Hangtime and installs it the same way the running copy was installed:
/// through `brew upgrade` for Homebrew installs, otherwise by downloading the notarized zip, verifying its
/// signature and replacing the app bundle in place. Settings live in UserDefaults keyed by the bundle ID, so
/// they (and the "setup done" flag) survive either path. After installing, the widget extension and
/// `chronod` are restarted so placed widgets load the new build.
@MainActor
@Observable
final class Updater {
    static let shared = Updater()

    static let repo = "Sevi-py/hangtime"
    static let caskToken = "hangtime"
    /// Updates must be signed with this team's Developer ID (same team as release builds).
    static let teamID = "8XX544GLPH"

    enum Method: Equatable { case homebrew(brew: String), direct }

    enum Phase: Equatable {
        case idle, checking, upToDate, available, installing(String), failed(String)
    }

    struct Release: Equatable {
        var version: String
        var notes: String
        var page: URL
        var zip: URL?
    }

    private enum Key {
        static let autoCheck = "updates.autoCheck"
        static let autoInstall = "updates.autoInstall"
        static let lastCheck = "updates.lastCheck"
        static let lastRunBuild = "updates.lastRunBuild"
        static let feedOverride = "updates.feedURL"   // testing only: `defaults write app.hangtime.mac updates.feedURL <url>`
    }

    var autoCheck: Bool { didSet { d.set(autoCheck, forKey: Key.autoCheck); schedule() } }
    var autoInstall: Bool { didSet { d.set(autoInstall, forKey: Key.autoInstall) } }
    var phase: Phase = .idle
    var latest: Release?
    var lastCheck: Date? { d.object(forKey: Key.lastCheck) as? Date }

    private let d = UserDefaults.standard
    private var timer: Timer?

    private init() {
        autoCheck = d.object(forKey: Key.autoCheck) as? Bool ?? true
        autoInstall = d.object(forKey: Key.autoInstall) as? Bool ?? true
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
    static var currentBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    var updateAvailable: Bool { latest.map { Self.isNewer($0.version, than: Self.currentVersion) } ?? false }

    // MARK: Lifecycle

    func start() {
        reloadWidgetsIfBuildChanged()
        schedule()
        if autoCheck {
            // Give the first refresh a head start.
            Task {
                try? await Task.sleep(for: .seconds(20))
                await check(userInitiated: false)
            }
        }
    }

    private func schedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in
                let u = Updater.shared
                u.relaunchIfReplacedOnDisk()
                if u.autoCheck, Date.now.timeIntervalSince(u.lastCheck ?? .distantPast) > 6 * 3600 {
                    await u.check(userInitiated: false)
                }
            }
        }
        timer?.tolerance = 300
    }

    /// The first launch of a new build (any install path, including `brew upgrade` run by hand and
    /// `scripts/install.sh`) reloads all widget timelines, so widgets never show stale layouts.
    private func reloadWidgetsIfBuildChanged() {
        let build = "\(Self.currentVersion) (\(Self.currentBuild))"
        if d.string(forKey: Key.lastRunBuild) != build {
            d.set(build, forKey: Key.lastRunBuild)
            WidgetCenter.shared.reloadAllTimelines()
            ControlCenter.shared.reloadAllControls()
        }
    }

    /// When something else replaced the bundle (e.g. the user ran `brew upgrade`), restart into it.
    private func relaunchIfReplacedOnDisk() {
        if case .installing = phase { return }
        let plist = Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: plist),
              let build = info["CFBundleVersion"] as? String,
              build != Self.currentBuild else { return }
        relaunch(after: nil)
    }

    // MARK: Install method

    static var installMethod: Method {
        let caskrooms = ["/opt/homebrew/Caskroom/\(caskToken)", "/usr/local/Caskroom/\(caskToken)"]
        for room in caskrooms where FileManager.default.fileExists(atPath: room) {
            let brew = URL(fileURLWithPath: room).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("bin/brew").path
            if FileManager.default.isExecutableFile(atPath: brew) { return .homebrew(brew: brew) }
        }
        return .direct
    }

    var methodDescription: String {
        if case .homebrew = Self.installMethod { "Homebrew" } else { "Direct download" }
    }

    // MARK: Check

    func check(userInitiated: Bool) async {
        if case .installing = phase { return }
        phase = .checking
        do {
            let release = try await fetchLatest()
            d.set(Date.now, forKey: Key.lastCheck)
            latest = release
            if Self.isNewer(release.version, than: Self.currentVersion) {
                phase = .available
                if autoInstall && !userInitiated { await install() }
            } else {
                phase = .upToDate
            }
        } catch {
            phase = userInitiated ? .failed(error.localizedDescription) : .idle
        }
    }

    private func fetchLatest() async throws -> Release {
        let feed = d.string(forKey: Key.feedOverride).flatMap(URL.init(string:))
            ?? URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!
        var req = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Hangtime/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError("GitHub answered \(http.statusCode)")
        }
        struct Payload: Decodable {
            struct Asset: Decodable { var name: String; var browser_download_url: URL }
            var tag_name: String
            var body: String?
            var html_url: URL
            var assets: [Asset]
            var draft: Bool?
            var prerelease: Bool?
        }
        let p = try JSONDecoder().decode(Payload.self, from: data)
        let version = p.tag_name.hasPrefix("v") ? String(p.tag_name.dropFirst()) : p.tag_name
        let zip = p.assets.first { $0.name.hasPrefix("Hangtime") && $0.name.hasSuffix(".zip") }?.browser_download_url
        return Release(version: version, notes: p.body ?? "", page: p.html_url, zip: zip)
    }

    /// Compares dotted version strings numerically ("1.10" > "1.9").
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    // MARK: Install

    func install() async {
        guard let release = latest, updateAvailable else { return }
        if case .installing = phase { return }
        do {
            switch Self.installMethod {
            case .homebrew(let brew):
                phase = .installing("Updating with Homebrew…")
                try await upgradeWithHomebrew(brew: brew)
            case .direct:
                guard let zip = release.zip else { throw UpdateError("The release has no download") }
                phase = .installing("Downloading \(release.version)…")
                let app = try await downloadAndVerify(zip, expectedVersion: release.version)
                phase = .installing("Installing…")
                try replaceBundle(with: app)
            }
            phase = .installing("Restarting…")
            relaunch(after: release.version)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func upgradeWithHomebrew(brew: String) async throws {
        // `brew update` first so the tap knows about the new cask version; ignore its failures (offline taps).
        _ = try? await run(brew, ["update", "--quiet"])
        let out = try await run(brew, ["upgrade", "--cask", Self.caskToken])
        guard out.status == 0 else {
            let last = out.output.split(separator: "\n").last.map(String.init) ?? "exit \(out.status)"
            throw UpdateError("brew upgrade failed: \(last)")
        }
    }

    private func downloadAndVerify(_ url: URL, expectedVersion: String) async throws -> URL {
        let (file, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError("Download failed (\(http.statusCode))")
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("HangtimeUpdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let zip = work.appendingPathComponent("Hangtime.zip")
        try FileManager.default.moveItem(at: file, to: zip)
        let unzip = try await run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
        guard unzip.status == 0 else { throw UpdateError("Could not unpack the update") }
        let app = work.appendingPathComponent("Hangtime.app")

        // Must be signed by our team with a valid Developer ID signature, and notarized.
        let requirement = "anchor apple generic and certificate leaf[subject.OU] = \"\(Self.teamID)\""
        let sig = try await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R=\(requirement)", app.path])
        guard sig.status == 0 else { throw UpdateError("The update's signature is not valid") }
        let gk = try await run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path])
        guard gk.status == 0 else { throw UpdateError("The update is not notarized") }

        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              info?["CFBundleShortVersionString"] as? String == expectedVersion else {
            throw UpdateError("The download is not the expected version")
        }
        return app
    }

    /// Swaps the running bundle for the new one. The old bundle goes to a temp location first so a failed
    /// copy can be rolled back; the running process keeps working from the open files until it relaunches.
    private func replaceBundle(with newApp: URL) throws {
        let fm = FileManager.default
        let target = Bundle.main.bundleURL
        guard fm.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            throw UpdateError("No permission to replace \(target.path). Download the update from GitHub instead.")
        }
        let backup = fm.temporaryDirectory.appendingPathComponent("Hangtime-old-\(UUID().uuidString).app")
        try fm.moveItem(at: target, to: backup)
        do {
            try fm.moveItem(at: newApp, to: target)
        } catch {
            try? fm.moveItem(at: backup, to: target)
            throw error
        }
        try? fm.removeItem(at: backup)
    }

    /// Quits, re-registers the widget extension, restarts the widget host and opens the (new) app.
    /// Runs from a detached shell so it outlives this process.
    func relaunch(after version: String?) {
        let app = Bundle.main.bundleURL.path
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        pkill -f 'HangtimeWidgets.appex' 2>/dev/null
        /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$1" >/dev/null 2>&1
        pluginkit -a "$1/Contents/PlugIns/HangtimeWidgets.appex" 2>/dev/null
        killall chronod 2>/dev/null
        sleep 0.5
        open "$1"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "hangtime-relaunch", app]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            phase = .failed("Could not restart: \(error.localizedDescription)")
            return
        }
        if let version { d.set(version, forKey: "updates.justInstalled") }
        NSApp.terminate(nil)
    }

    /// Set by `relaunch(after:)`; read once on the next launch to tell the user what happened.
    func consumeJustInstalled() -> String? {
        defer { d.removeObject(forKey: "updates.justInstalled") }
        return d.string(forKey: "updates.justInstalled")
    }

    // MARK: Process helper

    private func run(_ exe: String, _ args: [String]) async throws -> (status: Int32, output: String) {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            var env = ProcessInfo.processInfo.environment
            env["HOMEBREW_NO_ENV_HINTS"] = "1"
            env["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"
            env["NONINTERACTIVE"] = "1"
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            p.standardInput = FileHandle.nullDevice
            // Drain continuously so a chatty child (brew) never blocks on a full pipe.
            let buffer = OutputBuffer()
            pipe.fileHandleForReading.readabilityHandler = { h in buffer.append(h.availableData) }
            p.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                buffer.append(pipe.fileHandleForReading.readDataToEndOfFile())
                cont.resume(returning: (proc.terminationStatus, buffer.string))
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }
}

struct UpdateError: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private final class OutputBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    var string: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}
