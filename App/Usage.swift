import Foundation
import Observation
import SQLite3

/// Daily amounts for the last 30 days: spend in yuan for relays, OpenAI API value in US dollars for ChatGPT accounts.
struct UsageSeries: Equatable {
    enum Unit: Equatable { case yuan, usd }
    /// Oldest first; the last value is today.
    var days: [Double]
    var unit: Unit

    var today: Double { days.last ?? 0 }
    var week: Double { days.suffix(7).reduce(0, +) }
    var month: Double { days.reduce(0, +) }

    /// From day keys (yyyy-MM-dd, local) to amounts; nil when there is nothing at all.
    init?(_ byDay: [String: Double], unit: Unit, scale: Double = 1, now: Date = Date()) {
        guard !byDay.isEmpty else { return nil }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        days = (0..<30).reversed().map { offset in
            let day = calendar.date(byAdding: .day, value: -offset, to: start)!
            return (byDay[UsageStore.dayKey(day)] ?? 0) * scale
        }
        self.unit = unit
    }

    func text(_ value: Double) -> String {
        switch unit {
        case .yuan: return Fmt.yuan(value, 2)
        case .usd:
            let digits = value >= 100 ? 0 : 2
            return "$" + value.formatted(.number.precision(.fractionLength(digits)).grouping(.automatic))
        }
    }
}

/// Tokens and list-price dollars for one model on one day, from the local logs (Claude Code or Codex).
/// Input excludes cached input; Codex has no separate cache writes.
struct TokenDay: Codable, Equatable {
    var input = 0.0, output = 0.0, cacheRead = 0.0, cacheWrite = 0.0
    /// List price in US dollars; 0 when the model's price is unknown.
    var usd = 0.0

    static func + (a: TokenDay, b: TokenDay) -> TokenDay {
        TokenDay(input: a.input + b.input, output: a.output + b.output, cacheRead: a.cacheRead + b.cacheRead,
                 cacheWrite: a.cacheWrite + b.cacheWrite, usd: a.usd + b.usd)
    }
    static func += (a: inout TokenDay, b: TokenDay) { a = a + b }
    static func - (a: TokenDay, b: TokenDay) -> TokenDay {
        TokenDay(input: a.input - b.input, output: a.output - b.output, cacheRead: a.cacheRead - b.cacheRead,
                 cacheWrite: a.cacheWrite - b.cacheWrite, usd: a.usd - b.usd)
    }
}

/// day → model → tokens.
typealias ModelDays = [String: [String: TokenDay]]

/// Where each relay's spend per day comes from, best first:
/// 1. `/v1/usage?days=N` (zzq.si and similar) reports cost per day.
/// 2. new-api with a system access token: `/api/data/self` reports charged quota per time bucket.
/// 3. Otherwise the balance itself: falls count as spend, rises as refunds of held amounts (new-api holds an
///    estimate while a request runs), and a rise beyond what was spent that day as a top-up. Starts the day 切号
///    first sees the relay, so there is no history before that.
enum RelayUsage {
    struct Failure: Error { var status: Int? }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    /// Credit per local day, or nil when the relay has no per-day report this app can read.
    /// `days` counts back from today, today included.
    static func fetch(root: URL, key: String, accessToken: String?, userID: inout Int?, days: Int) async -> [String: Double]? {
        var usage = URLComponents(url: root.appendingPathComponent("v1/usage"), resolvingAgainstBaseURL: false)!
        usage.queryItems = [URLQueryItem(name: "days", value: String(days))]
        if let object = await getJSON(usage.url!, headers: ["Authorization": "Bearer \(key)"]),
           let daily = object["daily_usage"] as? [[String: Any]] {
            var out: [String: Double] = [:]
            for row in daily {
                guard let date = row["date"] as? String else { continue }
                out[date] = number(row["actual_cost"]) ?? number(row["cost"]) ?? 0
            }
            return out
        }
        guard let accessToken else { return nil }
        if userID == nil, let log = await getJSON(root.appendingPathComponent("api/log/token"), headers: ["Authorization": "Bearer \(key)"]),
           let rows = log["data"] as? [[String: Any]] ?? (log["data"] as? [String: Any])?["items"] as? [[String: Any]] {
            userID = rows.lazy.compactMap { $0["user_id"] as? Int }.first
        }
        guard let userID else { return nil }
        let now = Int(Date().timeIntervalSince1970)
        let start = Calendar.current.date(byAdding: .day, value: 1 - days, to: Calendar.current.startOfDay(for: Date()))!
        var data = URLComponents(url: root.appendingPathComponent("api/data/self"), resolvingAgainstBaseURL: false)!
        data.queryItems = [URLQueryItem(name: "start_timestamp", value: String(Int(start.timeIntervalSince1970))),
                           URLQueryItem(name: "end_timestamp", value: String(now))]
        for auth in [accessToken, "Bearer \(accessToken)"] {
            guard let object = await getJSON(data.url!, headers: ["Authorization": auth, "New-Api-User": String(userID)]),
                  object["success"] as? Bool != false, let rows = object["data"] as? [[String: Any]] else { continue }
            var out: [String: Double] = [:]
            for row in rows {
                guard let at = number(row["created_at"]), let quota = number(row["quota"]) else { continue }
                out[UsageStore.dayKey(Date(timeIntervalSince1970: at)), default: 0] += quota / 500_000
            }
            return out
        }
        return nil
    }

