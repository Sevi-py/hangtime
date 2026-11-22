import Foundation

/// Claude Code.
///
/// * Credentials: the CLI's own OAuth login (Keychain item `Claude Code-credentials`, or
///   `~/.claude/.credentials.json`). We never refresh tokens ourselves — Claude Code rotates refresh
///   tokens, so doing so would sign the CLI out. When the token is stale we let the CLI refresh it.
/// * Limits: `GET /api/oauth/usage` — the same endpoint `/usage` in the CLI uses. The `limits[]`
///   array is generic (session / weekly_all / weekly_scoped with a model scope such as "Fable"),
///   which keeps us working when new limits appear.
/// * Banked resets: `cedar_ember` (listing via the usage endpoint, redeeming via
///   `/api/organizations/{org}/reset_rate_limits`) — what `/limit-reset` in the CLI does.
struct ClaudeProvider: UsageProvider {
    let id = ProviderID.claude

    private static let base = URL(string: "https://api.anthropic.com")!
    private static let cache = ClaudeCache()

    // MARK: Credentials

    struct Credentials {
        var accessToken: String
        var expiresAt: Date?
        var subscriptionType: String?
        var rateLimitTier: String?
    }

    static var configDir: URL {
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }

    static var globalConfigURL: URL {
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath).appendingPathComponent(".claude.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
    }

    static func readCredentials() async -> Credentials? {
        var raw: String?
        // `security` created the item (Claude Code writes it with `security add-generic-password`),
        // so reading through the same tool doesn't trigger a Keychain prompt.
        if let r = try? await Shell.run("/usr/bin/security",
                                        ["find-generic-password", "-s", "Claude Code-credentials", "-a", NSUserName(), "-w"],
                                        timeout: 10), r.ok {
            raw = r.stdout
        }
        if raw == nil || JSON.object(raw!)?["claudeAiOauth"] == nil,
           let data = try? Data(contentsOf: configDir.appendingPathComponent(".credentials.json")) {
            raw = String(decoding: data, as: UTF8.self)
        }
        guard let raw, let obj = JSON.object(raw), let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = JSON.string(oauth["accessToken"]), !token.isEmpty else { return nil }
        return Credentials(accessToken: token, expiresAt: JSON.date(oauth["expiresAt"]),
                           subscriptionType: JSON.string(oauth["subscriptionType"]),
                           rateLimitTier: JSON.string(oauth["rateLimitTier"]))
    }

    static func globalConfig() -> [String: Any]? {
        guard let d = try? Data(contentsOf: globalConfigURL) else { return nil }
        return JSON.object(d)
    }

    // MARK: Fetch

    func fetch(command: String) async -> ProviderSnapshot {
        let version = await cliVersion(command: command)
        var snap = ProviderSnapshot(provider: id, status: .ok, cliVersion: version)

        // Auth status from the CLI itself — robust to storage changes.
        let status = await authStatus(command: command)
        if let status, (status["loggedIn"] as? Bool) == false {
            return ProviderSnapshot(provider: id, status: .loggedOut, cliVersion: version)
        }
        if let method = JSON.string(status?["authMethod"]), method != "claude.ai", !method.contains("oauth") {
            snap.plan = "API"
            snap.notes.append("Signed in with \(method) – subscription limits don't apply.")
            return snap
        }
        snap.plan = JSON.string(status?["planTier"]) ?? JSON.string(status?["subscriptionType"])
        snap.account = JSON.string(status?["email"])

        var creds = await Self.readCredentials()
        if creds == nil {
            if status == nil { return ProviderSnapshot(provider: id, status: .loggedOut, cliVersion: version) }
            // Logged in, but we couldn't read the token: fall back to the CLI's own usage cache.
            return fromCache(into: snap, reason: "Couldn't read Claude credentials; showing Claude Code's cached usage.")
        }
        snap.plan = snap.plan ?? creds?.rateLimitTier ?? creds?.subscriptionType

        // Stale token → let the CLI refresh it (a no-cost control request), then re-read.
        if let exp = creds?.expiresAt, exp < Date.now.addingTimeInterval(60) {
            await nudgeCLIRefresh(command: command)
            creds = await Self.readCredentials() ?? creds
        }

        // Anthropic rate-limits this endpoint aggressively (per token). Respect Retry-After and never
        // poll more than every few minutes; serve the freshest cached body in between.
        if let wait = await Self.cache.retryAfter, wait > .now {
            return await fallback(await bestCached(into: snap), token: creds!.accessToken, version: version)
        }
        if let at = await Self.cache.fetchedAt, Date.now.timeIntervalSince(at) < Self.minInterval,
           await Self.cache.lastBody != nil {
            return await bestCached(into: snap)
        }

        do {
            let body = try await usage(token: creds!.accessToken, version: version)
            await Self.cache.store(body)
            var fresh = parse(body, into: snap, note: nil)
            fresh.dataAsOf = .now
            return fresh
        } catch ClaudeError.unauthorized {
            // Token revoked/rotated: give the CLI a chance to refresh, then retry once.
            await nudgeCLIRefresh(command: command)
            if let fresh = await Self.readCredentials(), fresh.accessToken != creds?.accessToken,
               let body = try? await usage(token: fresh.accessToken, version: version) {
                await Self.cache.store(body)
                return parse(body, into: snap, note: nil)
            }
            return ProviderSnapshot(provider: id, status: .loggedOut, cliVersion: version)
        } catch ClaudeError.rateLimited(let retry) {
            await Self.cache.setRetry(Self.cache.backoff(serverRetry: retry))
            return await fallback(await bestCached(into: snap), token: creds!.accessToken, version: version)
        } catch {
            if await Self.cache.lastBody != nil || Self.cliCache() != nil {
                var s = await bestCached(into: snap)
                s.notes.append("Couldn't reach Anthropic – showing last known values.")
                return await fallback(s, token: creds!.accessToken, version: version)
            }
            return await fallback(fromCache(into: snap, reason: "Couldn't reach Anthropic: \(error.localizedDescription)"),
                                  token: creds!.accessToken, version: version)
        }
    }

