import Foundation

/// Google Antigravity CLI (`agy`). The CLI keeps its Google OAuth token in the Keychain (service `gemini`,
/// account `antigravity`, written by go-keyring through `/usr/bin/security`, so reading it the same way
/// doesn't prompt). Quotas come from the same Cloud Code endpoint the CLI calls on start-up
/// (`v1internal:fetchAvailableModels`), which reports a `remainingFraction` and `resetTime` per model.
struct AntigravityProvider: UsageProvider {
    let id = ProviderID.antigravity
    private static let api = URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:")!

    struct Auth { var token: String; var expiresAt: Date?; var email: String? }

    static func readAuth() async -> Auth? {
        guard let r = try? await Shell.run("/usr/bin/security",
                                           ["find-generic-password", "-s", "gemini", "-a", "antigravity", "-w"],
                                           timeout: 10), r.ok else { return nil }
        var raw = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("go-keyring-base64:"),
           let d = Data(base64Encoded: String(raw.dropFirst("go-keyring-base64:".count))) {
            raw = String(decoding: d, as: UTF8.self)
        }
        guard let obj = JSON.object(raw) else { return nil }
        let tok = (obj["token"] as? [String: Any]) ?? obj
        guard let access = JSON.string(tok["access_token"]), !access.isEmpty else { return nil }
        return Auth(token: access, expiresAt: JSON.date(tok["expiry"]), email: JSON.string(obj["id_token_email"]))
    }

    func fetch(command: String) async -> ProviderSnapshot {
        let version = await cliVersion(command: command)
        var snap = ProviderSnapshot(provider: id, status: .ok, cliVersion: version)
        guard var auth = await Self.readAuth() else {
            return ProviderSnapshot(provider: id, status: .loggedOut, cliVersion: version)
        }
        if let exp = auth.expiresAt, exp < Date.now.addingTimeInterval(60) {
            // Let the CLI refresh its own token: `agy models` signs in and fetches the model list.
            _ = try? await Shell.shared.runCLI(command, ["models"], timeout: 30)
            auth = await Self.readAuth() ?? auth
            if let exp2 = auth.expiresAt, exp2 < .now {
                return ProviderSnapshot(provider: id, status: .loggedOut, cliVersion: version)
            }
        }
        snap.account = auth.email

        do {
            let models = try await post("fetchAvailableModels", body: [:], auth: auth, version: version)
            snap.windows = Self.windows(from: models)
        } catch AGError.unauthorized {
            return ProviderSnapshot(provider: id, status: .loggedOut, cliVersion: version)
        } catch {
            snap.status = .error("Couldn't load Antigravity quotas: \(error.localizedDescription)")
        }

        let meta: [String: Any] = ["metadata": ["ideType": "ANTIGRAVITY", "pluginType": "GEMINI"]]
        if let load = try? await post("loadCodeAssist", body: meta, auth: auth, version: version) {
            let tier = (load["paidTier"] as? [String: Any]) ?? (load["currentTier"] as? [String: Any])
            let tid = (JSON.string(tier?["id"]) ?? "").lowercased()
            if tid.contains("free") || tid.isEmpty {
                snap.plan = tier == nil ? nil : "free"
            } else if tid.contains("ultra") {
                snap.plan = "Ultra"
            } else if tid.contains("pro") {
                snap.plan = "pro"
            } else {
                snap.plan = JSON.string(tier?["name"])?.replacingOccurrences(of: "Antigravity ", with: "")
            }
        }
        return snap
    }

    // MARK: Quota mapping

    private struct Group {
        var name: String
        var order: Int
        var remaining: Double
        var resetsAt: Date?
    }

