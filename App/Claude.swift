import Foundation
import Observation
import Darwin

/// An Anthropic-compatible relay for the Claude desktop app (third-party mode).
struct ClaudeProvider: Codable, Hashable, Identifiable {
    var id = UUID()
    var name = ""
    var baseURL = ""
    /// Yuan paid for one unit of the relay's credit, to show balances in ¥ (zzq.si 7, corecode 1).
    var cnyPerUnit = 1.0

    var keyAccount: String { "claude.key.\(id.uuidString)" }
    /// Optional new-api system access token, for spend per day.
    var accessAccount: String { "claude.access.\(id.uuidString)" }
    var root: URL? { Endpoint.root(from: baseURL) }
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? (root?.host ?? "未命名") : trimmed
    }
}

/// The Claude desktop app's third-party gateway config, plus ~/.claude/settings.json for the command line.
enum ClaudeConfig {
    enum Failure: Error { case unreadable, writeFailed }

    static var settings: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json") }
    static var desktopLibrary: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Claude-3p/configLibrary", isDirectory: true)
    }
    static var hasDesktopLibrary: Bool { FileManager.default.fileExists(atPath: desktopLibrary.appendingPathComponent("_meta.json").path) }

    /// The gateway the desktop app's applied entry points at, else the command line's base URL.
    static func currentBaseURL() -> String? {
        let lib = desktopLibrary
        if let meta = readJSON(lib.appendingPathComponent("_meta.json")), let applied = meta["appliedId"] as? String,
           let entry = readJSON(lib.appendingPathComponent("\(applied).json")),
           let url = entry["inferenceGatewayBaseUrl"] as? String {
            return url
        }
        return (readJSON(settings)?["env"] as? [String: Any])?["ANTHROPIC_BASE_URL"] as? String
    }

    /// Points the command line at the relay (only the two env keys change; the first original is backed up).
    static func applyCLI(baseURL: String, token: String) throws {
        let fm = FileManager.default
        var object: [String: Any] = [:]
        var mode = 0o600
        if fm.fileExists(atPath: settings.path) {
            guard let data = try? Data(contentsOf: settings),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.unreadable }
            object = parsed
            mode = ((try? fm.attributesOfItem(atPath: settings.path))?[.posixPermissions] as? Int) ?? 0o600
            let backup = Disk.url("claude-settings.backup.json")
            if !fm.fileExists(atPath: backup.path) { try? data.write(to: backup, options: .atomic); chmod(backup.path, 0o600) }
        } else {
            try? fm.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        var env = object["env"] as? [String: Any] ?? [:]
        env["ANTHROPIC_BASE_URL"] = baseURL
        env["ANTHROPIC_AUTH_TOKEN"] = token
        object["env"] = env
        try writeJSON(object, to: settings, mode: mode & 0o777)
    }

    /// Writes (or updates) the relay's entry in Claude-3p/configLibrary and makes it the applied one.
    /// Returns false when the desktop app has never been set up for third-party mode.
    @discardableResult
    static func applyDesktop(id: UUID, name: String, baseURL: String, token: String) throws -> Bool {
        let lib = desktopLibrary
        let metaURL = lib.appendingPathComponent("_meta.json")
        guard var meta = readJSON(metaURL) else { return false }
        let entryID = id.uuidString.lowercased()
        let entryURL = lib.appendingPathComponent("\(entryID).json")
        // Start from this relay's entry, else the applied one, so settings like egress hosts carry over.
        var entry = readJSON(entryURL)
            ?? (meta["appliedId"] as? String).flatMap { readJSON(lib.appendingPathComponent("\($0).json")) } ?? [:]
        entry["inferenceProvider"] = "gateway"
        entry["inferenceGatewayBaseUrl"] = baseURL
        entry["inferenceGatewayApiKey"] = token
        entry["inferenceGatewayAuthScheme"] = "bearer"
        entry.removeValue(forKey: "inferenceCredentialKind")
        try writeJSON(entry, to: entryURL, mode: 0o600)
        var entries = meta["entries"] as? [[String: Any]] ?? []
        let label = "切号 · \(name)"
        if let index = entries.firstIndex(where: { ($0["id"] as? String) == entryID }) {
            entries[index]["name"] = label
        } else {
            entries.append(["id": entryID, "name": label])
        }
        meta["entries"] = entries
        meta["appliedId"] = entryID
        try writeJSON(meta, to: metaURL, mode: 0o600)
        return true
    }

    private static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func writeJSON(_ object: [String: Any], to url: URL, mode: Int) throws {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .withoutEscapingSlashes]) else {
            throw Failure.writeFailed
        }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".qiehao-\(UUID().uuidString).json")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: mode]) else {
            throw Failure.writeFailed
        }
        guard rename(temporary.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary); throw Failure.writeFailed
        }
    }
}

/// Claude relays, which one the desktop app uses, and each one's balance.
@Observable @MainActor
final class ClaudeStore {
    static let shared = ClaudeStore()

    private(set) var providers: [ClaudeProvider] = []
    private(set) var balances: [UUID: (credit: Double, at: Date)] = [:]
    private(set) var errors: [UUID: String] = [:]
    private(set) var refreshing = false
    private(set) var refreshedAt: Date?
    private(set) var message: String?
    /// Bumped when the config files may have changed, so `activeID` is read again.
    private var configVersion = 0
    var restartClaude: Bool { didSet { defaults.set(restartClaude, forKey: "claude.restart") } }
    var syncCLI: Bool { didSet { defaults.set(syncCLI, forKey: "claude.syncCLI") } }