    private static func getJSON(_ url: URL, headers: [String: String]) async -> [String: Any]? {
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func number(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String { return Double(s) }
        return nil
    }
}

/// ChatGPT accounts' Codex use priced at OpenAI's API rates, per day, in US dollars — the way OpenUsage does it
/// (github.com/robinebers/openusage, Providers/Codex): every rollout under `sessions/` and `archived_sessions/`,
/// one event per `token_count` (`last_token_usage`, else the rise of the running total; an unchanged total is a
/// repeated snapshot), the parent history a fork or subagent replays at start skipped, priced as uncached input +
/// cached input + output with the long-context rate above 272k prompt tokens and the fast / ultrafast tier
/// multipliers. codex-auto-review is free since 2026-10-06; models without a known price are left out.
/// Each file is attributed to the account its thread belongs to (~/.codex/state_5.sqlite), else the signed-in one.
enum CodexTokenUsage {
    struct Rates { var input: Double; var cached: Double; var output: Double; var long: (Double, Double, Double)? }
    /// Per 1M tokens (OpenAI API, as in OpenUsage's catalog and CodexUsagePricing).
    static let rates: [String: Rates] = [
        // GPT-6.2 (2026-11-17): above 272k prompt tokens 2x input and cache, 1.5x output, like the earlier ones.
        "gpt-6.2-astra": Rates(input: 8, cached: 0.4, output: 40, long: (16, 0.8, 60)),
        "gpt-6.2-sol": Rates(input: 2, cached: 0.1, output: 10, long: (4, 0.2, 15)),
        "gpt-6-astra": Rates(input: 10, cached: 1, output: 50, long: (20, 2, 75)),
        "gpt-6.1-sol": Rates(input: 2, cached: 0.1, output: 10, long: (4, 0.2, 15)),
        "gpt-6.1-terra": Rates(input: 1, cached: 0.05, output: 5, long: nil),
        "gpt-6-sol": Rates(input: 2, cached: 0.2, output: 10, long: (4, 0.4, 15)),
        "gpt-6-luna": Rates(input: 0.1, cached: 0.01, output: 0.5, long: (0.2, 0.02, 0.75)),
        // Earlier models, still in old rollouts (list prices; Terra after its 2026-07-30 cut).
        "gpt-5.6-sol": Rates(input: 5, cached: 0.5, output: 30, long: (10, 1, 45)),
        "gpt-5.6-terra": Rates(input: 2, cached: 0.2, output: 12, long: (4, 0.4, 18)),
        "gpt-5.5": Rates(input: 5, cached: 0.5, output: 30, long: (10, 1, 45)),
    ]
    static let autoReviewFreeSince = ISO8601DateFormatter().date(from: "2026-10-06T00:00:00Z")!

