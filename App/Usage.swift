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

/// Where each relay's spend per day comes from, best first:
/// 1. `/v1/usage?days=30` (zzq.si and similar) reports cost per day.
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
    static func fetch(root: URL, key: String, accessToken: String?, userID: inout Int?) async -> [String: Double]? {
        var usage = URLComponents(url: root.appendingPathComponent("v1/usage"), resolvingAgainstBaseURL: false)!
        usage.queryItems = [URLQueryItem(name: "days", value: "30")]
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
        var data = URLComponents(url: root.appendingPathComponent("api/data/self"), resolvingAgainstBaseURL: false)!
        data.queryItems = [URLQueryItem(name: "start_timestamp", value: String(now - 31 * 86400)),
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
        "gpt-6-astra": Rates(input: 10, cached: 1, output: 50, long: (20, 2, 75)),
        "gpt-6.1-sol": Rates(input: 2, cached: 0.1, output: 10, long: (4, 0.2, 15)),
        "gpt-6.1-terra": Rates(input: 1, cached: 0.05, output: 5, long: nil),
        "gpt-6-sol": Rates(input: 2, cached: 0.2, output: 10, long: (4, 0.4, 15)),
        "gpt-6-luna": Rates(input: 0.1, cached: 0.01, output: 0.5, long: (0.2, 0.02, 0.75)),
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
        if ultrafast, base == "gpt-6-astra" { usd *= 6 } else if fast || ultrafast { usd *= 2 }
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
    }
    struct Cache: Codable { var version = 3; var files: [String: FileProgress] = [:] }

    /// account id → day → USD.
    static func scan(signedIn: String?) -> [String: [String: Double]] {
        let home = CodexFiles.home
        var cache = Disk.read(Cache.self, "codex-usage-v3.json") ?? Cache()
        let accounts = stateDB(home).map(threadAccounts(db:)) ?? [:]
        let since = Date().addingTimeInterval(-32 * 86400)
        var result: [String: [String: Double]] = [:]
        var seenRelative = Set<String>()
        var live = Set<String>()
        for folder in ["sessions", "archived_sessions"] {
            let root = home.appendingPathComponent(folder, isDirectory: true)
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { continue }
            for case let url as URL in walker where url.pathExtension == "jsonl" {
                // The same relative path in both folders: the active sessions/ copy wins.
                let relative = String(url.path.dropFirst(root.path.count))
                guard seenRelative.insert(relative).inserted else { continue }
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                guard let modified = values?.contentModificationDate, modified >= since else { continue }
                let size = values?.fileSize ?? 0
                var progress = cache.files[url.path] ?? FileProgress()
                if size < progress.offset { progress = FileProgress() }
                if size > progress.offset { read(url.path, into: &progress) }
                progress.size = size
                cache.files[url.path] = progress
                live.insert(url.path)
                guard let account = accounts[url.path] ?? signedIn else { continue }
                for (day, usd) in progress.days { result[account, default: [:]][day, default: 0] += usd }
            }
        }
        cache.files = cache.files.filter { live.contains($0.key) }
        Disk.write(cache, "codex-usage-v3.json")
        for old in ["codex-usage-v2.json", "codex-token-usage.json"] { Disk.remove(old) }
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
        guard let data = try? handle.readToEnd(), let end = data.lastIndex(of: UInt8(ascii: "\n")) else { return }
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
                guard let usd = cost(model: model, at: when, input: usage.input, cached: usage.cached, output: usage.output,
                                     fast: p.fast, ultrafast: p.ultrafast) else { continue }
                if usd > 0 { p.days[UsageStore.dayKey(when), default: 0] += usd }
            default:
                break
            }
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
    private var scanning = false

    private init() { trails = Disk.read([UUID: BalanceTrail].self, "balance-trails.json") ?? [:] }

    nonisolated static func dayKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    func series(relay id: UUID, ratio: Double) -> UsageSeries? {
        UsageSeries(byDay[id] ?? trails[id]?.days ?? [:], unit: .yuan, scale: ratio)
    }

    /// A ChatGPT account's use at OpenAI's API rates, in US dollars.
    func series(account: String?) -> UsageSeries? {
        account.flatMap { accountTokens[$0] }.flatMap { UsageSeries($0, unit: .usd) }
    }

    /// Per-day report for a relay; falls back to the balance trail when there is none.
    func refreshRelay(_ id: UUID, root: URL, key: String, accessToken: String?) async {
        var user = userIDs[id]
        let days = await RelayUsage.fetch(root: root, key: key, accessToken: accessToken, userID: &user)
        userIDs[id] = user
        // A failed fetch keeps the last report rather than flashing the balance trail.
        if let days { byDay[id] = days }
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
        let cutoff = Self.dayKey(Date().addingTimeInterval(-32 * 86400))
        trail.days = trail.days.filter { $0.key >= cutoff }
        trails[id] = trail
        Disk.write(trails, "balance-trails.json")
    }

    func refreshAccounts() async {
        guard !scanning else { return }
        scanning = true
        // Files with no thread record count for the account signed in to Codex now.
        let signedIn = CodexFiles.authData().flatMap(CodexLogin.init(data:))?.accountID
        accountTokens = await Task.detached(priority: .utility) { CodexTokenUsage.scan(signedIn: signedIn) }.value
        scanning = false
    }
}