    /// Anthropic rate-limits this endpoint per token, and the token is shared with Claude Code itself,
    /// T3 Code and other tools – so stay well below the limit.
    static let minInterval: TimeInterval = 300

    /// Claude Code's own cached copy (`~/.claude.json → cachedUsageUtilization`), written whenever the CLI fetches.
    static func cliCache() -> (body: [String: Any], at: Date)? {
        guard let cached = globalConfig()?["cachedUsageUtilization"] as? [String: Any],
              let body = cached["utilization"] as? [String: Any] else { return nil }
        return (body, JSON.date(cached["fetchedAtMs"]) ?? .distantPast)
    }

    /// Marks numbers read from a cache as "last known", and applies what we *do* know: any window whose
    /// reset time has passed since the snapshot has been reset.
    private func ageing(_ s: ProviderSnapshot, asOf: Date) async -> ProviderSnapshot {
        var snap = s
        snap.dataAsOf = asOf
        guard Date.now.timeIntervalSince(asOf) > 10 * 60 else { return snap }
        let retry = await Self.cache.retryAfter
        snap.staleReason = "Anthropic is limiting usage checks"
            + (retry.map { $0 > .now ? " – retrying \(DateFmt.time($0))" : "" } ?? "")
            + "."
        for i in snap.windows.indices {
            snap.windows[i].isStale = true
            snap.windows[i].asOf = asOf
            if let r = snap.windows[i].resetsAt, r <= .now {
                snap.windows[i].usedFraction = 0
                snap.windows[i].resetsAt = nil
            }
        }
        return snap
    }

    /// Picks whichever is newer: our last response or the CLI's cache. Banked resets only come from ours.
    private func bestCached(into snap: ProviderSnapshot) async -> ProviderSnapshot {
        let ours = Self.cache.peek()
        let cli = Self.cliCache()
        if let ours, ours.at >= (cli?.at ?? .distantPast) || cli == nil {
            return await ageing(parse(ours.body, into: snap, note: nil), asOf: ours.at)
        }
        if let cli {
            var s = parse(cli.body, into: snap, note: nil)
            // Keep the banked resets from our (older) response – the CLI cache doesn't include them.
            if let ours, cli.body["cedar_ember"] == nil || cli.body["cedar_ember"] is NSNull {
                let withResets = parse(ours.body, into: snap, note: nil)
                s.bankedResets = withResets.bankedResets
                s.bankedResetCount = withResets.bankedResetCount
            }
            return await ageing(s, asOf: cli.at)
        }
        var s = snap
        s.status = .error("Anthropic is rate limiting usage requests – trying again soon.")
        return s
    }

    private func fromCache(into snap: ProviderSnapshot, reason: String?) -> ProviderSnapshot {
        guard let cached = Self.globalConfig()?["cachedUsageUtilization"] as? [String: Any],
              let body = cached["utilization"] as? [String: Any] else {
            var s = snap
            s.status = .error(reason ?? "Usage temporarily unavailable.")
            return s
        }
        var note: String? = reason
        if let ms = JSON.date(cached["fetchedAtMs"]) {
            note = (reason.map { $0 + " " } ?? "") + "Cached \(ms.formatted(.relative(presentation: .named)))."
        }
        var out = parse(body, into: snap, note: note)
        if let at = JSON.date(cached["fetchedAtMs"]) { out.dataAsOf = at }
        return out
    }

    // MARK: Fallback: quota probe + limits hit in Claude Code's logs

    /// UserDefaults key of the "check with a tiny request" setting (on by default).
    static let probeSettingKey = "claudeProbe"
    static var probeEnabled: Bool { UserDefaults.standard.object(forKey: probeSettingKey) as? Bool ?? true }
    /// At most one probe every 10 minutes, whether it worked or not.
    static let probeInterval: TimeInterval = 600
    /// Fable's reply carries all three limits (session, weekly and Fable's own weekly share); Haiku's only the first
    /// two, but it's the cheapest model and keeps working when Fable's own limit is used up.
    static let fableModel = "claude-fable-5-2"
    static let haikuModel = "claude-haiku-5-5"

