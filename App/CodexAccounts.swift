import AppKit
import Foundation
import Observation
import Darwin

/// One way of running the Codex desktop app: a ChatGPT login (official) or an API relay.
struct CodexProfile: Codable, Hashable, Identifiable {
    enum Kind: String, Codable { case official, relay }

    var id = UUID()
    var kind: Kind
    var name = ""
    /// Official: chatgpt_account_id, which tells two logins apart.
    var accountID: String?
    var email: String?
    var plan: String?
    /// Relay: what the user typed; Codex gets `root + /v1`.
    var baseURL = ""
    /// Relay: yuan paid for one unit of its credit, to show balances in ¥.
    var cnyPerUnit = 1.0

    /// Official: the whole auth.json; relay: the API key. Kept in 切号's private credential file.
    var secretAccount: String { "codex.\(kind.rawValue).\(id.uuidString)" }
    /// Relay: optional new-api system access token, for spend per day.
    var accessAccount: String { "codex.access.\(id.uuidString)" }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        return kind == .official ? (email ?? "ChatGPT 账号") : (Endpoint.root(from: baseURL)?.host ?? "未命名中转")
    }

    var root: URL? { Endpoint.root(from: baseURL) }
    /// Codex's openai_base_url wants the /v1 prefix (it appends /responses).
    var codexBaseURL: String? { root.map { $0.appendingPathComponent("v1").absoluteString } }
}

/// One rate-limit window from chatgpt.com/backend-api/wham/usage.
struct CodexWindow: Codable, Hashable {
    var usedPercent: Double
    var seconds: Double
    var resetAt: Date
    var remaining: Double { max(0, min(100, 100 - usedPercent)) }
}

struct CodexQuota: Codable, Hashable {
    var plan: String?
    var fiveHour: CodexWindow?
    var week: CodexWindow?
    var credits: Double?
    var unlimitedCredits = false
    var limitReached = false
    var at: Date
}

/// ~/.codex (or $CODEX_HOME): auth.json and the config lines 切号 owns, `openai_base_url` and (for relays) `model_catalog_json`.
enum CodexFiles {
    enum Failure: Error { case writeFailed }

