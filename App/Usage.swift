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

/// Model prices from LiteLLM's catalog (github.com/BerriAI/litellm, model_prices_and_context_window.json), per
/// token in US dollars: downloaded at most once a day into prices.json, else the copy bundled with the app. Only the
/// gpt-* and claude-* rows are kept, with their token prices (not batch, flex, audio, image and the like).
enum Prices {
    static let source = URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!
    private static let lock = NSLock()
    nonisolated(unsafe) private static var table: [String: [String: Double]]?

    static func row(_ model: String) -> [String: Double]? {
        lock.lock(); defer { lock.unlock() }
        if table == nil { table = load() }
        return table?[model]
    }

    private static func load() -> [String: [String: Double]] {
        for url in [Disk.url("prices.json"), Bundle.main.url(forResource: "prices", withExtension: "json")].compactMap({ $0 }) {
            if let data = try? Data(contentsOf: url),
               let t = try? JSONDecoder().decode([String: [String: Double]].self, from: data), !t.isEmpty { return t }
        }
        return [:]
    }

    static func refresh() async {
        let file = Disk.url("prices.json")
        if let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
           Date().timeIntervalSince(date) < 86_400 { return }
        guard let (data, response) = try? await URLSession.shared.data(from: source),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let all = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let kept = keep(all)
        guard kept.count > 20, let out = try? JSONEncoder().encode(kept) else { return }
        try? out.write(to: file, options: .atomic)
        lock.withLock { table = kept }
    }

    private static let suffixes = ["_cost", "_token", "_tokens", "_priority", "_ultrafast", "_1hr"]
    private static let skipped = ["batch", "flex", "audio", "image", "search", "reasoning", "video", "character", "second", "pixel", "query"]

    private static func keep(_ all: [String: Any]) -> [String: [String: Double]] {
        var out: [String: [String: Double]] = [:]
        for (model, value) in all where !model.contains("/") && (model.hasPrefix("gpt-") || model.hasPrefix("claude-")) {
            guard let fields = value as? [String: Any] else { continue }
            var row: [String: Double] = [:]
            for (field, v) in fields where field.contains("cost") && suffixes.contains(where: field.hasSuffix)
                && !skipped.contains(where: field.contains) {
                guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { continue }
                row[field] = n.doubleValue
            }
            if !row.isEmpty { out[model] = row }
        }
        return out
    }
}

/// ChatGPT accounts' Codex use priced at OpenAI's API rates, per day, in US dollars — the way OpenUsage does it
/// (github.com/robinebers/openusage, Providers/Codex): every rollout under `sessions/` and `archived_sessions/`,
/// one event per `token_count` (`last_token_usage`, else the rise of the running total; an unchanged total is a
/// repeated snapshot), the parent history a fork or subagent replays at start skipped, priced as uncached input +
/// cached input + output at LiteLLM's prices (`Prices`): the long-context rate above 272k prompt tokens and the
/// priority (fast) / ultrafast tier. codex-auto-review is free since 2026-10-06; a model with no price yet waits
/// in `pending` until LiteLLM has one.
/// Each file is attributed to the account its thread belongs to (~/.codex/state_5.sqlite), else the signed-in one.
enum CodexTokenUsage {
    static let autoReviewFreeSince = ISO8601DateFormatter().date(from: "2026-10-06T00:00:00Z")!