    /// One limit as read from rate-limit headers or a logged rejection. Keys are the backend's limit names:
    /// `five_hour`, `seven_day`, `seven_day_overage_included` (the model-scoped weekly limit, e.g. Fable).
    struct LiveLimit: Codable { var used: Double; var resetsAt: Date? }
    struct LiveReading: Codable { var at: Date; var limits: [String: LiveLimit] }

    /// Used while `/api/oauth/usage` is blocked. Usage also comes back as headers on every model reply, so we
    /// ask for one token (what Claude Code's own quota probe does) and read them off. When a limit is used up
    /// the request is refused, and the refusal says which limit and when it resets. Hit limits Claude Code
    /// recorded in its transcripts are used too, at no cost.
    private func fallback(_ base: ProviderSnapshot, token: String, version: String?) async -> ProviderSnapshot {
        let baseAt = base.status == .ok && !base.windows.isEmpty ? (base.dataAsOf ?? .distantPast) : .distantPast
        var probe: LiveReading? = nil
        if Self.probeEnabled {
            if await Self.cache.claimProbeSlot(interval: Self.probeInterval),
               let fresh = await probeLimits(base: base, token: token, version: version) {
                await Self.cache.storeProbe(fresh)
            }
            probe = await Self.cache.lastProbe
        }
        var readings: [LiveReading] = []
        if let probe, probe.at > baseAt { readings.append(probe) }
        let since = max(baseAt, probe?.at ?? .distantPast)
        readings += Self.loggedLimitHits(since: since)
        guard !readings.isEmpty else { return base }

        var snap = base
        if snap.status != .ok { snap.status = .ok }
        for r in readings.sorted(by: { $0.at < $1.at }) {  // newest wins
            for (key, limit) in r.limits { apply(limit, key: key, at: r.at, to: &snap) }
        }
        snap.dataAsOf = readings.map(\.at).max()
        let old = snap.windows.filter { $0.isStale == true }
        if old.isEmpty {
            snap.staleReason = nil
        } else if old.count < snap.windows.count {
            let names = old.map { $0.scope ?? $0.title }.joined(separator: ", ")
            let retry = await Self.cache.retryAfter.flatMap { $0 > .now ? " – retrying \(DateFmt.time($0))" : nil } ?? ""
            snap.staleReason = "\(names): last known value. Anthropic is limiting usage checks\(retry)."
        }
        return snap
    }

    private func apply(_ limit: LiveLimit, key: String, at: Date, to snap: inout ProviderSnapshot) {
        var used = limit.used, reset = limit.resetsAt
        if let r = reset, r <= .now { used = 0; reset = nil }  // that window has reset since
        let stale = Date.now.timeIntervalSince(at) > 2 * Self.probeInterval
        let idx: Int?
        switch key {
        case "five_hour": idx = snap.windows.firstIndex { $0.kind == .session }
        case "seven_day": idx = snap.windows.firstIndex { $0.kind == .weekly }
        case "seven_day_overage_included":
            // The model-scoped weekly limit. It's the one probed with (Fable), or the only model limit we know.
            let models = snap.windows.indices.filter { snap.windows[$0].kind == .model }
            idx = models.first { snap.windows[$0].scope?.lowercased() == "fable" } ?? (models.count == 1 ? models.first : nil)
            if idx == nil && !models.isEmpty { return }
        default: return
        }
        if let i = idx {
            snap.windows[i].usedFraction = min(max(used, 0), 1)
            snap.windows[i].resetsAt = reset
            snap.windows[i].isStale = stale ? true : nil
            snap.windows[i].asOf = at
            snap.windows[i].note = nil  // the endpoint's "share of weekly" breakdown no longer matches
        } else if key == "seven_day_overage_included" {
            var w = UsageWindow(id: "limits.weekly_scoped.Fable", kind: .model, title: "Weekly · Fable", scope: "Fable",
                                usedFraction: used, resetsAt: reset, duration: 7 * 86400)
            w.isStale = stale ? true : nil
            w.asOf = at
            snap.windows.append(w)
        } else {
            let session = key == "five_hour"
            var w = UsageWindow(id: session ? "limits.session.all" : "limits.weekly_all.all",
                                kind: session ? .session : .weekly, title: session ? "Session (5h)" : "Weekly",
                                usedFraction: used, resetsAt: reset, duration: session ? 5 * 3600 : 7 * 86400)
            w.isStale = stale ? true : nil
            w.asOf = at
            snap.windows.append(w)
        }
    }

