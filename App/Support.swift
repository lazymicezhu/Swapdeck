import Foundation
import Darwin

/// App data in ~/Library/Application Support/QieHao.
enum Disk {
    static var base: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QieHao", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func url(_ name: String) -> URL { base.appendingPathComponent(name) }
    static func read<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let data = try? Data(contentsOf: url(name)) else { return nil }
        return try? JSONDecoder.iso.decode(type, from: data)
    }
    static func write<T: Encodable>(_ value: T, _ name: String) {
        guard let data = try? JSONEncoder.iso.encode(value) else { return }
        try? data.write(to: url(name), options: .atomic)
    }
    static func remove(_ name: String) { try? FileManager.default.removeItem(at: url(name)) }
}

extension JSONDecoder {
    static let iso: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}
extension JSONEncoder {
    static let iso: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
}

/// Keys and logins, in one JSON file readable only by this user (no Keychain, so the app can be shared and
/// rebuilt without password prompts). Same record shape as 余量's credential file, so it can be imported.
enum Secrets {
    private struct Record: Codable {
        var values: [String: String] = [:]
        var migrated: Set<String> = []
        var unavailable: Set<String> = []
    }
    enum Failure: Error { case fileAccess }

    static var directory: URL { Disk.base.appendingPathComponent("Secrets", isDirectory: true) }
    private static var file: URL { directory.appendingPathComponent("credentials.json") }
    private static var cached: Record?

    static func get(_ account: String) -> String? { (try? load())?.values[account] }

    static func set(_ value: String?, for account: String) throws { try set([account: value]) }

    static func set(_ values: [String: String?]) throws {
        var record = try load()
        for (account, value) in values { record.values[account] = value.flatMap { $0.isEmpty ? nil : $0 } }
        try commit(record)
    }

    private static func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard chmod(directory.path, 0o700) == 0 else { throw Failure.fileAccess }
    }

    private static func load() throws -> Record {
        if let cached { return cached }
        try prepare()
        guard let data = try? Data(contentsOf: file) else { cached = Record(); return cached! }
        let record = (try? JSONDecoder().decode(Record.self, from: data)) ?? Record()
        cached = record
        return record
    }

    private static func commit(_ record: Record) throws {
        try prepare()
        let data = try JSONEncoder().encode(record)
        let temporary = directory.appendingPathComponent(".credentials-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw Failure.fileAccess
        }
        guard rename(temporary.path, file.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary); throw Failure.fileAccess
        }
        cached = record
    }
}

/// API endpoints as users type them.
enum Endpoint {
    /// Accepts `example.com`, `https://example.com/`, `…/v1`, `…/v1/messages` or `…/v1/usage`; returns
    /// https://host[/prefix]. HTTPS only, except plain HTTP to this Mac (local proxies).
    static func root(from input: String) -> URL? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "https://" + s }
        guard var parts = URLComponents(string: s), let host = parts.host?.lowercased(), !host.isEmpty else { return nil }
        let scheme = parts.scheme?.lowercased()
        let local = ["localhost", "127.0.0.1", "::1"].contains(host)
        guard scheme == "https" || (scheme == "http" && local) else { return nil }
        parts.query = nil; parts.fragment = nil; parts.user = nil; parts.password = nil
        var path = parts.path
        while path.hasSuffix("/") { path.removeLast() }
        for suffix in ["/v1/messages", "/v1/responses", "/v1/usage", "/v1"] where path.hasSuffix(suffix) {
            path.removeLast(suffix.count); break
        }
        while path.hasSuffix("/") { path.removeLast() }
        parts.path = path
        return parts.url
    }

    static func sameRoot(_ a: String?, _ b: String?) -> Bool {
        guard let a = a.flatMap(root(from:)), let b = b.flatMap(root(from:)) else { return false }
        return a.absoluteString.lowercased() == b.absoluteString.lowercased()
    }
}

/// A relay seat's rate-limit windows (sub2api's /v1/usage `subscription`), shown like a ChatGPT account's.
struct RelayQuota: Hashable {
    var plan: String?
    var fiveHour: CodexWindow?
    var week: CodexWindow?
}

/// Remaining balance of a relay key: new-api's /api/usage/token/, else a /v1/usage that reports `balance`.
enum RelayBalance {
    struct Failure: Error { var status: Int?; var message: String }
    struct Reading { var credit: Double; var quota: RelayQuota? }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    static func fetch(root: URL, key: String) async -> Result<Double, Failure> {
        await read(root: root, key: key).map(\.credit)
    }

