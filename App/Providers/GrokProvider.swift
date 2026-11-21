import Foundation

/// xAI Grok CLI ("Grok Build"). Reads the CLI's login from `~/.grok/auth.json` and asks the same
/// billing endpoint the CLI's `/usage` command uses. Grok plans currently expose a single
/// credit-based window (weekly on most plans); we map whatever period the backend reports.
struct GrokProvider: UsageProvider {
    let id = ProviderID.grok
    private static let api = URL(string: "https://cli-chat-proxy.grok.com/v1/")!

    static var home: URL {
        if let h = ProcessInfo.processInfo.environment["GROK_HOME"], !h.isEmpty {
            return URL(fileURLWithPath: (h as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok")
    }

    struct Auth { var token: String; var expiresAt: Date?; var email: String? }

    static func readAuth() -> Auth? {
        guard let data = try? Data(contentsOf: home.appendingPathComponent("auth.json")),
              let obj = JSON.object(data) else { return nil }
        // Keyed by issuer (e.g. "https://auth.x.ai::<client>"); take the freshest entry with a token.
        let entries = obj.values.compactMap { $0 as? [String: Any] }
            .compactMap { e -> Auth? in
                guard let key = JSON.string(e["key"]) ?? JSON.string(e["access_token"]), !key.isEmpty else { return nil }
                return Auth(token: key, expiresAt: JSON.date(e["expires_at"]), email: JSON.string(e["email"]))
            }
        return entries.max { ($0.expiresAt ?? .distantPast) < ($1.expiresAt ?? .distantPast) }
    }

    func fetch(command: String) async -> ProviderSnapshot {
        let version = await cliVersion(command: command)
        var snap = ProviderSnapshot(provider: id, status: .ok, cliVersion: version)
        guard var auth = Self.readAuth() else {
            return ProviderSnapshot(provider: id, status: .loggedOut, cliVersion: version)
        }
        if let exp = auth.expiresAt, exp < Date.now.addingTimeInterval(60) {
            // Let the CLI refresh its own token (refresh tokens may rotate).
            _ = try? await Shell.shared.runCLI(command, ["models"], timeout: 30)
            auth = Self.readAuth() ?? auth
            if let exp2 = auth.expiresAt, exp2 < .now {
                return ProviderSnapshot(provider: id, status: .loggedOut, cliVersion: version)
            }
        }
        snap.account = auth.email

        do {
            let billing = try await get("billing?format=credits", auth: auth, version: version)
            let config = (billing["config"] as? [String: Any]) ?? billing
            let used = JSON.double(config["creditUsagePercent"]) ?? JSON.double(config["usagePercent"]) ?? 0
            let period = config["currentPeriod"] as? [String: Any]
            let start = JSON.date(period?["start"]) ?? JSON.date(config["billingPeriodStart"])
            let end = JSON.date(period?["end"]) ?? JSON.date(config["billingPeriodEnd"])
            let type = (JSON.string(period?["type"]) ?? "").uppercased()
            let duration: TimeInterval? = (start != nil && end != nil) ? end!.timeIntervalSince(start!) : nil
            let kind: WindowKind
            let title: String
            if type.contains("WEEK") || (duration.map { abs($0 - 7 * 86400) < 3600 } ?? false) {
                (kind, title) = (.weekly, "Weekly")
            } else if type.contains("HOUR") || (duration.map { $0 <= 86400 } ?? false) {
                (kind, title) = (.session, "Session (\(Fmt.duration(duration ?? 0, compact: true)))")
            } else if type.contains("MONTH") {
                (kind, title) = (.other, "Monthly")
            } else {
                (kind, title) = (.other, duration.map { "\(Fmt.duration($0, compact: true)) period" } ?? "Plan usage")
            }
            if start != nil || end != nil || config["creditUsagePercent"] != nil {
                snap.windows.append(UsageWindow(id: "credits", kind: kind, title: title, usedFraction: used / 100,
                                                resetsAt: end, duration: duration))
            }
            if let cap = JSON.double((config["onDemandCap"] as? [String: Any])?["val"]), cap > 0 {
                let od = JSON.double((config["onDemandUsed"] as? [String: Any])?["val"]) ?? 0
                snap.windows.append(UsageWindow(id: "ondemand", kind: .other, title: "On-demand credits",
                                                usedFraction: od / cap, resetsAt: end, duration: duration))
            }
            if let bal = JSON.double((config["prepaidBalance"] as? [String: Any])?["val"]), bal > 0 {
                snap.notes.append("Prepaid balance: \(bal.formatted(.currency(code: "USD")))")
            }
        } catch GrokError.unauthorized {
            return ProviderSnapshot(provider: id, status: .loggedOut, cliVersion: version)
        } catch {
            snap.status = .error("Couldn't load Grok usage: \(error.localizedDescription)")
        }

        if let settings = try? await get("settings", auth: auth, version: version) {
            snap.plan = JSON.string(settings["subscription_tier_display"]) ?? JSON.string(settings["subscription_tier"])
        }
        return snap
    }

    enum GrokError: LocalizedError {
        case unauthorized, http(Int)
        var errorDescription: String? {
            switch self {
            case .unauthorized: "Not signed in"
            case .http(let c): "HTTP \(c)"
            }
        }
    }

    private func get(_ path: String, auth: Auth, version: String?) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: path, relativeTo: Self.api)!, timeoutInterval: 20)
        req.setValue("Bearer \(auth.token)", forHTTPHeaderField: "Authorization")
        req.setValue("xai-grok-cli", forHTTPHeaderField: "X-XAI-Token-Auth")
        if let version { req.setValue(version, forHTTPHeaderField: "x-grok-client-version") }
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw GrokError.unauthorized }
        guard (200..<300).contains(code) else { throw GrokError.http(code) }
        return JSON.object(data) ?? [:]
    }

    func redeem(reset: BankedReset?, command: String) async throws -> String {
        throw ShellError.failed("Grok doesn't offer banked resets.")
    }

    func login(command: String) async throws {
        // `grok login` opens the browser and listens on 127.0.0.1 for the callback.
        let r = try await Shell.shared.runCLI(command, ["login"], timeout: 600, keepStdinOpen: true)
        if r.ok, Self.readAuth() != nil { return }
        if r.timedOut { throw ShellError.failed("Sign-in timed out.") }
        let tail = (r.stdout + r.stderr).split(separator: "\n").suffix(2).joined(separator: " ")
        throw ShellError.failed(tail.isEmpty ? "Sign-in didn't complete." : tail)
    }

    func cliVersion(command: String) async -> String? {
        guard let r = try? await Shell.shared.runCLI(command, ["--version"], timeout: 10), r.ok else { return nil }
        // "grok 1.0.92 (b06756fd6256) [stable]"
        let parts = r.stdout.split(separator: " ")
        return parts.count > 1 ? String(parts[1]) : r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