    /// One probe round (at most every 10 minutes):
    /// 1. Fable, which reports session, weekly and Fable's own limit in one reply. While Fable's limit is used up
    ///    the request is refused but still tells us when Fable resets, so we keep asking: a reset used elsewhere
    ///    shows up on the next round.
    /// 2. Haiku, only for what Fable didn't report: usually session and weekly while Fable is refused.
    /// Fable is skipped when it can't tell us anything we'd show: model limits are hidden in Settings, this
    /// account has no Fable limit, or the Fable model isn't available to it.
    private func probeLimits(base: ProviderSnapshot, token: String, version: String?) async -> LiveReading? {
        var limits: [String: LiveLimit] = [:]
        if await wantsFableProbe(base: base) {
            switch await quotaProbe(model: Self.fableModel, token: token, version: version) {
            case .reading(let l):
                limits = l
                // An answered request without a Fable limit: this account doesn't have one (for now).
                // (A refusal for another limit may leave the Fable headers out, so it proves nothing.)
                if l["seven_day_overage_included"] == nil, !l.values.contains(where: { $0.used >= 1 }) {
                    await Self.cache.skipFable(for: 86400)
                }
            case .modelUnavailable:
                await Self.cache.skipFable(for: 86400)
            case .failed:
                break
            }
        }
        if limits["five_hour"] == nil || limits["seven_day"] == nil,
           case .reading(let l) = await quotaProbe(model: Self.haikuModel, token: token, version: version) {
            for key in ["five_hour", "seven_day"] where limits[key] == nil { limits[key] = l[key] }
        }
        return limits.isEmpty ? nil : LiveReading(at: .now, limits: limits)
    }

    private func wantsFableProbe(base: ProviderSnapshot) async -> Bool {
        if UserDefaults.standard.object(forKey: "showModelLimits") as? Bool == false { return false }
        if let until = await Self.cache.fableSkippedUntil, until > .now { return false }
        // The last regular check listed this account's limits, and there was no model-specific one.
        if base.status == .ok, !base.windows.isEmpty, !base.windows.contains(where: { $0.kind == .model }) { return false }
        return true
    }

    enum ProbeOutcome { case reading([String: LiveLimit]), modelUnavailable, failed }

    /// Sends a one-token request with as little thinking as the model allows and reads the unified
    /// rate-limit headers.
    private func quotaProbe(model: String, token: String, version: String?) async -> ProbeOutcome {
        var req = URLRequest(url: Self.base.appendingPathComponent("v1/messages"), timeoutInterval: 20)
        req.httpMethod = "POST"
        Self.authorize(&req, token: token, version: version)
        // OAuth requests are only served when they look like Claude Code's own.
        req.setValue("claude-code-20250219,oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("cli", forHTTPHeaderField: "x-app")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "model": model, "max_tokens": 1,
            "system": [["type": "text", "text": "You are Claude Code, Anthropic's official CLI for Claude."]],
            "messages": [["role": "user", "content": "quota"]],
        ]
        // Haiku can turn thinking off; Fable only takes an effort level (low = no thinking tokens for this).
        if model == Self.haikuModel { body["thinking"] = ["type": "disabled"] } else { body["output_config"] = ["effort": "low"] }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return .failed }
        func header(_ name: String) -> String? { http.value(forHTTPHeaderField: "anthropic-ratelimit-unified-\(name)") }
        func date(_ name: String) -> Date? { header(name).flatMap(Double.init).map { Date(timeIntervalSince1970: $0) } }

