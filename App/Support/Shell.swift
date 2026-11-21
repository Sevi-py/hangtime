import Foundation

struct ProcessResult: Sendable {
    var status: Int32
    var stdout: String
    var stderr: String
    var timedOut: Bool
    var ok: Bool { status == 0 && !timedOut }
}

enum ShellError: LocalizedError {
    case notFound(String)
    case failed(String)
    var errorDescription: String? {
        switch self {
        case .notFound(let c): "Command not found: \(c)"
        case .failed(let m): m
        }
    }
}

/// Environment & command resolution. GUI apps don't inherit the user's shell PATH, so we
/// ask the login shell once and merge it with the usual install locations of the CLIs.
actor Shell {
    static let shared = Shell()

    private var cachedPath: String?

    private static let home = FileManager.default.homeDirectoryForCurrentUser.path

    static let extraDirs: [String] = [
        "\(home)/.local/bin", "\(home)/.gemini/antigravity-cli/bin", "\(home)/.claude/local", "\(home)/.grok/bin", "\(home)/.codex/bin",
        "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin", "\(home)/Library/pnpm",
        "\(home)/.bun/bin", "\(home)/.volta/bin", "\(home)/.cargo/bin", "\(home)/.deno/bin",
        "\(home)/.yarn/bin", "\(home)/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ]

    func path() async -> String {
        if let cachedPath { return cachedPath }
        var dirs: [String] = []
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        // -l -i so that .zshrc additions (nvm, pnpm, …) are included. Markers isolate noisy rc output.
        if let r = try? await Self.run(shell, ["-l", "-i", "-c", "echo __HR_PATH__${PATH}__HR_END__"],
                                       env: ["TERM": "dumb"], timeout: 8),
           let s = r.stdout.range(of: "__HR_PATH__"), let e = r.stdout.range(of: "__HR_END__") {
            dirs = r.stdout[s.upperBound..<e.lowerBound].split(separator: ":").map(String.init)
        }
        // nvm installs: add every node version's bin.
        let nvm = "\(Self.home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            dirs += versions.sorted(by: >).map { "\(nvm)/\($0)/bin" }
        }
        var seen = Set<String>()
        let merged = (dirs + Self.extraDirs).filter { seen.insert($0).inserted }.joined(separator: ":")
        cachedPath = merged
        return merged
    }

    func invalidate() { cachedPath = nil }

    func environment() async -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = await path()
        env["NO_COLOR"] = "1"
        env["TERM"] = env["TERM"] ?? "xterm-256color"
        return env
    }

    /// Splits a user supplied command like `claude`, `/usr/local/bin/codex`, or `npx -y @openai/codex`
    /// into executable + leading arguments, resolving the executable on PATH.
    func resolve(_ command: String) async -> (exe: String, args: [String])? {
        let parts = Self.split(command)
        guard let first = parts.first else { return nil }
        let rest = Array(parts.dropFirst())
        let expanded = (first as NSString).expandingTildeInPath
        if expanded.contains("/") {
            return FileManager.default.isExecutableFile(atPath: expanded) ? (expanded, rest) : nil
        }
        for dir in await path().split(separator: ":") {
            let candidate = "\(dir)/\(expanded)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return (candidate, rest) }
        }
        return nil
    }

    /// Runs a CLI command (user-configurable) with extra arguments.
    func runCLI(_ command: String, _ args: [String], timeout: TimeInterval = 20,
                stdin: String? = nil, keepStdinOpen: Bool = false) async throws -> ProcessResult {
        guard let (exe, pre) = await resolve(command) else { throw ShellError.notFound(command) }
        return try await Self.run(exe, pre + args, env: await environment(), timeout: timeout, stdin: stdin,
                                  keepStdinOpen: keepStdinOpen)
    }

    static func split(_ command: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var quote: Character?
        for ch in command {
            if let q = quote {
                if ch == q { quote = nil } else { cur.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == " " || ch == "\t" {
                if !cur.isEmpty { out.append(cur); cur = "" }
            } else {
                cur.append(ch)
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    static func run(_ exe: String, _ args: [String], env: [String: String]? = nil,
                    timeout: TimeInterval = 20, stdin: String? = nil,
                    keepStdinOpen: Bool = false) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            if let env { p.environment = env }
            p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            let out = Pipe(), err = Pipe(), inp = Pipe()
            p.standardOutput = out
            p.standardError = err
            p.standardInput = inp

            let outBuf = LockedData(), errBuf = LockedData()
            out.fileHandleForReading.readabilityHandler = { h in outBuf.append(h.availableData) }
            err.fileHandleForReading.readabilityHandler = { h in errBuf.append(h.availableData) }

            let timedOut = LockedFlag()
            p.terminationHandler = { proc in
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                outBuf.append(out.fileHandleForReading.readDataToEndOfFile())
                errBuf.append(err.fileHandleForReading.readDataToEndOfFile())
                cont.resume(returning: ProcessResult(status: proc.terminationStatus,
                                                     stdout: outBuf.string, stderr: errBuf.string,
                                                     timedOut: timedOut.value))
            }
            do {
                try p.run()
            } catch {
                cont.resume(throwing: error)
                return
            }
            if let stdin { inp.fileHandleForWriting.write(Data(stdin.utf8)) }
            // Interactive flows (sign-in) may read stdin; closing it would make them abort.
            if !keepStdinOpen { try? inp.fileHandleForWriting.close() }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if p.isRunning {
                    timedOut.set()
                    p.terminate()
                }
            }
        }
    }
}

final class LockedData: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    var string: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

final class LockedFlag: @unchecked Sendable {
    private var v = false
    private let lock = NSLock()
    func set() { lock.lock(); v = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return v }
}

/// Lenient JSON helpers — the CLIs' payloads change over time, so we never decode strictly.
enum JSON {
    static func object(_ s: String) -> [String: Any]? {
        guard let data = s.data(using: .utf8) else { return nil }
        if let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return o }
        // Output may contain banners before/after the JSON. Grab the outermost object.
        guard let a = s.firstIndex(of: "{"), let b = s.lastIndex(of: "}"), a < b,
              let d = String(s[a...b]).data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }

    static func object(_ d: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    static func double(_ v: Any?) -> Double? {
        switch v {
        case let n as NSNumber: n.doubleValue
        case let s as String: Double(s)
        default: nil
        }
    }

    static func int(_ v: Any?) -> Int? { double(v).map { Int($0) } }

    static func string(_ v: Any?) -> String? {
        switch v {
        case let s as String: s
        case let n as NSNumber: n.stringValue
        default: nil
        }
    }

    /// Accepts unix seconds, unix millis or ISO-8601 strings.
    static func date(_ v: Any?) -> Date? {
        if let s = v as? String {
            if let d = iso.date(from: s) ?? isoFrac.date(from: s) { return d }
            if let n = Double(s) { return date(n) }
            return nil
        }
        guard let n = double(v), n > 0 else { return nil }
        return Date(timeIntervalSince1970: n > 10_000_000_000 ? n / 1000 : n)
    }

    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    nonisolated(unsafe) private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
}
