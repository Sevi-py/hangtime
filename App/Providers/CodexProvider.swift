import Foundation
import AppKit

/// Codex: talks to the CLI's own `codex app-server` (JSON-RPC over stdio). Using the CLI's
/// protocol instead of private HTTP endpoints means auth refresh, account selection and
/// backend changes are handled by the CLI itself.
struct CodexProvider: UsageProvider {
    let id = ProviderID.codex

    private func open(_ command: String) async throws -> JSONRPCProcess {
        guard let (exe, pre) = await Shell.shared.resolve(command) else { throw ShellError.notFound(command) }
        let rpc = JSONRPCProcess(exe: exe, args: pre + ["app-server"], env: await Shell.shared.environment())
        try rpc.start()
        _ = try await rpc.request("initialize", ["clientInfo": ["name": "headroom", "title": "Headroom", "version": "1.0"]],
                                  timeout: 30)
        rpc.notify("initialized")
        return rpc
    }

    func fetch(command: String) async -> ProviderSnapshot {
        let rpc: JSONRPCProcess
        do { rpc = try await open(command) } catch {
            return ProviderSnapshot(provider: id, status: .error("Couldn't start codex app-server: \(error.localizedDescription)"))
        }
        defer { rpc.stop() }

        var snap = ProviderSnapshot(provider: id, status: .ok)
        // Account
        if let acc = try? await rpc.request("account/read", ["refreshToken": false]) {
            let account = acc["account"] as? [String: Any]
            if account == nil {
                return ProviderSnapshot(provider: id, status: .loggedOut)
            }
            if JSON.string(account?["type"]) == "apiKey" {
                snap.plan = "API key"
                snap.notes.append("Signed in with an API key – subscription limits don't apply.")
                return snap
            }
            snap.plan = JSON.string(account?["planType"])
            snap.account = JSON.string(account?["email"])
            if let ws = JSON.string(account?["workspaceName"]) { snap.notes.append("Workspace: \(ws)") }
        }

        do {
            let r = try await rpc.request("account/rateLimits/read", [:], timeout: 30)
            Self.parseRateLimits(r, into: &snap)
        } catch let e as JSONRPCProcess.RPCError {
            let msg = e.message.lowercased()
            if msg.contains("auth") || msg.contains("login") || msg.contains("401") || msg.contains("not signed") {
                snap.status = .loggedOut
            } else {
                snap.status = .error(e.message)
            }
        } catch {
            snap.status = .error(error.localizedDescription)
        }
        return snap
    }