    private let defaults = UserDefaults.standard
    private static let file = "claude-providers.json"
    private struct Saved: Codable { var providers: [ClaudeProvider] }
    private var loop: Task<Void, Never>?

    private init() {
        restartClaude = defaults.object(forKey: "claude.restart") as? Bool ?? true
        syncCLI = defaults.object(forKey: "claude.syncCLI") as? Bool ?? true
        providers = Disk.read(Saved.self, Self.file)?.providers ?? []
    }

    /// The relay the desktop app is configured for now, matched by base URL.
    var activeID: UUID? {
        _ = configVersion
        let url = ClaudeConfig.currentBaseURL()
        return providers.first { Endpoint.sameRoot($0.baseURL, url) }?.id
    }

    func activate() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshAll()
                try? await Task.sleep(for: .seconds(CodexStore.refreshEvery))
            }
        }
    }

    func deactivate() { loop?.cancel(); loop = nil }

    private func save() { Disk.write(Saved(providers: providers), Self.file) }

    // MARK: Switching

    func switchTo(_ id: UUID) {
        guard let provider = providers.first(where: { $0.id == id }) else { return }
        let running = AppActivity.isRunning(AppActivity.claudeBundle)
        if restartClaude && running && AppActivity.claudeBusy() { BusyAlert.show("Claude"); return }
        guard let key = Secrets.get(provider.keyAccount), let root = provider.root else {
            message = "\(provider.displayName) 还没有 API Key 或地址无效。"; return
        }
        guard ClaudeConfig.hasDesktopLibrary else {
            message = "Claude 桌面端还没开启第三方模式（没有 Claude-3p/configLibrary）。请先在 Claude 桌面端里配置一次第三方网关。"
            return
        }
        do {
            try ClaudeConfig.applyDesktop(id: provider.id, name: provider.displayName, baseURL: root.absoluteString, token: key)
        } catch {
            message = "写入 Claude 桌面端配置失败，仍走原来的线路。"; return
        }
        var note = ""
        if syncCLI {
            do { try ClaudeConfig.applyCLI(baseURL: root.absoluteString, token: key) } catch { note = "（命令行配置 ~/.claude/settings.json 没能写入）" }
        }
        configVersion += 1
        let name = provider.displayName
        if running && restartClaude {
            message = "已切到 \(name)\(note)，正在重启 Claude…"
            AppRestarter.restart(bundle: AppActivity.claudeBundle, appName: "Claude") { [weak self] result in
                self?.message = "已切到 \(name)\(note)。\(result)"
            }
        } else {
            message = running ? "已切到 \(name)\(note)。重启 Claude 后生效。" : "已切到 \(name)\(note)。下次打开 Claude 时生效。"
        }
        Task { await refresh(provider) }
    }

    // MARK: Editing

    @discardableResult
    func save(_ provider: ClaudeProvider, key: String, accessToken: String = "") -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            do { try Secrets.set(trimmed, for: provider.keyAccount) } catch { return false }
        }
        let access = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !access.isEmpty {
            do { try Secrets.set(access, for: provider.accessAccount) } catch { return false }
        }
        let wasActive = provider.id == activeID
        if let index = providers.firstIndex(where: { $0.id == provider.id }) { providers[index] = provider } else { providers.append(provider) }
        save()
        // Already in use: rewrite the config so a new key or URL takes effect on Claude's next start.
        if wasActive, let key = Secrets.get(provider.keyAccount), let root = provider.root {
            _ = try? ClaudeConfig.applyDesktop(id: provider.id, name: provider.displayName, baseURL: root.absoluteString, token: key)
            if syncCLI { try? ClaudeConfig.applyCLI(baseURL: root.absoluteString, token: key) }
            configVersion += 1
            message = "已更新 \(provider.displayName)，重启 Claude 后生效。"
        }
        Task { await refresh(provider) }
        return true
    }

    func delete(_ id: UUID) {
        guard let provider = providers.first(where: { $0.id == id }), id != activeID else { return }
        try? Secrets.set([provider.keyAccount: nil, provider.accessAccount: nil])
        providers.removeAll { $0.id == id }
        balances[id] = nil; errors[id] = nil
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        providers.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func hasKey(_ provider: ClaudeProvider) -> Bool { Secrets.get(provider.keyAccount) != nil }

    /// Re-reads which relay is configured (after another tool changed it).
    func reloadConfig() { configVersion += 1 }

    // MARK: Balance

    func refreshAll() async {
        guard !refreshing else { return }
        refreshing = true
        configVersion += 1
        for provider in providers { await refresh(provider) }
        refreshing = false
        refreshedAt = Date()
    }

    func refresh(_ provider: ClaudeProvider) async {
        guard let key = Secrets.get(provider.keyAccount), let root = provider.root else { errors[provider.id] = "没有 API Key"; return }
        switch await RelayBalance.fetch(root: root, key: key) {
        case .success(let credit):
            balances[provider.id] = (credit, Date()); errors[provider.id] = nil
            UsageStore.shared.recordBalance(provider.id, credit: credit)
        case .failure(let failure): balances[provider.id] = nil; errors[provider.id] = failure.message
        }
        await UsageStore.shared.refreshRelay(provider.id, root: root, key: key, accessToken: Secrets.get(provider.accessAccount))
    }

    // MARK: Import

    func importProviders(_ imported: [ClaudeProvider]) {
        providers = imported
        save()
    }
}