    /// Folds the per-model quotas into a few readable limits: each Gemini model the agent can use gets its own
    /// limit, the third-party models (Claude, GPT-OSS) share one. The window length is derived from the reset
    /// time (an untouched quota resets exactly one window from now).
    static func windows(from resp: [String: Any], now: Date = .now) -> [UsageWindow] {
        let models = (resp["models"] as? [String: [String: Any]]) ?? [:]
        // The models the agent actually offers; fall back to every model with a reset time.
        var agentIDs: [String] = []
        for sort in (resp["agentModelSorts"] as? [[String: Any]]) ?? [] {
            for g in (sort["groups"] as? [[String: Any]]) ?? [] {
                agentIDs += ((g["modelIds"] as? [String]) ?? [])
            }
        }
        // Tiered Gemini models (flash / pro); "flashLite" only powers helpers like commit messages.
        for (k, v) in (resp["tieredModelIds"] as? [String: Any]) ?? [:] where !k.lowercased().contains("lite") {
            agentIDs += (v as? [String]) ?? []
        }
        var seen = Set<String>()
        agentIDs = agentIDs.filter { models[$0] != nil && seen.insert($0).inserted }
        if agentIDs.isEmpty {
            agentIDs = models.filter { ($0.value["quotaInfo"] as? [String: Any])?["resetTime"] != nil
                && $0.value["displayName"] != nil }.keys.sorted()
        }

        var groups: [String: Group] = [:]
        for mid in agentIDs {
            guard let m = models[mid], let q = m["quotaInfo"] as? [String: Any] else { continue }
            // proto3 JSON omits zero values, so a missing fraction on a present quota means "used up".
            let remaining = JSON.double(q["remainingFraction"]) ?? 0
            let reset = JSON.date(q["resetTime"])
            let provider = (JSON.string(m["modelProvider"]) ?? "").uppercased()
            let key: String, name: String, order: Int
            if provider.contains("GOOGLE") || mid.hasPrefix("gemini") {
                name = baseName(id: mid, display: JSON.string(m["displayName"]))
                key = name
                order = 0
            } else {
                key = "thirdparty"
                name = "" // filled in below
                order = 1
            }
            var g = groups[key] ?? Group(name: name, order: order, remaining: remaining, resetsAt: reset)
            if remaining < g.remaining || (remaining == g.remaining && (reset ?? .distantPast) > (g.resetsAt ?? .distantPast)) {
                g.remaining = remaining
                g.resetsAt = reset
            }
            groups[key] = g
        }
        if var tp = groups["thirdparty"] {
            var fams: [String] = []
            for mid in agentIDs where !(mid.hasPrefix("gemini")) {
                let p = (JSON.string(models[mid]?["modelProvider"]) ?? "").uppercased()
                let fam = p.contains("ANTHROPIC") || mid.hasPrefix("claude") ? "Claude"
                    : p.contains("OPENAI") || mid.hasPrefix("gpt") ? "GPT" : nil
                if let fam, !fams.contains(fam) { fams.append(fam) }
            }
            tp.name = fams.isEmpty ? "Other models" : fams.joined(separator: " & ")
            groups["thirdparty"] = tp
        }

        var out: [UsageWindow] = []
        var usedKinds = Set<WindowKind>()
        for (key, g) in groups.sorted(by: { ($0.value.order, $0.value.name) < ($1.value.order, $1.value.name) }) {
            let left = g.resetsAt.map { $0.timeIntervalSince(now) }
            let duration: TimeInterval? = left.map { l in
                l <= 5 * 3600 + 120 ? 5 * 3600 : l <= 86_400 + 120 ? 86_400 : 7 * 86_400
            }
            let base: WindowKind = (duration ?? 0) >= 7 * 86_400 ? .weekly : .session
            let span = duration.map { $0 >= 7 * 86_400 ? "Weekly" : $0 >= 86_400 ? "Daily" : "Session (5h)" } ?? "Quota"
            // The first limit of each length is the headline one; the rest are model-scoped.
            let kind: WindowKind = usedKinds.insert(base).inserted ? base : .model
            let w = UsageWindow(id: "agy.\(key)", kind: kind, title: "\(span) · \(g.name)", scope: g.name,
                                usedFraction: 1 - g.remaining, resetsAt: g.resetsAt, duration: duration)
            out.append(w)
        }
        return out
    }

    /// "gemini-3.8-flash-tiered" → "Gemini 3.8 Flash"; "Gemini 3 Flash (High)" → "Gemini 3 Flash".
    static func baseName(id: String, display: String?) -> String {
        if let display, !display.isEmpty {
            return display.replacingOccurrences(of: #"\s*\(.*\)$"#, with: "", options: .regularExpression)
        }
        let drop: Set<String> = ["tiered", "high", "medium", "low", "thinking", "preview"]
        return id.split(separator: "-").filter { !drop.contains($0.lowercased()) }
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    // MARK: HTTP

    enum AGError: LocalizedError {
        case unauthorized, http(Int)
        var errorDescription: String? {
            switch self {
            case .unauthorized: "Not signed in"
            case .http(let c): "HTTP \(c)"
            }
        }
    }

    private func post(_ method: String, body: [String: Any], auth: Auth, version: String?) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: Self.api.absoluteString + method)!, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("Bearer \(auth.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Without an Antigravity user agent the backend treats the call as a legacy Gemini Code Assist client.
        req.setValue("antigravity/\(version ?? "1.0.0") darwin/arm64", forHTTPHeaderField: "User-Agent")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw AGError.unauthorized }
        guard (200..<300).contains(code) else { throw AGError.http(code) }
        return JSON.object(data) ?? [:]
    }

    func redeem(reset: BankedReset?, command: String) async throws -> String {
        throw ShellError.failed("Antigravity doesn't offer banked resets.")
    }

    func login(command: String) async throws {
        // The CLI only signs in from its interactive UI, so hand it a terminal.
        let script = "tell application \"Terminal\" to do script \"\(command.replacingOccurrences(of: "\"", with: "\\\""))\""
        _ = try? await Shell.run("/usr/bin/osascript", ["-e", script, "-e", "tell application \"Terminal\" to activate"],
                                 timeout: 15)
        for _ in 0..<120 {
            try await Task.sleep(for: .seconds(5))
            if await Self.readAuth() != nil { return }
        }
        throw ShellError.failed("Sign-in didn't complete. Run `\(command)` in a terminal and sign in.")
    }

    func cliVersion(command: String) async -> String? {
        guard let r = try? await Shell.shared.runCLI(command, ["--version"], timeout: 10), r.ok else { return nil }
        // "1.5.14"
        return r.stdout.split(whereSeparator: \.isWhitespace).last.map(String.init)
    }
}
