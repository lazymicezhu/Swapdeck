import Foundation

/// The Lazymice relay (a sub2api site): friends sign in or sign up here inside 切号, which then opens a key for
/// Codex and reads their usage, so they never need the website. Balance and spend per day come from the key's own
/// /v1/usage like any relay; the account login is only for setting up the key and the request log.
enum Sub2API {
    static let site = URL(string: "https://api.lazymicezhu.com")!
    /// The group keys are opened in, and the name the key gets (reused on later sign-ins).
    static let groupName = "chatgpt"
    static let keyName = "Swapdeck"
    /// The site wants an email; a plain user name (any script) gets this never-deliverable suffix instead.
    static let nameSuffix = "@lm.local"

    /// What the site is sent for what was typed: an email as is, a user name with the suffix.
    static func account(_ typed: String) -> String {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("@") ? trimmed : trimmed + nameSuffix
    }

    /// The other way round, for showing: the user name without the suffix.
    static func shortName(_ account: String) -> String {
        account.lowercased().hasSuffix(nameSuffix) ? String(account.dropLast(nameSuffix.count)) : account
    }

    struct Failure: Error { var status: Int?; var message: String }

    struct Tokens { var access: String; var refresh: String? }

    enum LoginResult { case tokens(Tokens), needsCode(tempToken: String) }

    struct Record: Identifiable, Hashable {
        var id: Int
        var at: Date
        var model: String
        var input: Int
        var output: Int
        var cached: Int
        var cost: Double
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    // MARK: Account

    static func login(email: String, password: String) async -> Result<LoginResult, Failure> {
        switch await call("auth/login", body: ["email": email, "password": password]) {
        case .success(let data):
            if data["requires_2fa"] as? Bool == true, let temp = data["temp_token"] as? String { return .success(.needsCode(tempToken: temp)) }
            return tokens(data).map { .success(.tokens($0)) } ?? .failure(Failure(message: "登录响应无法解析"))
        case .failure(let failure): return .failure(failure)
        }
    }

    static func login2FA(tempToken: String, code: String) async -> Result<Tokens, Failure> {
        await call("auth/login/2fa", body: ["temp_token": tempToken, "totp_code": code]).flatMap(parseTokens)
    }

    static func register(email: String, password: String, invitation: String) async -> Result<Tokens, Failure> {
        await call("auth/register", body: ["email": email, "password": password, "invitation_code": invitation]).flatMap(parseTokens)
    }

    static func refresh(_ refreshToken: String) async -> Result<Tokens, Failure> {
        await call("auth/refresh", body: ["refresh_token": refreshToken]).flatMap(parseTokens)
    }

    private static func parseTokens(_ data: [String: Any]) -> Result<Tokens, Failure> {
        tokens(data).map { .success($0) } ?? .failure(Failure(message: "登录响应无法解析"))
    }

    private static func tokens(_ data: [String: Any]) -> Tokens? {
        guard let access = data["access_token"] as? String, !access.isEmpty else { return nil }
        return Tokens(access: access, refresh: data["refresh_token"] as? String)
    }

    // MARK: Key

    /// The account's 切号 key in the chatgpt group: the existing one if there is one, else a new one.
    static func ensureKey(_ token: String) async -> Result<(id: Int, key: String), Failure> {
        let groups: [[String: Any]]
        switch await call("groups/available", token: token) {
        case .success(let data): groups = list(data)
        case .failure(let failure): return .failure(failure)
        }
        guard let group = groups.first(where: { ($0["name"] as? String)?.lowercased() == groupName }),
              let groupID = int(group["id"]) else {
            return .failure(Failure(message: "这个账号没有 \(groupName) 分组的权限，请联系站长开通。"))
        }
        let page = [URLQueryItem(name: "page", value: "1"), URLQueryItem(name: "page_size", value: "100")]
        if case .success(let data) = await call("keys", query: page, token: token) {
            for item in list(data) where item["name"] as? String == keyName && int(item["group_id"]) == groupID
                && (item["status"] as? String ?? "active") == "active" {
                if let key = item["key"] as? String, !key.contains("*"), let id = int(item["id"]) { return .success((id, key)) }
            }
        }
        switch await call("keys", body: ["name": keyName, "group_id": groupID], token: token) {
        case .success(let item):
            guard let key = item["key"] as? String, let id = int(item["id"]) else { return .failure(Failure(message: "创建 Key 的响应无法解析")) }
            return .success((id, key))
        case .failure(let failure): return .failure(failure)
        }
    }

