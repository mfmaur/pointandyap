import AppKit
import Sparkle

/// Sparkle: checks pointandyap.com/appcast.xml every 4 hours and at launch, downloads a new version in the background
/// (each download's EdDSA signature is checked against SUPublicEDKey), and installs it on quit. Once one is ready the
/// window shows it with a Restart button. Only the copy in /Applications updates itself.
@MainActor
final class Updater: NSObject, SPUUpdaterDelegate {
    static let shared = Updater()
    private var controller: SPUStandardUpdaterController?
    private var installNow: (() -> Void)?
    weak var state: AppState?

    var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?" }

    func start(state: AppState) {
        self.state = state
        guard AgentInstall.installed, controller == nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
    }

    func checkNow() {
        if let controller { controller.checkForUpdates(nil) } else { state?.showToast("Updates work for the copy in Applications") }
    }

    /// Restart into the downloaded version.
    func restart() {
        Relaunch.cancel()
        installNow?()
    }

    // MARK: SPUUpdaterDelegate

    /// A test feed for checking an update end to end (`defaults write com.marcmaurer.pointandyap updateFeedURL <url>`);
    /// the download must still carry a valid signature.
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        UserDefaults.standard.string(forKey: "updateFeedURL")
    }

    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock: @escaping () -> Void) -> Bool {
        let v = item.displayVersionString
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.installNow = immediateInstallationBlock
                self.state?.updateReady = v
            }
        }
        return true   // we show it ourselves; Sparkle still installs on quit
    }
}