        var limits: [String: LiveLimit] = [:]
        for (key, claim) in [("five_hour", "5h"), ("seven_day", "7d"), ("seven_day_overage_included", "7d_oi")] {
            let rejected = header("\(claim)-status") == "rejected"
            guard let used = rejected ? 1 : header("\(claim)-utilization").flatMap(Double.init) else { continue }
            limits[key] = LiveLimit(used: used, resetsAt: date("\(claim)-reset"))
        }
        // Out of usage: the request is refused, and the headers say which limit and until when.
        if header("status") == "rejected", let claim = header("representative-claim") {
            limits[claim] = LiveLimit(used: 1, resetsAt: limits[claim]?.resetsAt ?? date("reset"))
        }
        if !limits.isEmpty { return .reading(limits) }
        return [400, 403, 404].contains(http.statusCode) ? .modelUnavailable : .failed
    }

    /// Limits Claude Code ran into, from its transcripts (`apiError: usage_limit_reached`). Only entries newer
    /// than `since` whose reset is still ahead count, and only files written since then are read.
    static func loggedLimitHits(since: Date) -> [LiveReading] {
        let floor = max(since, Date.now.addingTimeInterval(-7 * 86400))
        let root = configDir.appendingPathComponent("projects", isDirectory: true)
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                                                         options: [.skipsHiddenFiles]) else { return [] }
        let needle = Data("usage_limit_reached".utf8)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var newest: [String: (at: Date, limit: LiveLimit)] = [:]
        for case let url as URL in files where url.pathExtension == "jsonl" {
            guard let mod = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  mod > floor, let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  data.range(of: needle) != nil else { continue }
            for line in data.split(separator: UInt8(ascii: "\n")) where line.range(of: needle) != nil {
                guard let obj = JSON.object(Data(line)), JSON.string(obj["apiError"]) == "usage_limit_reached",
                      let ts = JSON.string(obj["timestamp"]).flatMap(iso.date(from:)), ts > floor,
                      let info = (obj["apiErrorParams"] as? [String: Any])?["rate_limit_info"] as? [String: Any],
                      JSON.string(info["status"]) == "rejected", let type = JSON.string(info["rateLimitType"]),
                      let reset = JSON.double(info["resetsAt"]).map({ Date(timeIntervalSince1970: $0) }), reset > .now
                else { continue }
                if (newest[type]?.at ?? .distantPast) < ts { newest[type] = (ts, LiveLimit(used: 1, resetsAt: reset)) }
            }
        }
        return newest.map { LiveReading(at: $0.value.at, limits: [$0.key: $0.value.limit]) }
    }

    enum ClaudeError: Error { case unauthorized, rateLimited(Date?), http(Int) }

    private func usage(token: String, version: String?) async throws -> [String: Any] {
        var comps = URLComponents(url: Self.base.appendingPathComponent("api/oauth/usage"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [.init(name: "cedar_ember", value: "1"), .init(name: "at_wall", value: "1"),
                            .init(name: "skip_spend", value: "1")]
        do {
            return try await get(comps.url!, token: token, version: version)
        } catch ClaudeError.http(let code) where code == 400 || code == 403 {
            // Older backends / missing flags: retry plain.
            return try await get(Self.base.appendingPathComponent("api/oauth/usage"), token: token, version: version)
        }
    }

    private func get(_ url: URL, token: String, version: String?) async throws -> [String: Any] {
        var req = URLRequest(url: url, timeoutInterval: 20)
        Self.authorize(&req, token: token, version: version)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200..<300:
            guard let obj = JSON.object(data) else { throw ClaudeError.http(code) }
            return obj
        case 401: throw ClaudeError.unauthorized
        case 429:
            let ra = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
            throw ClaudeError.rateLimited(Date.now.addingTimeInterval(ra ?? 120))
        default: throw ClaudeError.http(code)
        }
    }

    private static func authorize(_ req: inout URLRequest, token: String, version: String?) {
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        // The backend gates some features (banked resets) on the CLI version in the UA.
        let v = version?.split(separator: " ").first.map(String.init) ?? "2.1.330"
        req.setValue("claude-cli/\(v) (external, cli)", forHTTPHeaderField: "User-Agent")
    }

    // MARK: Parsing

    static let flatTitles: [String: (WindowKind, String, String?)] = [
        "five_hour": (.session, "Session (5h)", nil),
        "seven_day": (.weekly, "Weekly", nil),
        "seven_day_opus": (.model, "Weekly · Opus", "Opus"),
        "seven_day_sonnet": (.model, "Weekly · Sonnet", "Sonnet"),
        "seven_day_oauth_apps": (.other, "Weekly · Apps", nil),
        "seven_day_cowork": (.other, "Weekly · Routines", nil),
        "seven_day_routines": (.other, "Weekly · Routines", nil),
    ]
    /// Keys that share the main limit and would only duplicate it.
    static let ignoredFlat: Set<String> = ["seven_day_omelette", "seven_day_overage_included"]

    func parse(_ body: [String: Any], into base: ProviderSnapshot, note: String?) -> ProviderSnapshot {
        var snap = base
        snap.status = .ok
        if let note { snap.notes.append(note) }
        var seen = Set<String>()

        // 1. Generic `limits[]` (preferred).
        for (i, l) in ((body["limits"] as? [[String: Any]]) ?? []).enumerated() {
            guard let pct = JSON.double(l["percent"]) ?? JSON.double(l["utilization"]) else { continue }
            let kindRaw = JSON.string(l["kind"]) ?? ""
            let group = JSON.string(l["group"]) ?? ""
            let scopeObj = l["scope"] as? [String: Any]
            let model = (scopeObj?["model"] as? [String: Any]).flatMap { JSON.string($0["display_name"]) ?? JSON.string($0["id"]) }
            let surface = JSON.string(scopeObj?["surface"]) ?? ((scopeObj?["surface"] as? [String: Any]).flatMap { JSON.string($0["display_name"]) })
            let scope = model ?? surface
            let isSession = kindRaw.contains("session") || group == "session" || kindRaw.contains("five_hour")
            let isWeekly = kindRaw.contains("weekly") || group == "weekly" || kindRaw.contains("seven_day")
            let kind: WindowKind = scope != nil ? .model : isSession ? .session : isWeekly ? .weekly : .other
            let baseTitle = isSession ? "Session (5h)" : isWeekly ? "Weekly" : kindRaw.replacingOccurrences(of: "_", with: " ").capitalized
            let title = scope.map { "\(baseTitle) · \($0)" } ?? baseTitle
            let wid = "limits.\(kindRaw).\(scope ?? "all")"
            guard !seen.contains(wid) else { continue }
            seen.insert(wid)
            snap.windows.append(UsageWindow(
                id: wid.isEmpty ? "limits.\(i)" : wid, kind: kind, title: title, scope: scope,
                usedFraction: pct / 100, resetsAt: JSON.date(l["resets_at"]),
                duration: isSession ? 5 * 3600 : isWeekly ? 7 * 86400 : nil))
        }
        // Model-scoped weekly limits are a share of the overall weekly limit (e.g. Fable may use up to 50%).
        let limitsArray = (body["limits"] as? [[String: Any]]) ?? []
        for share in (body["weekly_scoped_shares"] as? [[String: Any]]) ?? [] {
            guard let idx = JSON.int(share["limit_index"]), idx >= 0, idx < limitsArray.count else { continue }
            let l = limitsArray[idx]
            let scope = ((l["scope"] as? [String: Any])?["model"] as? [String: Any]).flatMap { JSON.string($0["display_name"]) ?? JSON.string($0["id"]) }
            let wid = "limits.\(JSON.string(l["kind"]) ?? "").\(scope ?? "all")"
            guard let i = snap.windows.firstIndex(where: { $0.id == wid }) else { continue }
            var parts: [String] = []
            if let allow = JSON.int(share["allowance_percent_of_weekly"]) { parts.append("Up to \(allow)% of weekly") }
            if let used = JSON.int(share["used_percent_of_weekly"]) { parts.append("\(used)% of weekly used") }
            if !parts.isEmpty { snap.windows[i].note = parts.joined(separator: " · ") }
        }
        let hasLimits = !snap.windows.isEmpty
        let modelScopes = Set(snap.windows.compactMap { $0.scope?.lowercased() })

        // 2. Flat keys (`five_hour`, `seven_day*`) – fallback, or for extra scopes not in limits[].
        for (key, value) in body {
            guard let w = value as? [String: Any], let util = JSON.double(w["utilization"]) else { continue }
            guard key == "five_hour" || key.hasPrefix("seven_day") || key.hasPrefix("thirty_day"),
                  !Self.ignoredFlat.contains(key), !key.hasSuffix("_breakdown") else { continue }
            let known = Self.flatTitles[key]
            if hasLimits {
                if key == "five_hour" || key == "seven_day" { continue }
                if let scope = known?.2, modelScopes.contains(scope.lowercased()) { continue }
            }
            let isSession = key == "five_hour"
            let isWeek = key.hasPrefix("seven_day")
            let fallbackTitle = key.replacingOccurrences(of: "seven_day_", with: "Weekly · ")
                .replacingOccurrences(of: "_", with: " ").capitalized
            snap.windows.append(UsageWindow(
                id: key, kind: known?.0 ?? .other, title: known?.1 ?? fallbackTitle, scope: known?.2,
                usedFraction: util / 100, resetsAt: JSON.date(w["resets_at"]),
                duration: isSession ? 5 * 3600 : isWeek ? 7 * 86400 : key.hasPrefix("thirty_day") ? 30 * 86400 : nil))
        }

        // Extra usage (pay-as-you-go overage).
        if let extra = body["extra_usage"] as? [String: Any], (extra["is_enabled"] as? Bool) == true {
            let decimals = JSON.int(extra["decimal_places"]) ?? 2
            let div = pow(10, Double(decimals))
            let cur = JSON.string(extra["currency"]) ?? "USD"
            if let used = JSON.double(extra["used_credits"]), let limit = JSON.double(extra["monthly_limit"]), limit > 0 {
                snap.notes.append("Extra usage: \((used / div).formatted(.currency(code: cur))) of \((limit / div).formatted(.currency(code: cur))) this month")
            } else if let used = JSON.double(extra["used_credits"]) {
                snap.notes.append("Extra usage: \((used / div).formatted(.currency(code: cur))) this month")
            }
        }

        // Banked resets.
        if let ce = body["cedar_ember"] as? [String: Any] {
            var count = 0
            for g in (ce["grants"] as? [[String: Any]]) ?? [] {
                guard let gid = JSON.string(g["id"]) else { continue }
                let left = JSON.int(g["resets_left"]) ?? 1
                if (g["paused"] as? Bool) == true || left <= 0 { continue }
                if let start = JSON.date(g["starts_at"]), start > .now { continue }
                let expires = JSON.date(g["ends_at"])
                if let expires, expires <= .now { continue }
                count += left
                let clears = (g["clears"] as? [String]) ?? []
                let kind: String = {
                    if (g["gives_back_weekly"] as? Bool) == true { return "Fable reset" }
                    switch JSON.string(g["type"]) {
                    case "session"?: return "Session reset"
                    case "weekly"?: return "Weekly reset"
                    case "full"?: return "Full reset (Session + Weekly)"
                    default:
                        let s = clears.contains("five_hour"), w = clears.contains { $0 != "five_hour" }
                        return s && w ? "Full reset (Session + Weekly)" : s ? "Session reset" : "Weekly reset"
                    }
                }()
                var details: [String] = []
                if let label = JSON.string(g["label"]), !label.isEmpty { details.append(label) }
                if left > 1 { details.append("\(left) uses left") }
                if (g["usable_now"] as? Bool) == false {
                    let reason = JSON.string(g["unavailable_reason"])
                    details.append(reason == "needs_limit" || (g["use_requires_limit"] as? Bool) == true
                                   ? "Usable once you hit a limit" : "Not usable right now")
                }
                snap.bankedResets.append(BankedReset(
                    id: gid, title: kind, detail: details.isEmpty ? nil : details.joined(separator: " · "),
                    grantedAt: JSON.date(g["starts_at"]), expiresAt: expires,
                    redeemable: (g["usable_now"] as? Bool) ?? true))
            }
            snap.bankedResetCount = count
            if let cd = JSON.date(ce["cooldown_until"]), cd > .now {
                snap.notes.append("Resets on cooldown until \(DateFmt.dateTime(cd))")
            }
        }
        if let jt = body["juniper_tide"] as? [String: Any], (jt["eligible"] as? Bool) == true {
            if (jt["available"] as? Bool) == true {
                snap.bankedResets.append(BankedReset(
                    id: "juniper_tide", title: "Reset 5-hour limit now",
                    detail: "Weekly allowance · counts against your weekly limit",
                    expiresAt: nil, redeemable: true))
            } else if let next = JSON.date(jt["next_available_at"]) {
                snap.notes.append("Next free 5-hour reset \(next.formatted(.relative(presentation: .named)))")
            }
        }
        snap.bankedResets.sort { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
        return snap
    }

    // MARK: Redeem

    func redeem(reset: BankedReset?, command: String) async throws -> String {
        guard let reset else { throw ShellError.failed("Pick a reset to use.") }
        guard let creds = await Self.readCredentials() else { throw ShellError.failed("Claude Code isn't signed in.") }
        let account = Self.globalConfig()?["oauthAccount"] as? [String: Any]
        guard let org = JSON.string(account?["organizationUuid"]) else {
            throw ShellError.failed("Couldn't determine your Claude organization.")
        }
        let version = await cliVersion(command: command)
        var body: [String: Any]
        if reset.id == "juniper_tide" {
            body = ["program": "juniper_tide"]
        } else {
            body = ["program": "cedar_ember", "grant_id": reset.id]
        }
        let requestID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        body["request_id"] = requestID

        var lastResult: [String: Any] = [:]
        for attempt in 0..<3 {
            var req = URLRequest(url: Self.base.appendingPathComponent("api/organizations/\(org)/reset_rate_limits"),
                                 timeoutInterval: 30)
            req.httpMethod = "POST"
            Self.authorize(&req, token: creds.accessToken, version: version)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 || code == 403 { throw ShellError.failed("Claude rejected the request (HTTP \(code)). Try signing in again.") }
            if code == 429 { throw ShellError.failed("Too many requests – try again in a minute.") }
            lastResult = JSON.object(data) ?? [:]
            // "unavailable" = couldn't confirm; retry with the same idempotency key.
            if JSON.string(lastResult["result"]) == "unavailable", attempt < 2 {
                try await Task.sleep(for: .seconds(2))
                continue
            }
            break
        }
        await Self.cache.invalidate()
        let reason = JSON.string(lastResult["reason"]).map { " (\($0.replacingOccurrences(of: "_", with: " ")))" } ?? ""
        switch JSON.string(lastResult["result"]) {
        case "reset"?:
            let cleared = (lastResult["cleared"] as? [String])?.map { $0 == "five_hour" ? "session" : "weekly" }
            return "Claude limits reset\(cleared.map { ": \(Set($0).sorted().joined(separator: " + "))" } ?? "")."
        case "already_used"?: return "That reset was already used."
        case "not_limited"?: return "Nothing to reset – you're not at a limit right now."
        case "cooldown"?: return "Resets are on cooldown\(reason)."
        case "ineligible"?: return "This account can't use that reset\(reason)."
        case "unavailable"?: return "Claude couldn't confirm the reset – check again shortly."
        case let other?: return "Claude replied: \(other)\(reason)"
        case nil: return "Unexpected response from Claude."
        }
    }

    // MARK: CLI helpers

    func cliVersion(command: String) async -> String? {
        if let v = await Self.cache.version(for: command) { return v }
        guard let r = try? await Shell.shared.runCLI(command, ["--version"], timeout: 15), r.ok else { return nil }
        let v = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " (Claude Code)", with: "")
        await Self.cache.setVersion(v, for: command)
        return v
    }

    private func authStatus(command: String) async -> [String: Any]? {
        guard let r = try? await Shell.shared.runCLI(command, ["auth", "status", "--json"], timeout: 20) else { return nil }
        if let o = JSON.object(r.stdout), o["loggedIn"] != nil { return o }
        // Older CLIs: plain `auth status`.
        if let r2 = try? await Shell.shared.runCLI(command, ["auth", "status"], timeout: 20),
           let o = JSON.object(r2.stdout), o["loggedIn"] != nil { return o }
        let text = (r.stdout + r.stderr).lowercased()
        if text.contains("not logged in") || text.contains("logged out") { return ["loggedIn": false] }
        return nil
    }

    /// Asks the CLI to do something authenticated (a free `get_usage` control request) so it refreshes
    /// its own OAuth token.
    private func nudgeCLIRefresh(command: String) async {
        let input = """
        {"type":"control_request","request_id":"r1","request":{"subtype":"initialize"}}
        {"type":"control_request","request_id":"r2","request":{"subtype":"get_usage","skip_behaviors":true}}

        """
        _ = try? await Shell.shared.runCLI(command, ["-p", "--input-format", "stream-json", "--output-format",
                                                     "stream-json", "--verbose"], timeout: 25, stdin: input)
    }

    func login(command: String) async throws {
        // `claude auth login` opens the browser itself and waits for the localhost callback.
        // It doesn't need a TTY, but stdin must stay open (it offers a "paste code" fallback).
        let r = try await Shell.shared.runCLI(command, ["auth", "login", "--claudeai"], timeout: 600, keepStdinOpen: true)
        await Self.cache.invalidate()
        if let status = await authStatus(command: command), (status["loggedIn"] as? Bool) == true { return }
        if r.timedOut { throw ShellError.failed("Sign-in timed out.") }
        let tail = (r.stdout + r.stderr).split(separator: "\n").suffix(2).joined(separator: " ")
        throw ShellError.failed(tail.isEmpty ? "Sign-in didn't complete." : tail)
    }
}