    static var home: URL {
        if let custom = ProcessInfo.processInfo.environment["CODEX_HOME"], !custom.isEmpty { return URL(fileURLWithPath: custom) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }
    static var auth: URL { home.appendingPathComponent("auth.json") }
    static var config: URL { home.appendingPathComponent("config.toml") }
    /// 切号's copy of the relay's Codex model list. With an API key Codex never asks the relay for its models and
    /// falls back to the list built into the app, so 切号 fetches it and points `model_catalog_json` here.
    static var relayCatalog: URL { home.appendingPathComponent("swapdeck-models.json") }

    static func authData() -> Data? { try? Data(contentsOf: auth) }
    static func authObject() -> [String: Any]? {
        authData().flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
    static func authModified() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: auth.path))?[.modificationDate] as? Date
    }

    /// The first original of each file, once, readable only by this user.
    static func backupOnce() {
        for (source, name) in [(auth, "codex-auth.backup.json"), (config, "codex-config.backup.toml")] {
            let target = Disk.url(name)
            guard !FileManager.default.fileExists(atPath: target.path), let data = try? Data(contentsOf: source) else { continue }
            try? data.write(to: target, options: .atomic)
            chmod(target.path, 0o600)
        }
    }

    static func writeAuth(_ data: Data) throws {
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try atomicWrite(data, to: auth, mode: 0o600)
    }

    static func removeAuth() { try? FileManager.default.removeItem(at: auth) }

    // MARK: config.toml

    /// Lines before the first [table]; top-level keys live there.
    private static func topLevelRange(_ lines: [String]) -> Range<Int> {
        let end = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") } ?? lines.count
        return 0..<end
    }

    private static func topLevelValue(_ key: String) -> String? {
        guard let text = try? String(contentsOf: config, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\n")
        for line in lines[topLevelRange(lines)] {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[0] == key else { continue }
            var value = parts[1]
            if let hash = value.range(of: " #") { value = String(value[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces) }
            return value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return nil
    }

    static func baseURLOverride() -> String? { topLevelValue("openai_base_url") }
    static func isProxy(_ base: String?) -> Bool { CodexRelayProxy.isProxyURL(base) }
    /// Anything but the built-in openai provider would split the thread list; 切号 leaves it alone and warns.
    static func modelProvider() -> String? { topLevelValue("model_provider") }

    /// Sets or removes the top-level `openai_base_url`, leaving every other line as it was.
    static func setBaseURL(_ url: String?) throws { try setTopLevel("openai_base_url", url) }

    /// Points Codex at 切号's copy of the relay's model list, or removes that pointer.
    /// A `model_catalog_json` the user set to some other file is left alone.
    static func setRelayCatalog(_ on: Bool) throws {
        if let current = topLevelValue("model_catalog_json"), current != relayCatalog.path { return }
        try setTopLevel("model_catalog_json", on ? relayCatalog.path : nil)
    }

    static func writeRelayCatalog(_ data: Data) throws {
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try atomicWrite(data, to: relayCatalog, mode: 0o644)
    }

    private static func setTopLevel(_ key: String, _ value: String?) throws {
        let fm = FileManager.default
        let text = (try? String(contentsOf: config, encoding: .utf8)) ?? ""
        var lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        let top = topLevelRange(lines)
        let existing = lines[top].indices.filter {
            lines[$0].split(separator: "=", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces) == key
        }
        if value == nil && existing.isEmpty { return }
        for index in existing.reversed() { lines.remove(at: index) }
        if let value {
            let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            lines.insert("\(key) = \"\(escaped)\"", at: 0)
        }
        if lines.isEmpty && value == nil && !fm.fileExists(atPath: config.path) { return }
        let mode = ((try? fm.attributesOfItem(atPath: config.path))?[.posixPermissions] as? Int) ?? 0o644
        try? fm.createDirectory(at: home, withIntermediateDirectories: true)
        try atomicWrite(Data(lines.joined(separator: "\n").utf8), to: config, mode: mode & 0o777)
    }

    private static func atomicWrite(_ data: Data, to url: URL, mode: Int) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".yuliang-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: mode]) else {
            throw Failure.writeFailed
        }
        guard rename(temporary.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw Failure.writeFailed
        }
    }
}

/// The model list a relay serves to Codex: `GET /v1/models?client_version=…` in Codex's manifest format
/// (sub2api answers this shape whenever `client_version` is present).
enum RelayCatalog {
    /// The version Codex reports when it fetches models itself, so the relay tailors the list the same way.
    static func clientVersion() -> String {
        if let data = try? Data(contentsOf: CodexFiles.home.appendingPathComponent("models_cache.json")),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let version = object["client_version"] as? String, !version.isEmpty {
            return version
        }
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: AppActivity.codexBundle) {
            for path in ["Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex", "Contents/Resources/codex"] {
                let binary = app.appendingPathComponent(path)
                guard FileManager.default.isExecutableFile(atPath: binary.path) else { continue }
                let process = Process(), pipe = Pipe()
                process.executableURL = binary
                process.arguments = ["--version"]
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                guard (try? process.run()) != nil else { continue }
                process.waitUntilExit()
                let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                if let r = text.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) { return String(text[r]) }
            }
        }
        return "0.169.0"
    }

    /// The relay's manifest, or nil when it doesn't serve one (then Codex keeps its built-in list).
    static func fetch(root: URL, key: String) async -> Data? {
        let version = await Task.detached { clientVersion() }.value
        guard var components = URLComponents(url: root.appendingPathComponent("v1/models"), resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = [URLQueryItem(name: "client_version", value: version)]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["models"] as? [[String: Any]], !models.isEmpty,
              models.allSatisfy({ $0["slug"] is String }) else { return nil }
        return data
    }

    /// Refreshes 切号's copy and points Codex at it; without a manifest the pointer is removed.
    @discardableResult
    static func install(root: URL, key: String) async -> Bool {
        guard let data = await fetch(root: root, key: key) else {
            try? CodexFiles.setRelayCatalog(false)
            return false
        }
        do { try CodexFiles.writeRelayCatalog(data); try CodexFiles.setRelayCatalog(true); return true } catch { return false }
    }
}

