import AppKit
import Sparkle

/// Sparkle: checks the appcast on GitHub (every 6 hours and from 检查更新…), shows what changed and installs on
/// the user's say-so. Updates are accepted only when signed with the release key (SUPublicEDKey).
@MainActor
final class Updates: NSObject, SPUUpdaterDelegate {
    static let shared = Updates()

    private(set) lazy var controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
    var updater: SPUUpdater { controller.updater }

    func start() { _ = controller }

    @objc func checkForUpdates(_ sender: Any?) { controller.checkForUpdates(sender) }

    /// For testing a release before it is public: `defaults write com.lazymice.swapdeck debug.feedURL <url>`.
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        UserDefaults.standard.string(forKey: "debug.feedURL")
    }
}