/// Remembers the last usage response (persisted, so relaunches don't hit the endpoint) and the backoff.
final class ClaudeCache: @unchecked Sendable {
    private let lock = NSLock()
    private var body: [String: Any]?
    private var at: Date?
    private var retry: Date?
    private var versions: [String: (String, Date)] = [:]

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("app.hangtime", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("claude-usage.json")
    }

    init() {
        if let d = try? Data(contentsOf: Self.fileURL), let o = JSON.object(d) {
            body = o["body"] as? [String: Any]
            at = JSON.date(o["at"])
        }
        retry = UserDefaults.standard.object(forKey: "claude.retryAfter") as? Date
    }

    private func sync<T>(_ f: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return f() }

    var lastBody: [String: Any]? { get async { sync { body } } }
    var fetchedAt: Date? { get async { sync { at } } }
    var retryAfter: Date? { get async { sync { retry } } }
    func peek() -> (body: [String: Any], at: Date)? { sync { body.map { ($0, at ?? .distantPast) } } }

    func store(_ b: [String: Any]) async {
        sync { body = b; at = .now; retry = nil; strikes = 0 }
        UserDefaults.standard.set(0, forKey: "claude.429strikes")
        UserDefaults.standard.removeObject(forKey: "claude.retryAfter")
        if let d = try? JSONSerialization.data(withJSONObject: ["body": b, "at": Date.now.timeIntervalSince1970]) {
            try? d.write(to: Self.fileURL, options: .atomic)
        }
    }