    /// Strips a dated snapshot suffix (-2026-11-01 / -20261101).
    static func baseModel(_ model: String) -> String {
        if let r = model.range(of: #"-\d{4}-\d{2}-\d{2}$|-\d{8}$"#, options: .regularExpression) { return String(model[..<r.lowerBound]) }
        return model
    }

    static func cost(model: String, at date: Date, input: Double, cached: Double, output: Double, fast: Bool, ultrafast: Bool,
                     long: Bool? = nil) -> Double? {
        if model == "codex-auto-review" { return date >= autoReviewFreeSince ? 0 : nil }
        let base = model == "gpt-reserve" ? "gpt-6-luna" : baseModel(model)
        guard let row = Prices.row(base) else { return nil }
        let isLong = long ?? (input > 272_000)
        let tier = ultrafast ? "_ultrafast" : fast ? "_priority" : ""
        func rate(_ field: String) -> Double? {
            let size = isLong && row[field + "_above_272k_tokens"] != nil ? "_above_272k_tokens" : ""
            guard let plain = row[field + size] else { return nil }
            if tier.isEmpty { return plain }
            if let exact = row[field + size + tier] { return exact }
            // No price for this tier at this size: the tier's ratio at short context, else priority's, else 2x.
            for t in [tier, "_priority"] { if let a = row[field + t], let b = row[field], b > 0 { return plain * a / b } }
            return plain * 2
        }
        guard let i = rate("input_cost_per_token"), let o = rate("output_cost_per_token") else { return nil }
        let c = rate("cache_read_input_token_cost") ?? i
        let cachedIn = min(cached, input), uncached = max(0, input - cachedIn)
        return uncached * i + cachedIn * c + output * o
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
        /// Tokens of models with no price yet: day → "model|long|tier". Priced (and fixed) once a price is added.
        var pending: [String: [String: Pending]]?
    }
    /// Input here is uncached input only.
    struct Pending: Codable { var input = 0.0, cached = 0.0, output = 0.0 }
    /// A day's dollars are fixed once counted, at the price of the day they were read; a later price change only
    /// touches what comes after. A model priced later is filled in from `pending` — new prices never need a rescan,
    /// so the version only changes when what is read from the rollouts changes.
    struct Cache: Codable { var version = 7; var files: [String: FileProgress] = [:] }

    /// Prices what was waiting for a price, into the file's own days, so it is fixed from now on.
    private static func pricePending(_ p: inout FileProgress) {
        guard var pending = p.pending else { return }
        for (day, keys) in pending {
            guard let date = dayParser.date(from: day + " 12") else { continue }
            for (key, t) in keys {
                let parts = key.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 3,
                      let usd = cost(model: parts[0], at: date, input: t.input + t.cached, cached: t.cached, output: t.output,
                                     fast: parts[2] == "fast", ultrafast: parts[2] == "ultrafast", long: parts[1] == "1") else { continue }
                if usd > 0 { p.days[day, default: 0] += usd }
                p.models[day, default: [:]][baseModel(parts[0]), default: TokenDay()].usd += usd
                pending[day]?[key] = nil
            }
            if pending[day]?.isEmpty == true { pending[day] = nil }
        }
        p.pending = pending.isEmpty ? nil : pending
    }

    /// yyyy-MM-dd at noon, local.
    static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH"
        return f
    }()

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
                pricePending(&progress)
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
                if usd == nil {
                    let tier = p.ultrafast ? "ultrafast" : p.fast ? "fast" : ""
                    let key = "\(model)|\(usage.input > 272_000 ? 1 : 0)|\(tier)"
                    var waiting = p.pending ?? [:]
                    waiting[day, default: [:]][key, default: Pending()].input += usage.input - cachedIn
                    waiting[day, default: [:]][key, default: Pending()].cached += cachedIn
                    waiting[day, default: [:]][key, default: Pending()].output += usage.output
                    p.pending = waiting
                }
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
/// at Anthropic's list price, from LiteLLM's catalog (`Prices`). Only the share
/// between models is used: the money itself comes from what the relays charged. Read incrementally like Codex's logs;
/// a message streamed over several lines carries the same id, and only its last line counts.
enum ClaudeTokenUsage {
    /// Per token, from LiteLLM (`Prices`); a dated id falls back to its model's row.
    struct Rates { var input, output, write, hourWrite, read: Double }
    static func rates(_ model: String) -> Rates? {
        guard let r = Prices.row(model) ?? Prices.row(CodexTokenUsage.baseModel(model)),
              let i = r["input_cost_per_token"], let o = r["output_cost_per_token"] else { return nil }
        return Rates(input: i, output: o, write: r["cache_creation_input_token_cost"] ?? i * 1.25,
                     hourWrite: r["cache_creation_input_token_cost_above_1hr"] ?? i * 2, read: r["cache_read_input_token_cost"] ?? i * 0.1)
    }