    static func parseRateLimits(_ r: [String: Any], into snap: inout ProviderSnapshot) {
        var buckets: [(String, [String: Any])] = []
        if let byId = r["rateLimitsByLimitId"] as? [String: Any], !byId.isEmpty {
            // Keep `codex` first, then the rest alphabetically.
            buckets = byId.compactMap { k, v in (v as? [String: Any]).map { (k, $0) } }
                .sorted { ($0.0 == "codex" ? "" : $0.0) < ($1.0 == "codex" ? "" : $1.0) }
        } else if let single = r["rateLimits"] as? [String: Any] {
            buckets = [(JSON.string(single["limitId"]) ?? "codex", single)]
        }

        for (limitId, b) in buckets {
            if snap.plan == nil { snap.plan = JSON.string(b["planType"]) }
            let isMain = limitId == "codex"
            let scope: String? = isMain ? nil : (JSON.string(b["limitName"]) ?? JSON.string(b["normalModelSlug"]) ?? limitId)
            for slot in ["primary", "secondary", "tertiary"] {
                guard let w = b[slot] as? [String: Any], let used = JSON.double(w["usedPercent"]) else { continue }
                let mins = JSON.double(w["windowDurationMins"])
                let duration = mins.map { $0 * 60 }
                let kind: WindowKind
                let base: String
                switch mins ?? (slot == "primary" ? 300 : 10080) {
                case ..<(24 * 60 + 1):
                    kind = isMain ? .session : .model
                    base = mins.map { $0 >= 60 ? "Session (\(Int($0 / 60))h)" : "Session" } ?? "Session"
                case (6 * 24 * 60)...(8 * 24 * 60):
                    kind = isMain ? .weekly : .model
                    base = "Weekly"
                default:
                    kind = isMain ? .other : .model
                    base = mins.map { "\(Fmt.duration($0 * 60, compact: true)) window" } ?? "Limit"
                }
                snap.windows.append(UsageWindow(
                    id: "\(limitId).\(slot)", kind: kind,
                    title: scope.map { "\(base) · \(Self.prettyModel($0))" } ?? base,
                    scope: scope, usedFraction: used / 100,
                    resetsAt: JSON.date(w["resetsAt"]), duration: duration))
            }
            if let ind = b["individualLimit"] as? [String: Any], let rem = JSON.double(ind["remainingPercent"]) {
                snap.windows.append(UsageWindow(id: "\(limitId).spend", kind: .other, title: "Spend limit",
                                                usedFraction: 1 - rem / 100, resetsAt: JSON.date(ind["resetsAt"]),
                                                duration: nil))
            }
            if isMain, let c = b["credits"] as? [String: Any] {
                if JSON.string(c["unlimited"]) == "1" || (c["unlimited"] as? Bool) == true {
                    snap.notes.append("Credits: unlimited")
                } else if let bal = JSON.double(c["balance"]), bal > 0 {
                    snap.notes.append("Credits balance: \(String(format: "%.2f", bal))")
                }
            }
            if isMain, let reached = JSON.string(b["rateLimitReachedType"]), reached != "rate_limit_reached" {
                snap.notes.append(reached.replacingOccurrences(of: "_", with: " ").capitalized)
            }
        }

        if let rc = r["rateLimitResetCredits"] as? [String: Any] {
            snap.bankedResetCount = JSON.int(rc["availableCount"])
            for c in (rc["credits"] as? [[String: Any]]) ?? [] {
                guard let cid = JSON.string(c["id"]) else { continue }
                let status = JSON.string(c["status"]) ?? "available"
                guard status == "available" else { continue }
                snap.bankedResets.append(BankedReset(
                    id: cid,
                    title: JSON.string(c["title"]) ?? "Rate limit reset",
                    detail: JSON.string(c["description"]),
                    grantedAt: JSON.date(c["grantedAt"]),
                    expiresAt: JSON.date(c["expiresAt"]),
                    redeemable: true))
            }
            snap.bankedResets.sort { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
        }
    }

    static func prettyModel(_ slug: String) -> String {
        slug.replacingOccurrences(of: "_", with: "-").split(separator: "-")
            .map { $0.count <= 3 && $0.allSatisfy(\.isLetter) ? $0.uppercased() : $0.capitalized }
            .joined(separator: "-")
    }

    func redeem(reset: BankedReset?, command: String) async throws -> String {
        let rpc = try await open(command)
        defer { rpc.stop() }
        var params: [String: Any] = ["idempotencyKey": UUID().uuidString]
        if let reset { params["creditId"] = reset.id }
        let r = try await rpc.request("account/rateLimitResetCredit/consume", params, timeout: 60)
        switch JSON.string(r["outcome"]) {
        case "reset": return "Your Codex limits were reset."
        case "nothingToReset": return "Nothing to reset right now – no limit window is currently eligible."
        case "noCredit": return "No reset credits are available."
        case "alreadyRedeemed": return "This reset was already redeemed."
        case let other?: return "Codex replied: \(other)"
        case nil: return "Reset requested."
        }
    }

    func login(command: String) async throws {
        let rpc = try await open(command)
        defer { rpc.stop() }
        let completed = AsyncStream<(Bool, String?)> { cont in
            rpc.onNotification = { method, params in
                if method == "account/login/completed" {
                    cont.yield(((params["success"] as? Bool) ?? false, JSON.string(params["error"])))
                    cont.finish()
                }
            }
        }
        let r = try await rpc.request("account/login/start", ["type": "chatgpt"], timeout: 30)
        guard let urlString = JSON.string(r["authUrl"]), let url = URL(string: urlString) else {
            throw ShellError.failed("Codex did not return a login URL.")
        }
        await MainActor.run { _ = NSWorkspace.shared.open(url) }
        let result = await withTaskGroup(of: (Bool, String?)?.self) { group in
            group.addTask { for await v in completed { return v }; return nil }
            group.addTask { try? await Task.sleep(for: .seconds(600)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let result else { throw ShellError.failed("Login timed out.") }
        if !result.0 { throw ShellError.failed(result.1 ?? "Login failed.") }
    }

    func cliVersion(command: String) async -> String? {
        guard let r = try? await Shell.shared.runCLI(command, ["--version"], timeout: 10), r.ok else { return nil }
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "codex-cli ", with: "")
    }

    /// Server-side daily token totals (all machines) — used to complement local logs.
    func accountDailyTokens(command: String) async -> [String: Int] {
        guard let rpc = try? await open(command) else { return [:] }
        defer { rpc.stop() }
        guard let r = try? await rpc.request("account/usage/read", [:], timeout: 30) else { return [:] }
        var out: [String: Int] = [:]
        for b in (r["dailyUsageBuckets"] as? [[String: Any]]) ?? [] {
            if let d = JSON.string(b["startDate"]), let t = JSON.int(b["tokens"]) { out[String(d.prefix(10))] = t }
        }
        return out
    }
}