    private var strikes: Int = UserDefaults.standard.integer(forKey: "claude.429strikes")

    /// Exponential backoff on repeated 429s (5 min, 10, 20, … up to 2 h), never shorter than the server asks.
    func backoff(serverRetry: Date?) -> Date {
        let n = sync { strikes += 1; return strikes }
        UserDefaults.standard.set(n, forKey: "claude.429strikes")
        let ours = Date.now.addingTimeInterval(min(7200, 300 * pow(2, Double(n - 1))))
        return max(ours, serverRetry ?? .distantPast)
    }

    func setRetry(_ d: Date?) async {
        sync { retry = d }
        UserDefaults.standard.set(d, forKey: "claude.retryAfter")
    }

    /// After a redeem/login we want fresh numbers, but never ignore a server backoff.
    func invalidate() async {
        sync { at = nil; probeAttempt = nil; fableSkip = nil }
        UserDefaults.standard.removeObject(forKey: "claude.fableSkipUntil")
    }

    // Quota probe (fallback while the usage endpoint is blocked). Persisted so relaunches respect the interval.
    private var probe: ClaudeProvider.LiveReading? = UserDefaults.standard.data(forKey: "claude.probe")
        .flatMap { try? JSONDecoder().decode(ClaudeProvider.LiveReading.self, from: $0) }
    private var probeAttempt: Date? = UserDefaults.standard.object(forKey: "claude.probeAttemptAt") as? Date

