import Foundation
import AppKit

/// Runs when Hangtime is opened from outside an Applications folder (the DMG, Downloads, an App Translocation
/// mount after unzipping): it installs itself the way the existing copy was installed, so there is only ever
/// one Hangtime.
///
/// - Installed from a GitHub download: replaces it (if this copy is newer) and switches to it, no questions.
/// - Installed with Homebrew: warns first, because replacing it behind brew's back leaves brew out of sync.
/// - Not installed: offers to move itself to Applications.
///
/// Settings live in UserDefaults for the bundle ID, so they and the setup-assistant state carry over.
@MainActor
enum SelfInstaller {
    /// Decided once at launch, before any scene shows (the menu bar item stays hidden while this runs).
    static let shouldRun: Bool = {
        #if DEBUG
        return false
        #else
        if CommandLine.arguments.dropFirst().contains(where: { $0.hasPrefix("--") }) { return false }
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        if applicationsDirs.contains(where: { path.hasPrefix($0.path + "/") }) { return false }
        // Builds run from Xcode or scripts/install.sh's build folder are not downloads.
        if path.contains("/Build/Products/") || path.contains("/DerivedData/") || path.contains("/Intermediates.noindex/") {
            return false
        }
        if UserDefaults.standard.string(forKey: declinedKey) == originalURL.path { return false }
        return true
        #endif
    }()

    private static let declinedKey = "install.declinedPath"
    private static let pendingTrashKey = "install.pendingTrash"

    private static var applicationsDirs: [URL] {
        [URL(fileURLWithPath: "/Applications"),
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
    }

    /// Returns true when this launch handed over to the installed copy (the caller must not start the app).
    static func run() -> Bool {
        guard shouldRun else { return false }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()

        let mine = Updater.currentVersion
        if let installed = installedCopy() {
            let theirs = version(of: installed) ?? "0"
            if case .homebrew(let brew) = Updater.installMethod {
                return homebrewInstalled(at: installed, version: theirs, brew: brew)
            }
            guard Updater.isNewer(mine, than: theirs) else {
                // Same or older than what's installed: just use (or bring forward) the installed copy.
                return Updater.handOff(open: installed, afterOpen: cleanupCommands())
            }
            return replace(installed, announce: mine)
        }
        return offerMoveToApplications()
    }

    /// Called at every normal launch: removes the downloaded copy we installed from (now a duplicate).
    static func finishPendingCleanup() {
        let d = UserDefaults.standard
        guard let path = d.string(forKey: pendingTrashKey) else { return }
        d.removeObject(forKey: pendingTrashKey)
        let url = URL(fileURLWithPath: path)
        guard url.path != Bundle.main.bundleURL.path, FileManager.default.fileExists(atPath: path) else { return }
        unregister(url)
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    // MARK: Cases

    private static func homebrewInstalled(at installed: URL, version theirs: String, brew: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Hangtime is installed with Homebrew"
        alert.informativeText = """
        Hangtime \(theirs) in \(installed.deletingLastPathComponent().path) is managed by Homebrew. \
        Replacing it with this download (\(Updater.currentVersion)) would leave Homebrew out of sync.

        Update it with Homebrew instead (brew upgrade --cask \(Updater.caskToken)). Your settings are kept either way.
        """
        alert.addButton(withTitle: "Update with Homebrew")
        alert.addButton(withTitle: "Replace Anyway")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            quitRunningCopies(of: installed)
            let upgrade = """
            "\(brew)" update --quiet >/dev/null 2>&1
            "\(brew)" upgrade --cask \(Updater.caskToken) >/dev/null 2>&1
            """
            return Updater.handOff(open: installed, whileStopped: upgrade, afterOpen: cleanupCommands())
        case .alertSecondButtonReturn:
            return replace(installed, announce: Updater.currentVersion)
        default:
            NSApp.terminate(nil)
            return true
        }
    }

    private static func offerMoveToApplications() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Move Hangtime to Applications?"
        alert.informativeText = "Hangtime runs from your Applications folder, so it can start at login and keep itself up to date."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else {
            UserDefaults.standard.set(originalURL.path, forKey: declinedKey)
            NSApp.setActivationPolicy(.accessory)
            LaunchState.shared.menuBarVisible = true
            return false
        }
        let dir = applicationsDirs.first { FileManager.default.isWritableFile(atPath: $0.path) }
            ?? applicationsDirs[1]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return replace(dir.appendingPathComponent("Hangtime.app"), announce: nil)
    }