    /// The balance plus, when the relay reports them, its 5-hour and weekly windows (from the same request).
    static func read(root: URL, key: String) async -> Result<Reading, Failure> {
        let newAPI = await getJSON(root.appendingPathComponent("api/usage/token/"), key: key)
        if case .success(let object) = newAPI, let data = object["data"] as? [String: Any], data["object"] as? String == "token_usage" {
            let account = number((data["user_quota"] as? [String: Any])?["total_available"])
            let own = number(data["total_available"])
            let available = (data["unlimited_quota"] as? Bool ?? false) ? (account ?? own) : (own ?? account)
            if let available { return .success(Reading(credit: available / 500_000)) }
        }
        if case .failure(let failure) = newAPI, failure.status == 401 || failure.status == 403 { return .failure(failure) }
        switch await getJSON(root.appendingPathComponent("v1/usage"), key: key) {
        case .success(let object):
            if let balance = number(object["balance"]) ?? number(object["remaining"]) {
                return .success(Reading(credit: balance, quota: quota(object)))
            }
            return .failure(Failure(status: 404, message: "无余额接口"))
        case .failure(let failure):
            return .failure(failure.status == 404 || failure.status == nil && failure.message == "无余额接口"
                            ? Failure(status: 404, message: "无余额接口") : failure)
        }
    }

    private static func getJSON(_ url: URL, key: String) async -> Result<[String: Any], Failure> {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch {
            return .failure(Failure(message: (error as? URLError)?.code == .timedOut ? "请求超时" : "网络请求失败"))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = status == 401 || status == 403 ? "Key 无效或无权限" : status == 429 ? "请求过于频繁" : status == 404 ? "无余额接口" : "HTTP \(status)"
            return .failure(Failure(status: status, message: message))
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(Failure(status: 404, message: "无余额接口"))
        }
        return .success(object)
    }

    private static func quota(_ object: [String: Any]) -> RelayQuota? {
        guard let sub = object["subscription"] as? [String: Any] else { return nil }
        let five = window(sub, "five_hour", seconds: 5 * 3600)
        let week = window(sub, "weekly", seconds: 7 * 86400)
        guard five != nil || week != nil else { return nil }
        let plan = (object["planName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return RelayQuota(plan: plan, fiveHour: five, week: week)
    }

    /// A window starts with its first request and resets `seconds` later. Not started, or already past its end, it is
    /// full and has no reset time yet (distantPast, so no countdown shows).
    private static func window(_ sub: [String: Any], _ prefix: String, seconds: Double) -> CodexWindow? {
        guard let limit = number(sub["\(prefix)_limit_usd"]), limit > 0 else { return nil }
        let used = number(sub["\(prefix)_usage_usd"]) ?? 0
        if let start = date(sub["\(prefix)_window_start"]), start.addingTimeInterval(seconds) > Date() {
            return CodexWindow(usedPercent: min(100, max(0, used / limit * 100)), seconds: seconds, resetAt: start.addingTimeInterval(seconds),
                               leftUSD: max(0, limit - used))
        }
        return CodexWindow(usedPercent: 0, seconds: seconds, resetAt: .distantPast, leftUSD: limit)
    }

    /// 2026-11-19T23:02:36.363519+08:00 (any number of fraction digits, or none).
    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let plain = text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: plain)
    }

    private static func number(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String { return Double(s) }
        return nil
    }
}

enum Fmt {
    static func yuan(_ value: Double?, _ digits: Int) -> String {
        guard let value else { return "—" }
        return "¥" + value.formatted(.number.precision(.fractionLength(digits)).grouping(.automatic))
    }
    /// Cut to cents, not rounded, so it never shows more than there is.
    static func usd(_ value: Double) -> String {
        "$" + ((value * 100).rounded(.down) / 100).formatted(.number.precision(.fractionLength(2)).grouping(.automatic))
    }
    /// Cut, not rounded, so a balance never shows more than there is.
    static func yuanDown(_ value: Double?, _ digits: Int) -> String {
        let scale = pow(10, Double(digits))
        return yuan(value.map { ($0 * scale).rounded(.down) / scale }, digits)
    }
    static func time(_ date: Date?) -> String {
        guard let date else { return "未更新" }
        return date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
    }
}