    /// Strips a dated snapshot suffix (-2026-11-01 / -20261101).
    static func baseModel(_ model: String) -> String {
        if let r = model.range(of: #"-\d{4}-\d{2}-\d{2}$|-\d{8}$"#, options: .regularExpression) { return String(model[..<r.lowerBound]) }
        return model
    }

    static func cost(model: String, at date: Date, input: Double, cached: Double, output: Double, fast: Bool, ultrafast: Bool) -> Double? {
        if model == "codex-auto-review" { return date >= autoReviewFreeSince ? 0 : nil }
        let base = model == "gpt-reserve" ? "gpt-6-luna" : baseModel(model)
        guard let r = rates[base] else { return nil }
        let cachedIn = min(cached, input), uncached = max(0, input - cachedIn)
        var (i, c, o) = (r.input, r.cached, r.output)
        if let long = r.long, input > 272_000 { (i, c, o) = long }
        var usd = (uncached * i + cachedIn * c + output * o) / 1_000_000
        if ultrafast, base.hasSuffix("-astra") { usd *= 6 } else if fast || ultrafast { usd *= 2 }
        return usd
    }

    struct Totals: Codable, Equatable { var input = 0.0, cached = 0.0, output = 0.0, total = 0.0 }

    struct FileProgress: Codable {
        var size = 0, offset = 0
        var model: String?
        var fast = false, ultrafast = false
        var previous: Totals?
        var sawMeta = false
        /// Child session: replayed parent lines are skipped until a task starting at or after this time.
        var gate: Double?
        var days: [String: Double] = [:]
        var models: ModelDays = [:]
    }
    struct Cache: Codable { var version = 7; var files: [String: FileProgress] = [:] }

    struct Scan { var cost: [String: [String: Double]] = [:]; var models: [String: ModelDays] = [:] }

    /// account id → day → USD, and account id → day → model → tokens.
    static func scan(signedIn: String?) -> Scan {
        let home = CodexFiles.home
        var cache = Disk.read(Cache.self, "codex-usage-v7.json") ?? Cache()
        let accounts = stateDB(home).map(threadAccounts(db:)) ?? [:]
        var result = Scan()
        var live = Set<String>()
        // Codex compresses older rollouts to .jsonl.zst. Each rollout once, by its path without .zst; the active
        // sessions/ copy wins over archived_sessions/, and a plain .jsonl over a compressed one.
        var chosen: [String: URL] = [:]
        var order: [String] = []
        for folder in ["sessions", "archived_sessions"] {
            let root = home.appendingPathComponent(folder, isDirectory: true)
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { continue }
            for case let url as URL in walker {
                let compressed = url.path.hasSuffix(".jsonl.zst")
                guard compressed || url.pathExtension == "jsonl" else { continue }
                let relative = String(url.path.dropFirst(root.path.count).dropLast(compressed ? 4 : 0))
                if let earlier = chosen[relative] {
                    // Only a plain file replaces a compressed one found in the same folder.
                    if !compressed, earlier.path.hasSuffix(".zst"), earlier.deletingLastPathComponent() == url.deletingLastPathComponent() {
                        chosen[relative] = url
                    }
                    continue
                }
                chosen[relative] = url
                order.append(relative)
            }
        }
        for relative in order {
            guard let url = chosen[relative] else { continue }
            let compressed = url.path.hasSuffix(".zst")
            do {
                // Every rollout, however old: 用量's 全部 goes back to the first one. Old ones are read once, then cached.
                let values = try? url.resourceValues(forKeys: [.fileSizeKey])
                let size = values?.fileSize ?? 0
                var progress = cache.files[url.path] ?? FileProgress()
                if compressed {
                    // A compressed rollout no longer grows: read it whole, once.
                    if progress.size != size || progress.offset == 0 {
                        progress = FileProgress()
                        if let data = try? Data(contentsOf: url), let plain = Zstd.decompress(data) { read(data: plain, into: &progress) }
                    }
                } else {
                    if size < progress.offset { progress = FileProgress() }
                    if size > progress.offset { read(url.path, into: &progress) }
                }
                progress.size = size
                cache.files[url.path] = progress
                live.insert(url.path)
                let plainPath = compressed ? String(url.path.dropLast(4)) : url.path
                guard let account = accounts[plainPath] ?? accounts[url.path] ?? signedIn else { continue }
                for (day, usd) in progress.days { result.cost[account, default: [:]][day, default: 0] += usd }
                for (day, models) in progress.models {
                    for (model, tokens) in models { result.models[account, default: [:]][day, default: [:]][model, default: TokenDay()] += tokens }
                }
            }
        }
        cache.files = cache.files.filter { live.contains($0.key) }
        Disk.write(cache, "codex-usage-v7.json")
        for old in ["codex-usage-v5.json", "codex-usage-v4.json", "codex-usage-v3.json", "codex-usage-v2.json", "codex-token-usage.json"] { Disk.remove(old) }
        return result
    }

    /// The newest state_N.sqlite (state_5 now; Codex bumps the number when the schema changes).
    private static func stateDB(_ home: URL) -> String? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        let versions = names.compactMap { name -> (Int, String)? in
            guard name.hasPrefix("state_"), name.hasSuffix(".sqlite"), let n = Int(name.dropFirst(6).dropLast(7)) else { return nil }
            return (n, name)
        }
        return versions.max { $0.0 < $1.0 }.map { home.appendingPathComponent($0.1).path }
    }

