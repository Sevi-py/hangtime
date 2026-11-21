import Foundation

/// Fallback history source: parses the CLIs' own session logs.
/// Files are append-only, so we remember how far we got in each file and only parse new bytes.
actor LocalLogHistory {
    static let shared = LocalLogHistory()

    struct Entry: Codable {
        var h: UInt64?          // dedupe hash (Claude: message.id + requestId)
        var day: String
        var model: String
        var i: Int, o: Int, cr: Int, cw: Int
        var cost: Double?       // when the log provides an exact cost (Grok)
        var w1: Int?            // part of `cw` written with the 1h cache TTL (Claude)
    }

    struct FileRecord: Codable {
        var provider: ProviderID
        var offset: Int
        var mtime: Double
        var entries: [Entry]
        var lastModel: String?
        var lastTotal: [Int]?   // Codex cumulative counters
    }

    private var cache: [String: FileRecord] = [:]
    private var loaded = false

    private static var cacheURL: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("app.headroom", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("log-history-v2.json")
    }

    private func loadCache() {
        guard !loaded else { return }
        loaded = true
        if let d = try? Data(contentsOf: Self.cacheURL),
           let c = try? JSONDecoder().decode([String: FileRecord].self, from: d) {
            cache = c
        }
    }

    private func saveCache() {
        if let d = try? JSONEncoder().encode(cache) { try? d.write(to: Self.cacheURL, options: .atomic) }
    }

    // MARK: Roots

    static func roots(for p: ProviderID) -> [(URL, String)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let env = ProcessInfo.processInfo.environment
        switch p {
        case .claude:
            var dirs = [ClaudeProvider.configDir.appendingPathComponent("projects")]
            let def = home.appendingPathComponent(".claude/projects")
            if !dirs.contains(def) { dirs.append(def) }
            return dirs.map { ($0, ".jsonl") }
        case .codex:
            let codexHome = env["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex")
            return [(codexHome.appendingPathComponent("sessions"), ".jsonl"),
                    (codexHome.appendingPathComponent("archived_sessions"), ".jsonl")]
        case .grok:
            return [(GrokProvider.home.appendingPathComponent("sessions"), "updates.jsonl")]
        }
    }

    // MARK: Load

    func load(providers: [ProviderID], sinceDays: Int = 366) async -> [DailyUsage] {
        loadCache()
        let cutoff = Date.now.addingTimeInterval(-Double(sinceDays) * 86400)
        var seenPaths = Set<String>()
        var work: [(String, ProviderID, Double, Int)] = []

        for p in providers {
            for (root, suffix) in Self.roots(for: p) {
                for (url, mtime, size) in Self.listFiles(root: root, suffix: suffix, cutoff: cutoff) {
                    let path = url.path
                    seenPaths.insert(path)
                    if let rec = cache[path], rec.offset == size, rec.mtime == mtime.timeIntervalSince1970 { continue }
                    work.append((path, p, mtime.timeIntervalSince1970, size))
                }
            }
        }

        // Parse changed files concurrently.
        let snapshot = cache
        let results = await withTaskGroup(of: (String, FileRecord?).self) { group in
            var it = work.makeIterator()
            var out: [(String, FileRecord?)] = []
            func addNext() -> Bool {
                guard let (path, p, mtime, size) = it.next() else { return false }
                let prev = snapshot[path]
                group.addTask { (path, Self.parse(path: path, provider: p, mtime: mtime, size: size, previous: prev)) }
                return true
            }
            for _ in 0..<8 { if !addNext() { break } }
            while let r = await group.next() {
                out.append(r)
                _ = addNext()
            }
            return out
        }
        for (path, rec) in results { cache[path] = rec }
        // Forget deleted files.
        for key in cache.keys where !seenPaths.contains(key) && providers.contains(cache[key]!.provider) {
            cache.removeValue(forKey: key)
        }
        if !results.isEmpty { saveCache() }

        // Aggregate with cross-file dedupe.
        var seen = Set<UInt64>()
        var agg: [String: DailyUsage] = [:]
        var costMissing: [String: Bool] = [:]
        var oneHour: [String: Int] = [:]
        for rec in cache.values where providers.contains(rec.provider) {
            for e in rec.entries {
                if let h = e.h { if seen.contains(h) { continue }; seen.insert(h) }
                let key = "\(e.day)|\(rec.provider.rawValue)|\(e.model)"
                var d = agg[key] ?? DailyUsage(day: e.day, provider: rec.provider, model: e.model)
                d.inputTokens += e.i
                d.outputTokens += e.o
                d.cacheReadTokens += e.cr
                d.cacheWriteTokens += e.cw
                if let c = e.cost { d.costUSD = (d.costUSD ?? 0) + c } else { costMissing[key] = true }
                if let w1 = e.w1 { oneHour[key, default: 0] += w1 }
                agg[key] = d
            }
        }
        // Price entries without an exact cost.
        for (key, var d) in agg where costMissing[key] == true {
            let c = await Pricing.shared.cost(model: d.model, input: d.inputTokens, output: d.outputTokens,
                                              cacheRead: d.cacheReadTokens, cacheWrite: d.cacheWriteTokens,
                                              cacheWrite1h: oneHour[key] ?? 0)
            if let c { d.costUSD = c + (d.costUSD ?? 0) }
            agg[key] = d
        }
        return Array(agg.values)
    }

    private static func listFiles(root: URL, suffix: String, cutoff: Date) -> [(URL, Date, Int)] {
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                                                      options: [.skipsHiddenFiles]) else { return [] }
        var out: [(URL, Date, Int)] = []
        while let url = en.nextObject() as? URL {
            guard url.lastPathComponent.hasSuffix(suffix) else { continue }
            let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let mtime = vals?.contentModificationDate ?? .distantPast
            guard mtime > cutoff else { continue }
            out.append((url, mtime, vals?.fileSize ?? 0))
        }
        return out
    }

    // MARK: Parsing

    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func day(_ v: Any?) -> String? {
        if let s = v as? String {
            if let d = iso.date(from: s) ?? JSON.date(s) { return DayFormatter.string(from: d) }
            return nil
        }
        return JSON.date(v).map { DayFormatter.string(from: $0) }
    }

    private static func fnv(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }

    static func parse(path: String, provider: ProviderID, mtime: Double, size: Int, previous: FileRecord?) -> FileRecord? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) else { return previous }
        var rec: FileRecord
        if let previous, previous.offset <= data.count, previous.provider == provider {
            rec = previous
        } else {
            rec = FileRecord(provider: provider, offset: 0, mtime: mtime, entries: [])
        }
        let needle: [UInt8]
        switch provider {
        case .claude: needle = Array(#""usage""#.utf8)
        case .codex: needle = Array(#""type":""#.utf8)
        case .grok: needle = Array("turn_completed".utf8)
        }

        var lastNewline = rec.offset
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard let base = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var start = rec.offset
            let end = buf.count
            while start < end {
                guard let nlPtr = memchr(base + start, 0x0A, end - start) else { break }
                let nl = UnsafeRawPointer(nlPtr).assumingMemoryBound(to: UInt8.self) - base
                let len = nl - start
                if len > 20, contains(base + start, len, needle) {
                    let line = Data(bytes: base + start, count: len)
                    handle(line: line, provider: provider, rec: &rec)
                }
                start = nl + 1
                lastNewline = start
            }
        }
        rec.offset = lastNewline
        rec.mtime = mtime
        _ = size
        return rec
    }

    private static func contains(_ p: UnsafePointer<UInt8>, _ len: Int, _ needle: [UInt8]) -> Bool {
        guard len >= needle.count else { return false }
        return needle.withUnsafeBufferPointer { n in
            memmem(p, len, n.baseAddress, n.count) != nil
        }
    }

    private static func handle(line: Data, provider: ProviderID, rec: inout FileRecord) {
        guard let o = JSON.object(line) else { return }
        switch provider {
        case .claude:
            guard JSON.string(o["type"]) == "assistant", let msg = o["message"] as? [String: Any],
                  let u = msg["usage"] as? [String: Any], let day = day(o["timestamp"]) else { return }
            let model = JSON.string(msg["model"]) ?? "unknown"
            if model == "<synthetic>" { return }
            let i = JSON.int(u["input_tokens"]) ?? 0, out = JSON.int(u["output_tokens"]) ?? 0
            let cr = JSON.int(u["cache_read_input_tokens"]) ?? 0, cw = JSON.int(u["cache_creation_input_tokens"]) ?? 0
            if i + out + cr + cw == 0 { return }
            let idKey = "\(JSON.string(msg["id"]) ?? "")|\(JSON.string(o["requestId"]) ?? JSON.string(o["uuid"]) ?? "")"
            let w1 = JSON.int((u["cache_creation"] as? [String: Any])?["ephemeral_1h_input_tokens"])
            rec.entries.append(Entry(h: fnv(idKey), day: day, model: model, i: i, o: out, cr: cr, cw: cw, cost: nil, w1: w1))

        case .codex:
            let payload = o["payload"] as? [String: Any]
            let type = JSON.string(o["type"])
            if type == "turn_context" {
                rec.lastModel = JSON.string(payload?["model"]) ?? rec.lastModel
                return
            }
            if type == "session_meta", rec.lastModel == nil {
                rec.lastModel = JSON.string(payload?["model"])
            }
            guard type == "event_msg", JSON.string(payload?["type"]) == "token_count",
                  let info = payload?["info"] as? [String: Any], let day = day(o["timestamp"]) else { return }
            func vec(_ u: [String: Any]?) -> [Int]? {
                guard let u else { return nil }
                return [JSON.int(u["input_tokens"]) ?? 0, JSON.int(u["cached_input_tokens"]) ?? 0,
                        JSON.int(u["output_tokens"]) ?? 0, JSON.int(u["cache_write_input_tokens"]) ?? 0]
            }
            let total = vec(info["total_token_usage"] as? [String: Any])
            var delta: [Int]
            if let total, let last = rec.lastTotal, zip(total, last).allSatisfy({ $0 >= $1 }) {
                delta = zip(total, last).map { $0 - $1 }
            } else if let total, rec.lastTotal == nil {
                delta = total
            } else {
                delta = vec(info["last_token_usage"] as? [String: Any]) ?? [0, 0, 0, 0]
            }
            if let total { rec.lastTotal = total }
            if delta.allSatisfy({ $0 == 0 }) { return }
            let cached = min(delta[1], delta[0])
            appendAggregated(&rec, day: day, model: rec.lastModel ?? "gpt-5",
                             i: delta[0] - cached, o: delta[2], cr: cached, cw: delta[3], cost: nil)

        case .grok:
            guard let params = o["params"] as? [String: Any], let up = params["update"] as? [String: Any],
                  JSON.string(up["sessionUpdate"]) == "turn_completed", let u = up["usage"] as? [String: Any],
                  let day = day(o["timestamp"]) else { return }
            let perModel = (u["modelUsage"] as? [String: Any]) ?? ["grok": u]
            for (model, mu) in perModel {
                guard let m = mu as? [String: Any] else { continue }
                let input = JSON.int(m["inputTokens"]) ?? 0
                let cr = JSON.int(m["cachedReadTokens"]) ?? 0
                let cost = JSON.double(m["costUsdTicks"]).map { $0 / 1e10 }
                appendAggregated(&rec, day: day, model: model, i: max(0, input - cr), o: JSON.int(m["outputTokens"]) ?? 0,
                                 cr: cr, cw: JSON.int(m["cacheCreationTokens"]) ?? 0, cost: cost)
            }
        }
    }

    /// For sources without per-message ids we keep one entry per (day, model) per file.
    private static func appendAggregated(_ rec: inout FileRecord, day: String, model: String,
                                         i: Int, o: Int, cr: Int, cw: Int, cost: Double?) {
        if let idx = rec.entries.lastIndex(where: { $0.day == day && $0.model == model }) {
            rec.entries[idx].i += i
            rec.entries[idx].o += o
            rec.entries[idx].cr += cr
            rec.entries[idx].cw += cw
            if let cost { rec.entries[idx].cost = (rec.entries[idx].cost ?? 0) + cost }
        } else {
            rec.entries.append(Entry(h: nil, day: day, model: model, i: i, o: o, cr: cr, cw: cw, cost: cost, w1: nil))
        }
    }
}

enum HistoryLoader {
    static func load(preference: HistorySourcePreference, providers: [ProviderID],
                     commands: [ProviderID: String]) async -> UsageHistory {
        if preference != .cliLogs, T3CodeHistory.isInstalled {
            do {
                let days = try await T3CodeHistory.load()
                return UsageHistory(days: days.filter { providers.contains($0.provider) }, source: .t3code)
            } catch {
                if preference == .t3code {
                    NSLog("Headroom: T3 Code history unavailable: \(error.localizedDescription)")
                }
            }
        }
        let days = await LocalLogHistory.shared.load(providers: providers)
        return UsageHistory(days: days, source: .cliLogs)
    }
}
