import AppKit
import Foundation

/// Whether the Claude or Codex desktop app is in the middle of a turn, read from the transcripts they write.
/// Neither app exposes its state, so this is a heuristic: anything that looks unfinished and was written
/// recently counts as running. When in doubt it says busy, so a switch never cuts a turn off.
enum AppActivity {
    static let claudeBundle = "com.anthropic.claudefordesktop"
    static let codexBundle = "com.openai.codex"
    /// A transcript untouched for this long is idle whatever its last line says (a crash leaves a turn open).
    private static let window: TimeInterval = 10 * 60

    static func isRunning(_ bundle: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty
    }

    // MARK: Claude

    /// Claude Code (desktop Code tab included) writes ~/.claude/projects/<project>/<session>.jsonl.
    /// A turn is over when the last message is the assistant's with a final stop reason, or the user stopped it.
    nonisolated static func claudeBusy(now: Date = Date()) -> Bool {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)
        return recentFiles(in: root, ext: "jsonl", since: now.addingTimeInterval(-window)).contains { claudeOpen($0) }
    }

    private static func claudeOpen(_ url: URL) -> Bool {
        for line in tailLines(url).reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = object["type"] as? String, type == "assistant" || type == "user" else { continue }
            let message = object["message"] as? [String: Any] ?? [:]
            if type == "assistant" {
                let stop = message["stop_reason"] as? String
                return !["end_turn", "stop_sequence", "max_tokens", "refusal"].contains(stop ?? "")
            }
            // Slash-command echoes and meta lines get no reply.
            if object["isMeta"] as? Bool == true { continue }
            let text = textOf(message["content"])
            if text.hasPrefix("<command-name>") || text.hasPrefix("<local-command") { continue }
            if text.contains("[Request interrupted by user") { return false }
            return true
        }
        return false
    }

    private static func textOf(_ content: Any?) -> String {
        if let s = content as? String { return s }
        if let parts = content as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return ""
    }

    // MARK: Codex

    /// Codex writes ~/.codex/sessions/…/rollout-*.jsonl with task_started / task_complete events per turn.
    nonisolated static func codexBusy(home: URL = CodexFiles.home, now: Date = Date()) -> Bool {
        let root = home.appendingPathComponent("sessions", isDirectory: true)
        return recentFiles(in: root, ext: "jsonl", since: now.addingTimeInterval(-window)).contains { url in
            for line in tailLines(url).reversed() {
                if line.contains("\"task_complete\"") || line.contains("\"turn_aborted\"") { return false }
                if line.contains("\"task_started\"") { return true }
            }
            // No marker in the tail: only a file being written right now counts.
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return modified.map { now.timeIntervalSince($0) < 60 } ?? false
        }
    }

    // MARK: Files

    private static func recentFiles(in root: URL, ext: String, since: Date) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                                                          options: [.skipsHiddenFiles], errorHandler: { _, _ in true }) else { return [] }
        var found: [URL] = []
        for case let url as URL in walker where url.pathExtension == ext {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            if values?.isRegularFile == true, let date = values?.contentModificationDate, date >= since { found.append(url) }
        }
        return found
    }

    /// The last ~256 KB as lines; a partial first line is dropped.
    private static func tailLines(_ url: URL, bytes: UInt64 = 256 * 1024) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > bytes ? size - bytes : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return [] }
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return lines
    }
}

/// Quits a desktop app and opens it again, the way 切号 already restarts Claude.
@MainActor
enum AppRestarter {
    /// Calls `done` with a user-facing result. Does nothing (and says so) when the app is not running.
    static func restart(bundle: String, appName: String, done: @escaping (String) -> Void) {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundle)
        guard let url = running.first?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else {
            done("没有找到 \(appName)。"); return
        }
        guard !running.isEmpty else { done("\(appName) 没在运行，下次打开时生效。"); return }
        running.forEach { $0.terminate() }
        Task { @MainActor in
            for _ in 0..<60 where running.contains(where: { !$0.isTerminated }) { try? await Task.sleep(for: .milliseconds(250)) }
            guard running.allSatisfy(\.isTerminated) else {
                done("\(appName) 没有退出（可能在等你确认），请手动退出再打开。"); return
            }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            do {
                try await NSWorkspace.shared.openApplication(at: url, configuration: config)
                done("\(appName) 已重启，新账号已生效。")
            } catch {
                done("\(appName) 已退出但没能重新打开，请手动打开。")
            }
        }
    }

    /// Opens the app (or brings it up) without quitting it.
    static func launch(bundle: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

@MainActor
enum BusyAlert {
    static func show(_ app: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "正在调用中请等结束后再执行切换"
        alert.informativeText = "\(app) 还有对话在运行，切换需要重启 \(app)，会打断它。等这一轮结束后再切换。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}