    private static func threadAccounts(db path: String) -> [String: String] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); return [:] }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT rollout_path, creator_account_id FROM threads WHERE creator_account_id IS NOT NULL", -1, &statement, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(statement) }
        var out: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let p = sqlite3_column_text(statement, 0), let a = sqlite3_column_text(statement, 1) else { continue }
            out[String(cString: p)] = String(cString: a)
        }
        return out
    }

    private static func number(_ json: [String: Any]?, _ keys: String...) -> Double? {
        for key in keys { if let n = json?[key] as? NSNumber { return n.doubleValue } }
        return nil
    }

    private static func totals(_ json: [String: Any]?) -> Totals? {
        guard let json else { return nil }
        return Totals(input: number(json, "input_tokens", "prompt_tokens", "input") ?? 0,
                      cached: number(json, "cached_input_tokens", "cache_read_input_tokens", "cached_tokens") ?? 0,
                      output: number(json, "output_tokens", "completion_tokens", "output") ?? 0,
                      total: number(json, "total_tokens") ?? 0)
    }

    private static func read(_ path: String, into p: inout FileProgress) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: UInt64(p.offset))
        guard let data = try? handle.readToEnd() else { return }
        read(data: data, into: &p)
    }

    /// Complete lines of `data` (what follows `p.offset` in the rollout); moves the offset past them.
    private static func read(data: Data, into p: inout FileProgress) {
        guard let end = data.lastIndex(of: UInt8(ascii: "\n")) else { return }
        let complete = data[..<end]
        p.offset += complete.count + 1
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        func date(_ raw: Any?) -> Date? { (raw as? String).flatMap { iso.date(from: $0) ?? plain.date(from: $0) } }
        let markers = ["\"turn_context\"", "\"token_count\"", "\"session_meta\"", "\"task_started\"", "\"thread_settings_applied\""].map { Data($0.utf8) }
        for line in complete.split(separator: UInt8(ascii: "\n")) {
            guard markers.contains(where: { line.firstRange(of: $0) != nil }),
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            let type = object["type"] as? String
            let payload = object["payload"] as? [String: Any]
            if type == "turn_context" {
                if let model = (payload?["model"] as? String) ?? (payload?["model_name"] as? String) { p.model = model }
                continue
            }
            if type == "session_meta" {
                guard !p.sawMeta else { continue }
                p.sawMeta = true
                let source = payload?["source"] as? [String: Any]
                let child = payload?["forked_from_id"].map { !($0 is NSNull) } == true
                    || payload?["parent_thread_id"].map { !($0 is NSNull) } == true
                    || payload?["thread_source"] as? String == "subagent"
                    || source?["subagent"].map { !($0 is NSNull) } == true
                if child { p.gate = (date(object["timestamp"])?.timeIntervalSince1970 ?? 0).rounded(.down) }
                continue
            }
            guard type == "event_msg", let payload else { continue }
            switch payload["type"] as? String {
            case "thread_settings_applied":
                let settings = payload["thread_settings"] as? [String: Any]
                if let tier = (settings?["service_tier"] as? String) ?? (payload["service_tier"] as? String), !tier.isEmpty {
                    p.ultrafast = tier == "ultrafast"
                    p.fast = tier == "fast" || tier == "priority"
                }
            case "task_started":
                if let gate = p.gate, let started = payload["started_at"] as? NSNumber, started.doubleValue >= gate { p.gate = nil }
            case "token_count":
                guard let when = date(object["timestamp"]) else { continue }
                let info = payload["info"] as? [String: Any]
                let running = totals(info?["total_token_usage"] as? [String: Any])
                if p.gate != nil { if let running { p.previous = running }; continue }
                if let running, let previous = p.previous, running == previous { continue }
                var usage: Totals
                if let last = totals(info?["last_token_usage"] as? [String: Any]) {
                    usage = last
                } else if let running {
                    let before = p.previous ?? Totals()
                    usage = Totals(input: max(0, running.input - before.input), cached: max(0, running.cached - before.cached),
                                   output: max(0, running.output - before.output), total: max(0, running.total - before.total))
                } else { continue }
                if let running { p.previous = running }
                guard usage.input > 0 || usage.cached > 0 || usage.output > 0 else { continue }
                let model = (payload["model"] as? String) ?? (info?["model"] as? String) ?? p.model ?? "gpt-5"
                p.model = model
                let usd = cost(model: model, at: when, input: usage.input, cached: usage.cached, output: usage.output,
                               fast: p.fast, ultrafast: p.ultrafast)
                let day = UsageStore.dayKey(when)
                let cachedIn = min(usage.cached, usage.input)
                let tokens = TokenDay(input: usage.input - cachedIn, output: usage.output, cacheRead: cachedIn, usd: usd ?? 0)
                let name = baseModel(model)
                p.models[day, default: [:]][name, default: TokenDay()] += tokens
                if let usd, usd > 0 { p.days[day, default: 0] += usd }
            default:
                break
            }
        }
    }
}