    /// Copies this bundle over `target` (atomically, via a staged copy next to it) and switches to it.
    private static func replace(_ target: URL, announce version: String?) -> Bool {
        let fm = FileManager.default
        let staged = target.deletingLastPathComponent()
            .appendingPathComponent(".Hangtime-\(UUID().uuidString).app")
        do {
            guard fm.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
                throw UpdateError("You don't have permission to change \(target.deletingLastPathComponent().path).")
            }
            try fm.copyItem(at: Bundle.main.bundleURL, to: staged)
            // Already checked by Gatekeeper when this copy was opened; don't ask the user a second time.
            _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/xattr"), arguments: ["-dr", "com.apple.quarantine", staged.path])
            quitRunningCopies(of: target)
            if fm.fileExists(atPath: target.path) {
                _ = try fm.replaceItemAt(target, withItemAt: staged)
            } else {
                try fm.moveItem(at: staged, to: target)
            }
        } catch {
            try? fm.removeItem(at: staged)
            let alert = NSAlert(error: error)
            alert.messageText = "Hangtime couldn't be installed"
            alert.runModal()
            NSApp.terminate(nil)
            return true
        }
        return Updater.handOff(open: target, afterOpen: cleanupCommands(), justInstalled: version)
    }

    // MARK: Helpers

    private static func installedCopy() -> URL? {
        let fm = FileManager.default
        let candidates = applicationsDirs.map { $0.appendingPathComponent("Hangtime.app") }
            + NSWorkspace.shared.urlsForApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        return candidates.first { url in
            let path = url.resolvingSymlinksInPath().path
            return fm.fileExists(atPath: url.appendingPathComponent("Contents/Info.plist").path)
                && path != Bundle.main.bundleURL.resolvingSymlinksInPath().path
                && applicationsDirs.contains { path.hasPrefix($0.path + "/") }
        }
    }

    private static func version(of app: URL) -> String? {
        NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
    }

    /// Quits other running instances (the installed copy) before replacing them; force-quits after 5 s.
    private static func quitRunningCopies(of app: URL) {
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != me }
        others.forEach { $0.terminate() }
        let deadline = Date.now.addingTimeInterval(5)
        while others.contains(where: { !$0.isTerminated }) && Date.now < deadline {
            RunLoop.current.run(until: Date.now.addingTimeInterval(0.1))
        }
        others.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
    }

    /// Shell run after the installed copy opened: forget this copy, eject the disk image it came from,
    /// and leave a note for the installed copy to move a downloaded duplicate to the Trash.
    private static func cleanupCommands() -> String {
        let source = originalURL
        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        var cmds = ["\"\(lsregister)\" -u \(shellQuote(Bundle.main.bundleURL.path)) >/dev/null 2>&1"]
        if source.path.hasPrefix("/Volumes/") {
            let volume = source.pathComponents.prefix(3).joined(separator: "/").replacingOccurrences(of: "//", with: "/")
            cmds.append("hdiutil detach \(shellQuote(volume)) -quiet >/dev/null 2>&1")
        } else if FileManager.default.isWritableFile(atPath: source.deletingLastPathComponent().path) {
            UserDefaults.standard.set(source.path, forKey: pendingTrashKey)
        }
        return cmds.joined(separator: "\n")
    }

    private static func unregister(_ app: URL) {
        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        _ = try? Process.run(URL(fileURLWithPath: lsregister), arguments: ["-u", app.path])
    }

    private static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Where the user actually put this copy. Opened from a quarantined download, macOS runs it from a
    /// randomized read-only App Translocation path; this maps that back to the original location.
    static let originalURL: URL = {
        let url = Bundle.main.bundleURL
        typealias IsTranslocated = @convention(c) (CFURL, UnsafeMutablePointer<Bool>, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Bool
        typealias OriginalPath = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let isSym = dlsym(handle, "SecTranslocateIsTranslocatedURL"),
              let origSym = dlsym(handle, "SecTranslocateCreateOriginalPathForURL") else { return url }
        var translocated = false
        guard unsafeBitCast(isSym, to: IsTranslocated.self)(url as CFURL, &translocated, nil), translocated,
              let original = unsafeBitCast(origSym, to: OriginalPath.self)(url as CFURL, nil)?.takeRetainedValue()
        else { return url }
        return original as URL
    }()
}

/// Whether the menu bar item is shown. Hidden for headless runs (--render, --dump, --reset-setup) and while a
/// downloaded copy is installing itself, so they never add a second Hangtime to the menu bar.
@MainActor
@Observable
final class LaunchState {
    static let shared = LaunchState()
    var menuBarVisible: Bool

    static let isHeadless = CommandLine.arguments.contains { ["--render", "--dump", "--reset-setup"].contains($0) }

    private init() {
        menuBarVisible = !(Self.isHeadless || SelfInstaller.shouldRun)
    }
}