/// Claims inside a ChatGPT login's JWTs.
enum JWT {
    static func claims(_ token: String?) -> [String: Any]? {
        guard let token else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func expiry(_ token: String?) -> Date? {
        (claims(token)?["exp"] as? Double).map(Date.init(timeIntervalSince1970:))
    }
}

/// A parsed ChatGPT login (auth.json with tokens).
struct CodexLogin {
    var raw: [String: Any]
    var accessToken: String
    var refreshToken: String?
    var accountID: String
    var email: String?
    var plan: String?
    var clientID: String?

    init?(data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        self.init(object: object)
    }

    init?(object: [String: Any]) {
        guard let tokens = object["tokens"] as? [String: Any], let access = tokens["access_token"] as? String else { return nil }
        let idClaims = JWT.claims(tokens["id_token"] as? String)
        let accessClaims = JWT.claims(access)
        let auth = (idClaims?["https://api.openai.com/auth"] ?? accessClaims?["https://api.openai.com/auth"]) as? [String: Any]
        guard let account = (tokens["account_id"] as? String) ?? (auth?["chatgpt_account_id"] as? String) else { return nil }
        raw = object
        accessToken = access
        refreshToken = tokens["refresh_token"] as? String
        accountID = account
        email = (idClaims?["email"] as? String) ?? ((accessClaims?["https://api.openai.com/profile"] as? [String: Any])?["email"] as? String)
        plan = auth?["chatgpt_plan_type"] as? String
        clientID = accessClaims?["client_id"] as? String
    }

    var data: Data? { try? JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .withoutEscapingSlashes]) }
}

/// ChatGPT endpoints Codex itself uses. Not public API: they can change without notice.
enum CodexAPI {
    struct Failure: Error { var status: Int?; var message: String }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()
    static let defaultClientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    static func usage(_ login: CodexLogin) async -> Result<CodexQuota, Failure> {
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.setValue("Bearer \(login.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(login.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("codex_cli_rs", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch {
            return .failure(Failure(message: (error as? URLError)?.code == .timedOut ? "请求超时" : "网络请求失败"))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            return .failure(Failure(status: status, message: status == 401 || status == 403 ? "登录已过期" : "HTTP \(status)"))
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(Failure(status: status, message: "响应无法解析"))
        }
        let limits = object["rate_limit"] as? [String: Any]
        func window(_ key: String) -> CodexWindow? {
            guard let w = limits?[key] as? [String: Any], let used = number(w["used_percent"]) else { return nil }
            let seconds = number(w["limit_window_seconds"]) ?? 0
            let reset = number(w["reset_at"]).map(Date.init(timeIntervalSince1970:))
                ?? Date().addingTimeInterval(number(w["reset_after_seconds"]) ?? 0)
            return CodexWindow(usedPercent: used, seconds: seconds, resetAt: reset)
        }
        // The two windows are usually 5 h and 7 d; sort by length rather than trusting primary/secondary.
        let windows = [window("primary_window"), window("secondary_window")].compactMap { $0 }.sorted { $0.seconds < $1.seconds }
        let credits = object["credits"] as? [String: Any]
        return .success(CodexQuota(
            plan: object["plan_type"] as? String,
            fiveHour: windows.first { $0.seconds <= 6 * 3600 } ?? (windows.count == 2 ? windows[0] : nil),
            week: windows.first { $0.seconds > 6 * 3600 },
            credits: number(credits?["balance"]),
            unlimitedCredits: credits?["unlimited"] as? Bool ?? false,
            limitReached: limits?["limit_reached"] as? Bool ?? false,
            at: Date()))
    }