    // MARK: Usage

    /// The newest requests made with the key.
    static func records(_ token: String, keyID: Int?, count: Int = 50) async -> Result<[Record], Failure> {
        var items = [URLQueryItem(name: "page", value: "1"), URLQueryItem(name: "page_size", value: String(count)),
                     URLQueryItem(name: "sort_by", value: "created_at"), URLQueryItem(name: "sort_order", value: "desc"),
                     URLQueryItem(name: "timezone", value: TimeZone.current.identifier)]
        if let keyID { items.append(URLQueryItem(name: "api_key_id", value: String(keyID))) }
        switch await call("usage", query: items, token: token) {
        case .success(let data):
            let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let plain = ISO8601DateFormatter()
            return .success(list(data).compactMap { row in
                guard let id = int(row["id"]), let raw = row["created_at"] as? String,
                      let at = iso.date(from: raw) ?? plain.date(from: raw) else { return nil }
                return Record(id: id, at: at, model: row["model"] as? String ?? "—",
                              input: int(row["input_tokens"]) ?? 0, output: int(row["output_tokens"]) ?? 0,
                              cached: int(row["cache_read_tokens"]) ?? 0,
                              cost: number(row["actual_cost"]) ?? number(row["total_cost"]) ?? 0)
            })
        case .failure(let failure): return .failure(failure)
        }
    }

    // MARK: Transport

    /// `/api/v1/<path>`; unwraps sub2api's `{code, message, data}` and turns its message into the error shown.
    private static func call(_ path: String, query: [URLQueryItem]? = nil, body: [String: Any]? = nil, token: String? = nil) async -> Result<[String: Any], Failure> {
        var components = URLComponents(url: site.appendingPathComponent("api/v1/" + path), resolvingAgainstBaseURL: false)!
        components.queryItems = query
        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN", forHTTPHeaderField: "Accept-Language")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch {
            return .failure(Failure(message: (error as? URLError)?.code == .timedOut ? "请求超时" : "连不上 \(site.host ?? "站点")"))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let message = (object?["reason"] as? String).flatMap { reasons[$0] }
            ?? (object?["message"] as? String).flatMap { $0.isEmpty || $0 == "success" ? nil : $0 }
        guard (200..<300).contains(status), (object?["code"] as? Int ?? 0) == 0 else {
            let fallback = status == 401 ? "登录已失效" : status == 429 ? "操作太频繁，稍后再试" : "HTTP \(status)"
            return .failure(Failure(status: status, message: message ?? fallback))
        }
        if let payload = object?["data"] as? [String: Any] { return .success(payload) }
        if let payload = object?["data"] as? [[String: Any]] { return .success(["items": payload]) }
        return .success(object ?? [:])
    }

    /// sub2api answers in English; the errors a friend is likely to meet, in Chinese.
    private static let reasons = [
        "INVALID_CREDENTIALS": "账号或密码不对。",
        "USER_NOT_ACTIVE": "这个账号已被停用，请联系站长。",
        "EMAIL_EXISTS": "这个用户名已经注册过。",
        "EMAIL_RESERVED": "这个名字不能用来注册。",
        "EMAIL_BLOCKED": "这个名字不能用来注册。",
        "EMAIL_SUFFIX_NOT_ALLOWED": "不支持这个邮箱后缀。",
        "EMAIL_VERIFY_REQUIRED": "站点开启了邮箱验证，暂时只能在网站上注册。",
        "REGISTRATION_DISABLED": "站点暂未开放注册。",
        "INVITATION_CODE_REQUIRED": "需要邀请码。",
        "INVITATION_CODE_INVALID": "邀请码无效或已被使用。",
    ]

    /// A paginated `{items: […]}` or a bare array.
    private static func list(_ data: [String: Any]) -> [[String: Any]] { data["items"] as? [[String: Any]] ?? [] }

    private static func int(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        if let s = value as? String { return Int(s) }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String { return Double(s) }
        return nil
    }
}