/// Claude Code's use per day and model, from its session records (~/.claude/projects, subagents included), priced
/// at Anthropic's list price — the same table as the yuliang-band mod and 余量 (turn-sync.py). Only the share
/// between models is used: the money itself comes from what the relays charged. Read incrementally like Codex's logs;
/// a message streamed over several lines carries the same id, and only its last line counts.
enum ClaudeTokenUsage {
    /// Per 1M tokens: input, output, 5-minute cache write, cache read; a 1-hour cache write is twice the input price.
    static let rates: [String: (Double, Double, Double, Double)] = [
        "claude-fable-5-2": (8, 40, 10, 0.20),
        "claude-fable-5-1": (10, 50, 12.5, 0.25),
        "claude-fable-5": (10, 50, 12.5, 1.0),
        "claude-opus-5-5": (4, 20, 5, 0.20),
        "claude-sonnet-5": (2, 10, 2.5, 0.20),
        "claude-sonnet-5-5": (2, 10, 2.5, 0.20),
        "claude-haiku-5-5": (0.10, 0.50, 0.125, 0.01),
        "claude-haiku-4-5": (1, 5, 1.25, 0.10),
        "claude-haiku-4-5-20251001": (1, 5, 1.25, 0.10),
    ]

    struct FileProgress: Codable {
        var size = 0, offset = 0
        /// The last message counted, so a later line of the same message replaces it instead of adding.
        var lastID: String?
        var lastDay: String?
        var lastModel: String?
        var last: TokenDay?
        var models: ModelDays = [:]
    }
    struct Cache: Codable { var version = 1; var files: [String: FileProgress] = [:] }

