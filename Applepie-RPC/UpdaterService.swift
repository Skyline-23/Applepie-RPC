import Foundation
import Sparkle

@MainActor
final class UpdaterService: ObservableObject {
    enum UpdateChannel: Equatable {
        case sparkle
        case homebrew
    }

    enum UpdateTriggerResult: Equatable {
        case sparkle
        case homebrewLaunched
        case homebrewManualFallback
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

    @discardableResult
    func checkForUpdates() -> UpdateTriggerResult {
        switch updateChannel {
        case .sparkle:
            updaterController?.updater.checkForUpdates()
            return .sparkle
        case .homebrew:
            return launchHomebrewUpgradeInTerminal() ? .homebrewLaunched : .homebrewManualFallback
        }
    }

    var homebrewUpgradeCommand: String {
        "brew upgrade --cask applepie-rpc"
    }

    private func launchHomebrewUpgradeInTerminal() -> Bool {
        guard let brewPath = resolveHomebrewPath() else {
            debugLog("[UpdaterService] Homebrew binary not found; falling back to manual command.")
            return false
        }

        let command = "\(brewPath) update && \(brewPath) upgrade --cask applepie-rpc"
        let escapedCommand = Self.escapeForAppleScript(command)
        let script = """
        tell application "Terminal"
            activate
            do script "\(escapedCommand)"
        end tell
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        do {
            try process.run()
            process.waitUntilExit()
            let succeeded = process.terminationStatus == 0
            if !succeeded {
                debugLog("[UpdaterService] Failed to open Terminal for Homebrew update (status=\(process.terminationStatus)).")
            }
            return succeeded
        } catch {
            debugLog("[UpdaterService] Failed to launch Homebrew update via Terminal: \(error)")
            return false
        }
    }

    private func resolveHomebrewPath() -> String? {
        let envCandidates = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { String($0) + "/brew" }
        let fallbackCandidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        let allCandidates = envCandidates + fallbackCandidates
        return allCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func escapeForAppleScript(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
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
