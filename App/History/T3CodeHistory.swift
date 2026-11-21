import Foundation
import Security

/// Reads usage from T3 Code's local server (`server.getUsageSummary` over its WebSocket RPC).
/// T3 Code already scans every provider's history, prices it, and de-duplicates sources, so when it
/// is installed and running it's the most complete source.
enum T3AccessState: Equatable {
    case unknown, notInstalled, none, revoked, invalid
    case granted(expires: Date?, lastUsed: Date?)
}

enum T3CodeHistory {
    static let userData = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".t3/userdata")

    static var isInstalled: Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: userData.path) { return true }
        if let apps = try? fm.contentsOfDirectory(atPath: "/Applications"), apps.contains(where: { $0.hasPrefix("T3 Code") }) {
            return true
        }
        return Shell.extraDirs.contains { fm.isExecutableFile(atPath: "\($0)/t3") }
    }

    enum T3Error: LocalizedError {
        case notRunning, noToken(String), rpc(String)
        var errorDescription: String? {
            switch self {
            case .notRunning: "T3 Code isn't running"
            case .noToken(let m): "Couldn't get a T3 Code token: \(m)"
            case .rpc(let m): m
            }
        }
    }

    static func endpoint() -> URL? {
        guard let d = try? Data(contentsOf: userData.appendingPathComponent("server-runtime.json")),
              let o = JSON.object(d) else { return nil }
        if let pid = JSON.int(o["pid"]), kill(pid_t(pid), 0) != 0 { return nil }
        let host = JSON.string(o["host"]) ?? "127.0.0.1"
        guard let port = JSON.int(o["port"]) else { return nil }
        return URL(string: "ws://\(host):\(port)/ws?orchestrationProtocol=2")
    }

    // MARK: Token (stored in our own Keychain item)

    private static let service = "app.headroom.t3code"

    static func storedToken() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func store(token: String?) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(base as CFDictionary)
        guard let token else { return }
        var add = base
        add[kSecValueData as String] = Data(token.utf8)
        add[kSecAttrLabel as String] = "Headroom – T3 Code usage access"
        SecItemAdd(add as CFDictionary, nil)
    }

    static var revokedByUser: Bool { UserDefaults.standard.bool(forKey: "t3AccessRevoked") }
    private static var sessionID: String? {
        get { UserDefaults.standard.string(forKey: "t3SessionID") }
        set { UserDefaults.standard.set(newValue, forKey: "t3SessionID") }
    }

    /// Issues a read-only (`diagnostics:read`) bearer session for Headroom and stores it in the Keychain.
    /// If a previous Headroom session exists, it is revoked afterwards so they don't pile up.
    static func issueToken(command: String = "t3") async throws -> String {
        let r = try await Shell.shared.runCLI(command, ["auth", "session", "issue", "--scope", "diagnostics:read",
                                                        "--ttl", "90d", "--label", "Headroom", "--json"], timeout: 30)
        guard r.ok, let o = JSON.object(r.stdout), let token = JSON.string(o["token"]), !token.isEmpty else {
            let msg = (r.stderr + r.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
            throw T3Error.noToken(msg.isEmpty ? "Is T3 Code installed and has it been opened once?" : String(msg.prefix(200)))
        }
        let old = sessionID
        store(token: token)
        sessionID = JSON.string(o["sessionId"])
        if let old, old != sessionID {
            _ = try? await Shell.shared.runCLI(command, ["auth", "session", "revoke", old], timeout: 20)
        }
        return token
    }

    static func revoke(command: String = "t3") async {
        var ids = Set<String>()
        if let id = sessionID { ids.insert(id) }
        // Also clean up any other Headroom sessions (e.g. from an older install).
        for sess in await sessions(command: command) where JSON.string((sess["client"] as? [String: Any])?["label"]) == "Headroom" {
            if let id = JSON.string(sess["sessionId"]) { ids.insert(id) }
        }
        for id in ids { _ = try? await Shell.shared.runCLI(command, ["auth", "session", "revoke", id], timeout: 20) }
        store(token: nil)
        sessionID = nil
    }

    static func sessions(command: String = "t3") async -> [[String: Any]] {
        guard let r = try? await Shell.shared.runCLI(command, ["auth", "session", "list", "--json"], timeout: 20), r.ok,
              let data = r.stdout.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return arr
    }

    static func accessState(command: String = "t3") async -> T3AccessState {
        guard isInstalled else { return .notInstalled }
        guard storedToken() != nil else { return revokedByUser ? .revoked : .none }
        let all = await sessions(command: command)
        var match = all.first(where: { JSON.string($0["sessionId"]) == sessionID })
        if match == nil, sessionID == nil {
            // Token issued before we tracked the session id: adopt the newest "Headroom" session.
            match = all.filter { JSON.string(($0["client"] as? [String: Any])?["label"]) == "Headroom" }
                .max { (JSON.date($0["issuedAt"]) ?? .distantPast) < (JSON.date($1["issuedAt"]) ?? .distantPast) }
            if let id = match.flatMap({ JSON.string($0["sessionId"]) }) { sessionID = id }
        }
        guard let mine = match else {
            // Token exists but T3 no longer knows the session (revoked in T3 or data reset).
            return all.isEmpty ? .granted(expires: nil, lastUsed: nil) : .invalid
        }
        return .granted(expires: JSON.date(mine["expiresAt"]), lastUsed: JSON.date(mine["lastConnectedAt"]))
    }

    // MARK: Query

    static func load(days: Int = 366) async throws -> [DailyUsage] {
        guard !revokedByUser else { throw T3Error.noToken("Access was turned off in Settings") }
        guard let url = endpoint() else { throw T3Error.notRunning }
        var token = storedToken()
        if token == nil { token = try await issueToken() }
        // Renew quietly when the session is about to expire.
        if case .granted(let exp?, _) = await accessState(), exp.timeIntervalSinceNow < 7 * 86400 {
            token = (try? await issueToken()) ?? token
        }
        do {
            return try await summary(url: url, token: token!, days: days)
        } catch T3Error.rpc(let m) where m.contains("401") || m.lowercased().contains("unauthor") || m.lowercased().contains("scope") {
            // Token expired or revoked – mint a new one and retry once.
            token = try await issueToken()
            return try await summary(url: url, token: token!, days: days)
        }
    }

    private static func summary(url: URL, token: String, days: Int) async throws -> [DailyUsage] {
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: req)
        task.maximumMessageSize = 64 * 1024 * 1024
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }

        let cal = Calendar.current
        let since = cal.date(byAdding: .day, value: -(days - 1), to: cal.startOfDay(for: .now))!
        let request: [String: Any] = [
            "_tag": "Request", "id": "1", "tag": "server.getUsageSummary", "headers": [],
            "payload": ["sinceDay": DayFormatter.string(from: since), "untilDay": DayFormatter.string(from: .now),
                        "timeZone": TimeZone.current.identifier, "provisional": true],
        ]
        let data = try JSONSerialization.data(withJSONObject: request)
        try await task.send(.string(String(decoding: data, as: UTF8.self)))

        let deadline = Date.now.addingTimeInterval(90)
        while Date.now < deadline {
            let msg: URLSessionWebSocketTask.Message
            do { msg = try await task.receive() } catch {
                let code = (task.response as? HTTPURLResponse)?.statusCode
                throw T3Error.rpc(code.map { "HTTP \($0)" } ?? error.localizedDescription)
            }
            let text: String
            switch msg {
            case .string(let s): text = s
            case .data(let d): text = String(decoding: d, as: UTF8.self)
            @unknown default: continue
            }
            for line in text.split(separator: "\n") {
                guard let lineData = line.data(using: .utf8),
                      let parsed = try? JSONSerialization.jsonObject(with: lineData) else { continue }
                let frames = (parsed as? [[String: Any]]) ?? [(parsed as? [String: Any]) ?? [:]]
                for f in frames {
                    switch JSON.string(f["_tag"]) {
                    case "Ping"?:
                        try? await task.send(.string(#"{"_tag":"Pong"}"#))
                    case "Exit"?:
                        let exit = f["exit"] as? [String: Any]
                        guard JSON.string(exit?["_tag"]) == "Success", let value = exit?["value"] as? [String: Any] else {
                            throw T3Error.rpc(describe(exit?["cause"]) ?? "T3 Code returned an error")
                        }
                        return await parse(value)
                    case "Defect"?, "ClientProtocolError"?:
                        throw T3Error.rpc(describe(f) ?? "T3 Code protocol error")
                    default:
                        continue
                    }
                }
            }
        }
        throw T3Error.rpc("Timed out waiting for T3 Code")
    }

    private static func describe(_ any: Any?) -> String? {
        guard let any, let d = try? JSONSerialization.data(withJSONObject: any) else { return nil }
        return String(decoding: d, as: UTF8.self).prefix(300).description
    }

    static func parse(_ summary: [String: Any]) async -> [DailyUsage] {
        var out: [String: DailyUsage] = [:]
        for b in (summary["buckets"] as? [[String: Any]]) ?? [] {
            guard let dayRaw = JSON.string(b["day"]), let provRaw = JSON.string(b["provider"]) else { continue }
            let provider: ProviderID
            switch provRaw.lowercased() {
            case let s where s.contains("claude"): provider = .claude
            case let s where s.contains("codex"): provider = .codex
            case let s where s.contains("grok"): provider = .grok
            case let s where s.contains("antigravity") || s.contains("agy"): provider = .antigravity
            default: continue
            }
            let t = (b["totals"] as? [String: Any]) ?? [:]
            let model = JSON.string(b["model"])
            let key = "\(dayRaw)|\(provider.rawValue)|\(model ?? "")"
            var d = out[key] ?? DailyUsage(day: String(dayRaw.prefix(10)), provider: provider, model: model)
            d.inputTokens += JSON.int(t["uncachedInputTokens"]) ?? 0
            d.cacheReadTokens += JSON.int(t["cachedInputTokens"]) ?? 0
            d.cacheWriteTokens += JSON.int(t["cacheCreationTokens"]) ?? 0
            d.outputTokens += JSON.int(t["outputTokens"]) ?? 0
            if let c = JSON.double(b["costUsd"]) { d.costUSD = (d.costUSD ?? 0) + c }
            out[key] = d
        }
        return Array(out.values)
    }
}
