import Foundation
import Sparkle

@MainActor
final class UpdaterService: ObservableObject {
    enum UpdateChannel: Equatable {
        case sparkle
        case homebrew
    }

    @Published private(set) var updateChannel: UpdateChannel

    /// `nil` when updates are managed externally (e.g. Homebrew).
    private let updaterController: SPUStandardUpdaterController?

    init() {
        if Self.isHomebrewManagedInstall() {
            updateChannel = .homebrew
            updaterController = nil
            return
        }

        updateChannel = .sparkle
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        controller.updater.automaticallyChecksForUpdates = true
        controller.updater.automaticallyDownloadsUpdates = true
        updaterController = controller
    }

    func checkForUpdates() {
        updaterController?.updater.checkForUpdates()
    }

    var homebrewUpgradeCommand: String {
        "brew upgrade --cask applepie-rpc"
    }

    /// Best-effort detection to avoid Homebrew-managed app bundles being modified by Sparkle.
    /// Sparkle self-updates are great for direct installs, but fight with cask-managed upgrades.
    private static func isHomebrewManagedInstall() -> Bool {
        let resolvedBundlePath = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        if resolvedBundlePath.contains("/Caskroom/") {
            return true
        }

        // If the cask exists, prefer Homebrew as the update authority.
        // This is intentionally conservative; users can still update via Homebrew even if the app
        // was moved to /Applications.
        let caskName = "applepie-rpc"
        let candidateCaskrooms = [
            "/opt/homebrew/Caskroom/\(caskName)",
            "/usr/local/Caskroom/\(caskName)"
        ]
        return candidateCaskrooms.contains { FileManager.default.fileExists(atPath: $0) }
    }
}