    /// Exchanges the refresh token for new tokens, the way Codex does; returns the updated auth.json object.
    static func refresh(_ login: CodexLogin) async -> Result<[String: Any], Failure> {
        guard let refreshToken = login.refreshToken else { return .failure(Failure(message: "没有 refresh token")) }
        var request = URLRequest(url: URL(string: "https://auth.openai.com/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "client_id": login.clientID ?? defaultClientID, "grant_type": "refresh_token",
            "refresh_token": refreshToken, "scope": "openid profile email"])
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch {
            return .failure(Failure(message: "网络请求失败"))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = object["access_token"] as? String else {
            return .failure(Failure(status: status, message: status == 400 || status == 401 ? "登录已失效，请重新登录这个账号" : "刷新登录失败（HTTP \(status)）"))
        }
        var raw = login.raw
        var tokens = raw["tokens"] as? [String: Any] ?? [:]
        tokens["access_token"] = access
        if let id = object["id_token"] as? String { tokens["id_token"] = id }
        if let next = object["refresh_token"] as? String { tokens["refresh_token"] = next }
        raw["tokens"] = tokens
        raw["last_refresh"] = ISO8601DateFormatter().string(from: Date())
        return .success(raw)
    }

    private static func number(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String { return Double(s) }
        return nil
    }
}

/// Codex accounts and relays, what the desktop app uses now, and each one's quota.
@Observable @MainActor
final class CodexStore {
    static let shared = CodexStore()

    private(set) var profiles: [CodexProfile] = []
    /// The profile ~/.codex points at now; nil when it matches none (logged out, or set up outside 切号).
    private(set) var activeID: UUID?
    private(set) var quotas: [UUID: CodexQuota] = [:]
    private(set) var balances: [UUID: (credit: Double, at: Date)] = [:]
    private(set) var errors: [UUID: String] = [:]
    private(set) var refreshing = false
    /// Fetching a relay's model list before switching to it.
    private(set) var switching = false
    private(set) var refreshedAt: Date?
    private(set) var message: String?
    /// Waiting for the user to sign in to another account in Codex.
    private(set) var pendingLogin: Bool { didSet { defaults.set(pendingLogin, forKey: "codex.pendingLogin") } }
    var restartCodex: Bool { didSet { defaults.set(restartCodex, forKey: "codex.restart") } }

    static let refreshEvery: TimeInterval = 5 * 60
    private let defaults = UserDefaults.standard
    private static let file = "codex-profiles.json"
    private static let quotaFile = "codex-quotas.json"
    private var loop: Task<Void, Never>?
    private var lastAuthDate: Date?
    private var nextRefresh = Date.distantPast

    private struct Saved: Codable { var profiles: [CodexProfile] }

    private init() {
        pendingLogin = defaults.bool(forKey: "codex.pendingLogin")
        restartCodex = defaults.object(forKey: "codex.restart") as? Bool ?? true
        profiles = Disk.read(Saved.self, Self.file)?.profiles ?? []
        quotas = Disk.read([UUID: CodexQuota].self, Self.quotaFile) ?? [:]
    }

    var active: CodexProfile? { profiles.first { $0.id == activeID } }
    var officials: [CodexProfile] { profiles.filter { $0.kind == .official } }
    var relays: [CodexProfile] { profiles.filter { $0.kind == .relay } }

    /// The relay the local forwarder serves; ~/.codex only shows the forwarder's loopback address.
    private var proxyRelayID: UUID? {
        get { defaults.string(forKey: "codex.proxyRelay").flatMap(UUID.init(uuidString:)) }
        set { defaults.set(newValue?.uuidString, forKey: "codex.proxyRelay") }
    }

    /// Brings the forwarder up when Codex is already pointed at a relay (after 切号 restarts, or a relay set up
    /// by an older build that pointed Codex straight at the relay and so hit the WebSocket retries).
    private func resumeProxy() {
        let base = CodexFiles.baseURLOverride()
        let relay: CodexProfile?
        if CodexFiles.isProxy(base) {
            relay = relays.first { $0.id == proxyRelayID }
        } else if let base {
            relay = relays.first { Endpoint.sameRoot($0.baseURL, base) }
        } else {
            return
        }
        guard let relay, let root = relay.root else { return }
        let wanted = base.flatMap(URL.init(string:))?.port.map(UInt16.init)
        guard CodexRelayProxy.shared.start(upstream: root, wanted: CodexFiles.isProxy(base) ? wanted : nil) != nil,
              let proxyURL = CodexRelayProxy.shared.codexBaseURL else {
            message = "本机转发没能启动，Codex 中转可能每次提问都要重连。请重新打开切号再试。"; return
        }
        proxyRelayID = relay.id
        if proxyURL != base {
            try? CodexFiles.setBaseURL(proxyURL)
            message = "已改为经切号本机转发连接 \(relay.displayName)，重启 Codex 后提问不再反复重连。"
        }
        // Keep the relay's model list current for Codex's next start (also fixes relays switched to by older builds).
        if let key = Secrets.get(relay.secretAccount) {
            Task { await RelayCatalog.install(root: root, key: key) }
        }
    }

