import SwiftUI
import AppKit
import Observation
import ServiceManagement

@main
@MainActor
enum QieHaoMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            LegacyPrefs.migrateOnce()
            YuliangImport.runOnce()
            YuliangImport.accessTokensOnce()
            NSApp.mainMenu = MainMenu.build()
            // `--dark` / `--light` force an appearance, for checking the design.
            if CommandLine.arguments.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
            if CommandLine.arguments.contains("--light") { NSApp.appearance = NSAppearance(named: .aqua) }
            ClaudeStore.shared.activate()
            CodexStore.shared.activate()
            WindowManager.shared.showMain()
            Updates.shared.start()
            let center = NSWorkspace.shared.notificationCenter
            center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { ClaudeStore.shared.deactivate(); CodexStore.shared.deactivate() }
            }
            center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { ClaudeStore.shared.activate(); CodexStore.shared.activate() }
            }
        }
    }

    /// Closing the window keeps the app (and the Codex relay forwarder) running; the Dock icon brings it back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { WindowManager.shared.showMain() }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            // Codex talks to the relay through this app; quitting would cut it off.
            guard CodexStore.shared.active?.kind == .relay, AppActivity.isRunning(AppActivity.codexBundle) else { return .terminateNow }
            let alert = NSAlert()
            alert.messageText = "退出后 Codex 将连不上中转"
            alert.informativeText = "Codex 正经切号的本机转发使用「\(CodexStore.shared.active?.displayName ?? "中转")」。退出切号后，Codex 的提问会失败，直到再次打开切号。"
            alert.addButton(withTitle: "仍然退出")
            alert.addButton(withTitle: "取消")
            return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
        }
    }
}

@Observable @MainActor
final class Prefs {
    static let shared = Prefs()
    private let defaults = UserDefaults.standard

    var onTop: Bool { didSet { defaults.set(onTop, forKey: "window.onTop"); WindowManager.shared.applyLevel() } }
    var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do { try launchAtLogin ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() } catch {
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

    private init() {
        onTop = defaults.object(forKey: "window.onTop") as? Bool ?? false
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

@MainActor
final class WindowManager {
    static let shared = WindowManager()
    private var window: NSWindow?

    func showMain() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 600),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.contentView = NSHostingView(rootView: SwitcherView())
            window.contentMinSize = NSSize(width: 320, height: 420)
            window.title = "切号"
            // The view draws its own title row (tab switch and tools); the system title stays for Mission Control.
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("QieHaoMain")
            if window.frame.origin == .zero { window.center() }
            self.window = window
            applyLevel()
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func applyLevel() {
        guard let window else { return }
        let onTop = Prefs.shared.onTop
        window.level = onTop ? .floating : .normal
        window.collectionBehavior = onTop ? [.canJoinAllSpaces, .fullScreenAuxiliary] : []
    }
}

/// App, Edit (so ⌘V works in the key fields) and Window menus.
@MainActor
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于切号", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "检查更新…", action: #selector(Updates.checkForUpdates(_:)), keyEquivalent: "").target = Updates.shared
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏切号", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = appMenu.addItem(withTitle: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "全部显示", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出切号", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "切号", action: #selector(MenuTarget.showMain), keyEquivalent: "0").target = MenuTarget.shared
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        return main
    }
}

final class MenuTarget: NSObject {
    static let shared = MenuTarget()
    @objc func showMain() { MainActor.assumeIsolated { WindowManager.shared.showMain() } }
}

/// Before 1.1 the app was com.lazymice.qiehao; carry its window and toggle settings over once.
@MainActor
enum LegacyPrefs {
    static func migrateOnce() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "migrated.qiehao") else { return }
        defaults.set(true, forKey: "migrated.qiehao")
        guard let old = defaults.persistentDomain(forName: "com.lazymice.qiehao") else { return }
        for (key, value) in old where defaults.object(forKey: key) == nil { defaults.set(value, forKey: key) }
    }
}

/// First launch: bring over the relays, Codex accounts and keys already set up in 余量, so the app works at once.
/// 余量's files are only read.
@MainActor
enum YuliangImport {
    static func runOnce() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "import.yuliang.done") else { return }
        defaults.set(true, forKey: "import.yuliang.done")
        let yuliang = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Yuliang", isDirectory: true)
        let secrets = (readJSON(yuliang.appendingPathComponent("Secrets/credentials.json"))?["values"] as? [String: String]) ?? [:]
        var values: [String: String?] = [:]

        // Claude relays (余量 calls them providers).
        if !FileManager.default.fileExists(atPath: Disk.url("claude-providers.json").path),
           let file = readJSON(yuliang.appendingPathComponent("providers.json")), let list = file["providers"] as? [[String: Any]] {
            let providers: [ClaudeProvider] = list.compactMap { item in
                guard let idText = item["id"] as? String, let id = UUID(uuidString: idText) else { return nil }
                var provider = ClaudeProvider(id: id, name: item["name"] as? String ?? "", baseURL: item["baseURL"] as? String ?? "")
                provider.cnyPerUnit = (item["cnyPerUSD"] as? Double) ?? 1
                if let key = secrets["relay.key.\(idText)"] { values[provider.keyAccount] = key }
                return provider
            }
            if !providers.isEmpty { ClaudeStore.shared.importProviders(providers) }
        }

        // Codex accounts and relays: same file shape and secret names.
        let codexFile = yuliang.appendingPathComponent("codex-profiles.json")
        if !FileManager.default.fileExists(atPath: Disk.url("codex-profiles.json").path),
           let data = try? Data(contentsOf: codexFile) {
            try? data.write(to: Disk.url("codex-profiles.json"), options: .atomic)
            for (account, value) in secrets where account.hasPrefix("codex.") { values[account] = value }
            if let relay = UserDefaults(suiteName: "com.lazymice.yuliang.mac")?.string(forKey: "codex.proxyRelay") {
                defaults.set(relay, forKey: "codex.proxyRelay")
            }
        }
        if !values.isEmpty { try? Secrets.set(values) }
    }

    /// 1.2: new-api system access tokens saved in 余量 for the same Claude relays, for spend per day.
    static func accessTokensOnce() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "import.yuliang.access") else { return }
        defaults.set(true, forKey: "import.yuliang.access")
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Yuliang/Secrets/credentials.json")
        let secrets = (readJSON(url)?["values"] as? [String: String]) ?? [:]
        var values: [String: String?] = [:]
        for provider in ClaudeStore.shared.providers where Secrets.get(provider.accessAccount) == nil {
            if let token = secrets["relay.access.\(provider.id.uuidString)"] { values[provider.accessAccount] = token }
        }
        if !values.isEmpty { try? Secrets.set(values) }
    }

    private static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
