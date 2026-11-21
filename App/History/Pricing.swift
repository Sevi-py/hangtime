import Foundation

/// API-equivalent token prices (USD per token). Uses LiteLLM's public price list (the same source
/// T3 Code and ccusage use), preferring T3 Code's cached copy, then our own cache, then a download.
actor Pricing {
    static let shared = Pricing()

    struct Rate: Sendable {
        var input: Double
        var output: Double
        var cacheRead: Double?
        var cacheWrite: Double?
        var cacheWrite1h: Double?
    }

    private var table: [String: Rate] = [:]
    private var bareTable: [String: Rate] = [:]
    private var loaded = false
    private var memo: [String: Rate?] = [:]

    private static let remote = URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!

    private static var cacheURL: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("app.headroom", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("model-prices.json")
    }

    private func ensureLoaded() async {
        guard !loaded else { return }
        loaded = true
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [home.appendingPathComponent(".t3/userdata/usage-model-rates.json"), Self.cacheURL]
        var data: Data?
        for url in candidates {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let mod = attrs[.modificationDate] as? Date, Date.now.timeIntervalSince(mod) < 7 * 86400,
               let d = try? Data(contentsOf: url) {
                data = d
                break
            }
        }
        if data == nil, let (d, resp) = try? await URLSession.shared.data(from: Self.remote),
           (resp as? HTTPURLResponse)?.statusCode == 200 {
            try? d.write(to: Self.cacheURL)
            data = d
        }
        if data == nil {
            data = candidates.lazy.compactMap { try? Data(contentsOf: $0) }.first
        }
        guard let data, var obj = JSON.object(data) else { return }
        // T3 Code wraps the LiteLLM table: {"document": {...} | "<json>", "fetchedAtMs": …}
        if let inner = obj["document"] as? [String: Any] { obj = inner }
        else if let str = obj["document"] as? String, let inner = JSON.object(str) { obj = inner }
        else if let inner = obj["rates"] as? [String: Any] ?? obj["models"] as? [String: Any] { obj = inner }
        var bareKeyLength: [String: Int] = [:]
        for (k, v) in obj {
            guard let m = v as? [String: Any], let i = JSON.double(m["input_cost_per_token"]),
                  let o = JSON.double(m["output_cost_per_token"]) else { continue }
            let rate = Rate(input: i, output: o,
                            cacheRead: JSON.double(m["cache_read_input_token_cost"]),
                            cacheWrite: JSON.double(m["cache_creation_input_token_cost"]),
                            cacheWrite1h: JSON.double(m["cache_creation_input_token_cost_above_1hr"]))
            let key = k.lowercased()
            table[key] = rate
            // Index by bare model name too ("azure/gpt-6.1-sol", "us.anthropic.claude-opus-5-5" → "gpt-6.1-sol", …),
            // preferring the shortest original key (usually the first-party listing).
            var bare = String(key.split(separator: "/").last ?? Substring(key))
            if let r = bare.range(of: #"^([a-z0-9-]+\.)*(anthropic|openai|xai)\."#, options: .regularExpression) {
                bare.removeSubrange(r)
            }
            bare = bare.replacingOccurrences(of: #"(@.*|-v\d+:\d+)$"#, with: "", options: .regularExpression)
            if bare != key, key.count < (bareKeyLength[bare] ?? .max) {
                bareTable[bare] = rate
                bareKeyLength[bare] = key.count
            }
        }
    }

    /// Family fallbacks for brand new models not yet in the price list.
    private static let fallbacks: [(String, Rate)] = [
        ("opus", Rate(input: 5e-6, output: 25e-6, cacheRead: 0.5e-6, cacheWrite: 6.25e-6)),
        ("sonnet", Rate(input: 3e-6, output: 15e-6, cacheRead: 0.3e-6, cacheWrite: 3.75e-6)),
        ("haiku", Rate(input: 1e-6, output: 5e-6, cacheRead: 0.1e-6, cacheWrite: 1.25e-6)),
        ("gpt-5", Rate(input: 1.25e-6, output: 10e-6, cacheRead: 0.125e-6, cacheWrite: nil)),
        ("grok", Rate(input: 3e-6, output: 15e-6, cacheRead: 0.75e-6, cacheWrite: nil)),
    ]

    func rate(for rawModel: String) async -> Rate? {
        await ensureLoaded()
        let model = rawModel.lowercased()
        if let m = memo[model] { return m }
        var candidates = [model]
        // Strip date suffixes like -20251001 and provider prefixes.
        let noDate = model.replacingOccurrences(of: #"-\d{8}$"#, with: "", options: .regularExpression)
        candidates += [noDate, "anthropic/\(noDate)", "openai/\(noDate)", "xai/\(noDate)"]
        // claude-opus-5-5 → claude-opus-5.5
        candidates.append(noDate.replacingOccurrences(of: #"-(\d)-(\d)$"#, with: "-$1.$2", options: .regularExpression))
        var found = candidates.lazy.compactMap { self.table[$0] ?? self.bareTable[$0] }.first
        if found == nil {
            // Longest table key that is a prefix of the model (e.g. gpt-5.5-codex-high → gpt-5.5-codex).
            found = bareTable.filter { noDate.hasPrefix($0.key) && $0.key.count > 4 }.max { $0.key.count < $1.key.count }?.value
        }
        if found == nil {
            found = Self.fallbacks.first { model.contains($0.0) }?.1
        }
        memo[model] = found
        return found
    }

    /// `cacheWrite1h` is the part of `cacheWrite` that used the 1-hour cache TTL (priced higher).
    func cost(model: String?, input: Int, output: Int, cacheRead: Int, cacheWrite: Int, cacheWrite1h: Int = 0) async -> Double? {
        guard let model, let r = await rate(for: model) else { return nil }
        let w5 = r.cacheWrite ?? r.input * 1.25
        let w1 = r.cacheWrite1h ?? r.input * 2
        let oneHour = min(cacheWrite1h, cacheWrite)
        return Double(input) * r.input + Double(output) * r.output
            + Double(cacheRead) * (r.cacheRead ?? r.input * 0.1)
            + Double(cacheWrite - oneHour) * w5 + Double(oneHour) * w1
    }
}