    func activate() {
        if loop == nil { resumeProxy() }
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.watchAuth()
                if Date() >= self.nextRefresh { await self.refreshAll() }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func deactivate() { loop?.cancel(); loop = nil }

    private func save() { Disk.write(Saved(profiles: profiles), Self.file) }

    // MARK: Following ~/.codex

    /// Notices logins made in Codex (adds the account) and keeps the active account's saved copy current,
    /// since Codex rotates its refresh token and an old copy would stop working.
    private func watchAuth() {
        let modified = CodexFiles.authModified()
        guard modified != lastAuthDate else { return }
        lastAuthDate = modified
        detectActive()
    }

    func detectActive() {
        guard let data = CodexFiles.authData() else { activeID = nil; return }
        if let login = CodexLogin(data: data) {
            do {
                if let index = profiles.firstIndex(where: { $0.kind == .official && $0.accountID == login.accountID }) {
                    storeLogin(data, for: profiles[index])
                    profiles[index].email = login.email ?? profiles[index].email
                    profiles[index].plan = login.plan ?? profiles[index].plan
                    activeID = profiles[index].id
                } else {
                    var profile = CodexProfile(kind: .official)
                    profile.accountID = login.accountID
                    profile.email = login.email
                    profile.plan = login.plan
                    storeLogin(data, for: profile)
                    profiles.insert(profile, at: officials.count)
                    activeID = profile.id
                    if pendingLogin { message = "已记住 \(profile.displayName)。" }
                    nextRefresh = .distantPast
                }
                if pendingLogin { pendingLogin = false }
                save()
            }
            return
        }
        // API-key login: match the relay by its base URL.
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["OPENAI_API_KEY"] is String,
           let base = CodexFiles.baseURLOverride() {
            activeID = CodexFiles.isProxy(base) ? relays.first { $0.id == proxyRelayID }?.id
                                                : relays.first { Endpoint.sameRoot($0.baseURL, base) }?.id
        } else {
            activeID = nil
        }
    }

    private func storeLogin(_ data: Data, for profile: CodexProfile) {
        guard Secrets.get(profile.secretAccount).map({ Data($0.utf8) }) != data else { return }
        try? Secrets.set(String(decoding: data, as: UTF8.self), for: profile.secretAccount)
    }

    // MARK: Switching

    /// Points Codex at the profile and restarts the desktop app. Refuses while a turn is running.
    func switchTo(_ id: UUID) {
        guard let target = profiles.first(where: { $0.id == id }) else { return }
        guard id != activeID, !switching else { return }
        let running = AppActivity.isRunning(AppActivity.codexBundle)
        if running && AppActivity.codexBusy() { BusyAlert.show("Codex"); return }
        if let provider = CodexFiles.modelProvider(), provider != "openai" {
            message = "config.toml 里设了 model_provider = \"\(provider)\"，切换不会生效，也会让会话列表按供应商分开。请删掉这一行后再切换。"
            return
        }
        switch target.kind {
        case .official:
            guard let blob = Secrets.get(target.secretAccount) else {
                message = "\(target.displayName) 的登录信息不在了，请重新登录这个账号。"; return
            }
            apply(target, running: running) {
                try CodexFiles.writeAuth(Data(blob.utf8))
                try CodexFiles.setBaseURL(nil)
                try CodexFiles.setRelayCatalog(false)
                CodexRelayProxy.shared.setUpstream(nil)
            }
        case .relay:
            guard let key = Secrets.get(target.secretAccount), let root = target.root else {
                message = "\(target.displayName) 还没有 API Key 或地址无效。"; return
            }
            // Codex never asks a relay for its models in API-key mode, so fetch them first (see RelayCatalog).
            switching = true
            message = "正在读取 \(target.displayName) 的模型列表…"
            Task {
                let catalog = await RelayCatalog.fetch(root: root, key: key)
                switching = false
                apply(target, running: running) {
                    // Codex talks to the loopback forwarder, which turns away its WebSocket attempt (see CodexRelayProxy).
                    guard CodexRelayProxy.shared.start(upstream: root) != nil, let base = CodexRelayProxy.shared.codexBaseURL else {
                        throw SwitchFailure.message("本机转发没能启动（端口 47811–47830 都被占用），Codex 仍用原来的账号。")
                    }
                    proxyRelayID = target.id
                    let auth: [String: Any] = ["auth_mode": "apikey", "OPENAI_API_KEY": key]
                    try CodexFiles.writeAuth(try JSONSerialization.data(withJSONObject: auth, options: [.prettyPrinted]))
                    try CodexFiles.setBaseURL(base)
                    if let catalog { try CodexFiles.writeRelayCatalog(catalog) }
                    try CodexFiles.setRelayCatalog(catalog != nil)
                }
            }
        }
    }

    private enum SwitchFailure: Error { case message(String) }

    /// Writes the target's files into ~/.codex, then restarts Codex when asked to.
    private func apply(_ target: CodexProfile, running: Bool, write: () throws -> Void) {
        let id = target.id
        detectActive()   // save the current login's latest tokens before leaving it
        CodexFiles.backupOnce()
        do {
            try write()
        } catch SwitchFailure.message(let text) {
            message = text
            return
        } catch {
            message = "写入 ~/.codex 失败，Codex 仍用原来的账号。"
            return
        }
        lastAuthDate = CodexFiles.authModified()
        activeID = id
        pendingLogin = false
        let name = target.displayName
        message = "已切到 \(name)。"
        if running && restartCodex {
            message = "已切到 \(name)，正在重启 Codex…"
            AppRestarter.restart(bundle: AppActivity.codexBundle, appName: "Codex") { [weak self] result in
                self?.message = "已切到 \(name)。\(result)"
            }
        } else if running {
            message = "已切到 \(name)。重启 Codex 后生效。"
        }
        Task { await refresh(target) }
    }

    /// Signs Codex out (the current login stays saved) and opens it, so the user can sign in to another account.
    func beginLogin() {
        let running = AppActivity.isRunning(AppActivity.codexBundle)
        if running && AppActivity.codexBusy() { BusyAlert.show("Codex"); return }
        detectActive()
        CodexFiles.backupOnce()
        CodexFiles.removeAuth()
        try? CodexFiles.setBaseURL(nil)
        try? CodexFiles.setRelayCatalog(false)
        lastAuthDate = nil
        activeID = nil
        pendingLogin = true
        message = "请在 Codex 里登录另一个账号，登录后切号会自动记住它。"
        if running {
            AppRestarter.restart(bundle: AppActivity.codexBundle, appName: "Codex") { [weak self] _ in
                self?.message = "请在 Codex 里登录另一个账号，登录后切号会自动记住它。"
            }
        } else {
            AppRestarter.launch(bundle: AppActivity.codexBundle)
        }
    }

    func cancelLogin() { pendingLogin = false; message = nil }

    // MARK: Editing

    @discardableResult
    func saveRelay(_ profile: CodexProfile, key: String, accessToken: String = "") -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            do { try Secrets.set(trimmed, for: profile.secretAccount) } catch { return false }
        }
        let access = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !access.isEmpty {
            do { try Secrets.set(access, for: profile.accessAccount) } catch { return false }
        }
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) { profiles[index] = profile } else { profiles.append(profile) }
        save()
        if profile.id == activeID, let root = profile.root {
            // Already in use: the forwarder follows a new URL at once; a new key is read by Codex on its next start.
            if !trimmed.isEmpty, let data = try? JSONSerialization.data(withJSONObject: ["auth_mode": "apikey", "OPENAI_API_KEY": trimmed]) {
                try? CodexFiles.writeAuth(data); lastAuthDate = CodexFiles.authModified()
            }
            CodexRelayProxy.shared.setUpstream(root)
        }
        Task { await refresh(profile) }
        return true
    }

    func rename(_ id: UUID, to name: String) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].name = name
        save()
    }

    func delete(_ id: UUID) {
        guard let profile = profiles.first(where: { $0.id == id }), id != activeID else { return }
        try? Secrets.set([profile.secretAccount: nil, profile.accessAccount: nil])
        profiles.removeAll { $0.id == id }
        quotas[id] = nil; balances[id] = nil; errors[id] = nil
        save()
        Disk.write(quotas, Self.quotaFile)
    }

    func storedKey(_ profile: CodexProfile) -> Bool { Secrets.get(profile.secretAccount) != nil }

    // MARK: Quota

    func refreshAll() async {
        guard !refreshing else { return }
        refreshing = true
        nextRefresh = Date().addingTimeInterval(Self.refreshEvery)
        for profile in profiles { await refresh(profile) }
        await UsageStore.shared.refreshAccounts()
        refreshing = false
        refreshedAt = Date()
    }

    func refresh(_ profile: CodexProfile) async {
        switch profile.kind {
        case .official: await refreshOfficial(profile)
        case .relay: await refreshRelay(profile)
        }
    }

    private func refreshOfficial(_ profile: CodexProfile) async {
        let isActive = profile.id == activeID
        // The active login belongs to Codex: read it live and never refresh it here (that would rotate
        // the refresh token out from under Codex). Saved logins are 切号's own to refresh.
        let blob = isActive ? CodexFiles.authData() : Secrets.get(profile.secretAccount).map { Data($0.utf8) }
        guard let blob, var login = CodexLogin(data: blob) else { errors[profile.id] = "没有登录信息"; return }
        if !isActive, let exp = JWT.expiry(login.accessToken), exp < Date().addingTimeInterval(120) {
            guard let renewed = await renew(login, profile) else { return }
            login = renewed
        }
        var result = await CodexAPI.usage(login)
        if case .failure(let failure) = result, failure.status == 401 || failure.status == 403, !isActive,
           let renewed = await renew(login, profile) {
            result = await CodexAPI.usage(renewed)
        }
        switch result {
        case .success(let quota):
            quotas[profile.id] = quota
            errors[profile.id] = nil
            if let index = profiles.firstIndex(where: { $0.id == profile.id }), let plan = quota.plan, profiles[index].plan != plan {
                profiles[index].plan = plan; save()
            }
            Disk.write(quotas, Self.quotaFile)
        case .failure(let failure):
            errors[profile.id] = isActive && failure.status == 401 ? "登录已过期，在 Codex 里用一次会自动续期" : failure.message
        }
    }

    private func renew(_ login: CodexLogin, _ profile: CodexProfile) async -> CodexLogin? {
        switch await CodexAPI.refresh(login) {
        case .success(let raw):
            guard let renewed = CodexLogin(object: raw), let data = renewed.data else { return nil }
            // Switched to it meanwhile: Codex owns it now.
            guard profile.id != activeID else { return renewed }
            try? Secrets.set(String(decoding: data, as: UTF8.self), for: profile.secretAccount)
            return renewed
        case .failure(let failure):
            errors[profile.id] = failure.message
            return nil
        }
    }

    private func refreshRelay(_ profile: CodexProfile) async {
        guard let key = Secrets.get(profile.secretAccount), let root = profile.root else {
            errors[profile.id] = "没有 API Key"; return
        }
        switch await RelayBalance.fetch(root: root, key: key) {
        case .success(let credit):
            balances[profile.id] = (credit, Date()); errors[profile.id] = nil
            UsageStore.shared.recordBalance(profile.id, credit: credit)
            await UsageStore.shared.refreshRelay(profile.id, root: root, key: key, accessToken: Secrets.get(profile.accessAccount))
            return
        case .failure(let failure) where failure.status != nil && failure.status != 404:
            balances[profile.id] = nil; errors[profile.id] = failure.message; return
        case .failure:
            break
        }
        balances[profile.id] = nil
        errors[profile.id] = "无余额接口"
    }
}