    var lastProbe: ClaudeProvider.LiveReading? { get async { sync { probe } } }

    /// Set when a Fable probe can't help (no Fable limit on this account, or no access to the model).
    private var fableSkip: Date? = UserDefaults.standard.object(forKey: "claude.fableSkipUntil") as? Date
    var fableSkippedUntil: Date? { get async { sync { fableSkip } } }
    func skipFable(for seconds: TimeInterval) async {
        let until = Date.now.addingTimeInterval(seconds)
        sync { fableSkip = until }
        UserDefaults.standard.set(until, forKey: "claude.fableSkipUntil")
    }

    /// True (and records the attempt) when no probe was sent within `interval`.
    func claimProbeSlot(interval: TimeInterval) async -> Bool {
        let ok = sync { () -> Bool in
            if let last = probeAttempt, Date.now.timeIntervalSince(last) < interval, last <= .now { return false }
            probeAttempt = .now
            return true
        }
        if ok { UserDefaults.standard.set(Date.now, forKey: "claude.probeAttemptAt") }
        return ok
    }

    func storeProbe(_ r: ClaudeProvider.LiveReading) async {
        sync { probe = r }
        if let d = try? JSONEncoder().encode(r) { UserDefaults.standard.set(d, forKey: "claude.probe") }
    }

    func version(for cmd: String) async -> String? {
        sync {
            guard let v = versions[cmd], Date.now.timeIntervalSince(v.1) < 3600 else { return nil }
            return v.0
        }
    }
    func setVersion(_ v: String, for cmd: String) async { sync { versions[cmd] = (v, .now) } }
}