    static var root: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true) }

    /// day → model → tokens, for every session Claude Code still keeps.
    static func scan() -> ModelDays {
        var cache = Disk.read(Cache.self, "claude-usage-v1.json") ?? Cache()
        var result: ModelDays = [:]
        if let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                                                       options: [], errorHandler: { _, _ in true }) {
            for case let url as URL in walker where url.pathExtension == "jsonl" {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                var progress = cache.files[url.path] ?? FileProgress()
                if size < progress.offset { progress = FileProgress() }
                if size > progress.offset { read(url.path, into: &progress) }
                progress.size = size
                cache.files[url.path] = progress
            }
        }
        // Claude Code deletes sessions after 30 days; what they used stays here, so 用量's 全部 keeps those days.
        for progress in cache.files.values {
            for (day, models) in progress.models {
                for (model, tokens) in models { result[day, default: [:]][model, default: TokenDay()] += tokens }
            }
        }
        Disk.write(cache, "claude-usage-v1.json")
        return result
    }

    private static func read(_ path: String, into p: inout FileProgress) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: UInt64(p.offset))
        guard let data = try? handle.readToEnd(), let end = data.lastIndex(of: UInt8(ascii: "\n")) else { return }
        let complete = data[..<end]
        p.offset += complete.count + 1
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        let marker = Data("\"usage\"".utf8)
        for line in complete.split(separator: UInt8(ascii: "\n")) {
            guard line.firstRange(of: marker) != nil,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  object["type"] as? String == "assistant",
                  let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  let model = message["model"] as? String, model != "<synthetic>",
                  let stamp = object["timestamp"] as? String,
                  let when = iso.date(from: stamp) ?? plain.date(from: stamp) else { continue }
            func n(_ key: String) -> Double { (usage[key] as? NSNumber)?.doubleValue ?? 0 }
            let write = n("cache_creation_input_tokens")
            let hour = ((usage["cache_creation"] as? [String: Any])?["ephemeral_1h_input_tokens"] as? NSNumber)?.doubleValue ?? 0
            var tokens = TokenDay(input: n("input_tokens"), output: n("output_tokens"), cacheRead: n("cache_read_input_tokens"), cacheWrite: write)
            if let r = rates[model] {
                tokens.usd = (tokens.input * r.0 + tokens.output * r.1 + (write - hour) * r.2 + hour * r.0 * 2 + tokens.cacheRead * r.3) / 1_000_000
            }
            let day = UsageStore.dayKey(when)
            let id = (message["id"] as? String) ?? (object["uuid"] as? String)
            // Same message as the line before: take back what that line added.
            if let id, id == p.lastID, let last = p.last, let lastDay = p.lastDay, let lastModel = p.lastModel {
                p.models[lastDay, default: [:]][lastModel, default: TokenDay()] = (p.models[lastDay]?[lastModel] ?? TokenDay()) - last
            }
            p.models[day, default: [:]][model, default: TokenDay()] += tokens
            p.lastID = id; p.lastDay = day; p.lastModel = model; p.last = tokens
        }
    }
}

/// 30-day usage for every card, refreshed with the balances (every 5 minutes).
@Observable @MainActor
final class UsageStore {
    static let shared = UsageStore()

    /// Relay credit per day (multiply by the relay's ratio for yuan) or account tokens per day, by profile id.
    private(set) var byDay: [UUID: [String: Double]] = [:]
    private var userIDs: [UUID: Int] = [:]
    private struct BalanceTrail: Codable { var last: Double; var days: [String: Double] }
    private var trails: [UUID: BalanceTrail]
    private var accountTokens: [String: [String: Double]] = [:]
    /// Codex account id → day → model → tokens, and Claude Code's day → model → tokens (all relays together).
    private(set) var codexModels: [String: ModelDays] = [:]
    private(set) var claudeModels: ModelDays = [:]
    private var scanning = false
    private var scanningClaude = false