    struct FileProgress: Codable {
        var size = 0, offset = 0
        /// The last message counted, so a later line of the same message replaces it instead of adding.
        var lastID: String?
        var lastDay: String?
        var lastModel: String?
        var last: TokenDay?
        var models: ModelDays = [:]
        /// Tokens of models with no price yet (day → model), priced and fixed once a price is added; and the last
        /// message's share of them, so a later line of that message can take it back.
        var pending: [String: [String: Pending]]?
        var lastPending: Pending?
    }
    /// Cache writes split by lifetime: a 1-hour write has its own price.
    struct Pending: Codable {
        var input = 0.0, output = 0.0, cacheRead = 0.0, write = 0.0, hour = 0.0
        static func + (a: Pending, b: Pending) -> Pending {
            Pending(input: a.input + b.input, output: a.output + b.output, cacheRead: a.cacheRead + b.cacheRead, write: a.write + b.write, hour: a.hour + b.hour)
        }
        static func - (a: Pending, b: Pending) -> Pending {
            Pending(input: a.input - b.input, output: a.output - b.output, cacheRead: a.cacheRead - b.cacheRead, write: a.write - b.write, hour: a.hour - b.hour)
        }
        func usd(_ r: Rates) -> Double {
            input * r.input + output * r.output + (write - hour) * r.write + hour * r.hourWrite + cacheRead * r.read
        }
    }
    /// Like Codex's: a day's dollars are fixed at the price they were read at; a model priced later is filled in
    /// from `pending`, with no rescan.
    struct Cache: Codable { var version = 1; var files: [String: FileProgress] = [:] }

    private static func pricePending(_ p: inout FileProgress) {
        guard var pending = p.pending else { return }
        for (day, models) in pending {
            for (model, t) in models {
                guard let r = rates(model) else { continue }
                p.models[day, default: [:]][model, default: TokenDay()].usd += t.usd(r)
                if let last = p.lastPending, day == p.lastDay, model == p.lastModel { p.last?.usd = last.usd(r); p.lastPending = nil }
                pending[day]?[model] = nil
            }
            if pending[day]?.isEmpty == true { pending[day] = nil }
        }
        p.pending = pending.isEmpty ? nil : pending
    }

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
        for key in cache.files.keys where cache.files[key]?.pending != nil { pricePending(&cache.files[key]!) }
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
            let raw = Pending(input: tokens.input, output: tokens.output, cacheRead: tokens.cacheRead, write: write, hour: hour)
            let r = rates(model)
            if let r { tokens.usd = raw.usd(r) }
            let day = UsageStore.dayKey(when)
            let id = (message["id"] as? String) ?? (object["uuid"] as? String)
            // Same message as the line before: take back what that line added.
            if let id, id == p.lastID, let last = p.last, let lastDay = p.lastDay, let lastModel = p.lastModel {
                p.models[lastDay, default: [:]][lastModel, default: TokenDay()] = (p.models[lastDay]?[lastModel] ?? TokenDay()) - last
                if let lastPending = p.lastPending, let waiting = p.pending?[lastDay]?[lastModel] {
                    p.pending?[lastDay]?[lastModel] = waiting - lastPending
                }
            }
            p.models[day, default: [:]][model, default: TokenDay()] += tokens
            if r == nil {
                var waiting = p.pending ?? [:]
                waiting[day, default: [:]][model] = (waiting[day]?[model] ?? Pending()) + raw
                p.pending = waiting
                p.lastPending = raw
            } else {
                p.lastPending = nil
            }
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

    private var pricesFetch: Task<Void, Never>?
    /// Both scans ask; one download serves them.
    private func freshPrices() async {
        if let pricesFetch { return await pricesFetch.value }
        let fetch = Task { await Prices.refresh() }
        pricesFetch = fetch
        await fetch.value
        pricesFetch = nil
    }

    func refreshAccounts() async {
        guard !scanning else { return }
        scanning = true
        // Files with no thread record count for the account signed in to Codex now.
        let signedIn = CodexFiles.authData().flatMap(CodexLogin.init(data:))?.accountID
        await freshPrices()
        let scan = await Task.detached(priority: .utility) { CodexTokenUsage.scan(signedIn: signedIn) }.value
        accountTokens = scan.cost
        codexModels = scan.models
        scanning = false
    }

    func refreshClaudeCode() async {
        guard !scanningClaude else { return }
        scanningClaude = true
        await freshPrices()
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