    private init() {
        trails = Disk.read([UUID: BalanceTrail].self, "balance-trails.json") ?? [:]
        byDay = Disk.read([UUID: [String: Double]].self, "relay-days.json") ?? [:]
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    nonisolated static func dayKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    func series(relay id: UUID, ratio: Double) -> UsageSeries? {
        UsageSeries(byDay[id] ?? trails[id]?.days ?? [:], unit: .yuan, scale: ratio)
    }

    /// Every day on record, in yuan (用量's 全部).
    func daily(relay id: UUID, ratio: Double) -> [String: Double] {
        (byDay[id] ?? trails[id]?.days ?? [:]).mapValues { $0 * ratio }
    }

    /// Every day on record of a ChatGPT account, at API rates in US dollars.
    func daily(account: String?) -> [String: Double] {
        account.flatMap { accountTokens[$0] } ?? [:]
    }

    /// A ChatGPT account's use at OpenAI's API rates, in US dollars.
    func series(account: String?) -> UsageSeries? {
        account.flatMap { accountTokens[$0] }.flatMap { UsageSeries($0, unit: .usd) }
    }

    /// Per-day report for a relay; falls back to the balance trail when there is none.
    func refreshRelay(_ id: UUID, root: URL, key: String, accessToken: String?) async {
        var user = userIDs[id]
        // Days already on record don't change: ask only from the newest one on (at least today and yesterday, so
        // the last minutes before midnight are counted), or 30 days the first time.
        let today = Calendar.current.startOfDay(for: Date())
        var span = 30
        if let newest = byDay[id]?.keys.max(), let date = Self.dayFormatter.date(from: newest) {
            let gap = Calendar.current.dateComponents([.day], from: date, to: today).day ?? 30
            span = min(30, max(2, gap + 1))
        }
        let days = await RelayUsage.fetch(root: root, key: key, accessToken: accessToken, userID: &user, days: span)
        userIDs[id] = user
        // A failed fetch keeps the last report rather than flashing the balance trail. Every day reported stays in
        // relay-days.json, so 用量's 全部 keeps days the relay no longer reports.
        guard let days else { return }
        var kept = byDay[id] ?? [:]
        kept.merge(days) { _, new in new }
        guard kept != byDay[id] else { return }
        byDay[id] = kept
        Disk.write(byDay, "relay-days.json")
    }

    /// Every balance reading feeds the trail, used only for relays without a per-day report.
    func recordBalance(_ id: UUID, credit: Double) {
        let today = Self.dayKey(Date())
        var trail = trails[id] ?? BalanceTrail(last: credit, days: [:])
        let change = trail.last - credit
        if change > 0 {
            trail.days[today, default: 0] += change
        } else if change < 0 {
            // A rise gives back held amounts first; anything beyond today's spend is a top-up.
            trail.days[today] = max(0, (trail.days[today] ?? 0) + change)
        }
        trail.last = credit
        trails[id] = trail
        Disk.write(trails, "balance-trails.json")
    }

    func refreshAccounts() async {
        guard !scanning else { return }
        scanning = true
        // Files with no thread record count for the account signed in to Codex now.
        let signedIn = CodexFiles.authData().flatMap(CodexLogin.init(data:))?.accountID
        let scan = await Task.detached(priority: .utility) { CodexTokenUsage.scan(signedIn: signedIn) }.value
        accountTokens = scan.cost
        codexModels = scan.models
        scanning = false
    }

    func refreshClaudeCode() async {
        guard !scanningClaude else { return }
        scanningClaude = true
        claudeModels = await Task.detached(priority: .utility) { ClaudeTokenUsage.scan() }.value
        scanningClaude = false
    }
}

/// zstd decompression for Codex's compressed rollouts, from zstd's own decoder (built into the app by build.command;
/// macOS has no zstd of its own: libarchive hands it to an external zstd program that most Macs lack).
enum Zstd {
    static func decompress(_ data: Data) -> Data? {
        guard let stream = ZSTD_createDStream() else { return nil }
        defer { ZSTD_freeDStream(stream) }
        ZSTD_initDStream(stream)
        let chunk = ZSTD_DStreamOutSize()
        var buffer = [UInt8](repeating: 0, count: chunk)
        var out = Data()
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data? in
            var input = ZSTD_inBuffer(src: raw.baseAddress, size: raw.count, pos: 0)
            while true {
                var failed = false
                let produced = buffer.withUnsafeMutableBytes { dst -> Int in
                    var output = ZSTD_outBuffer(dst: dst.baseAddress, size: chunk, pos: 0)
                    failed = ZSTD_isError(ZSTD_decompressStream(stream, &output, &input)) != 0
                    return output.pos
                }
                if failed { return nil }
                out.append(contentsOf: buffer[0..<produced])
                // All input read and the output buffer not filled: nothing more is coming.
                if input.pos >= input.size && produced < chunk { return out }
            }
        }
    }
}
