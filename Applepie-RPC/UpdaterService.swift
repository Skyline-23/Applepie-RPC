import Foundation

@MainActor
final class UpdaterService: ObservableObject {
    typealias UpdateChannel = AppUpdateChannel
    typealias UpdateResult = AppUpdateResult

    @Published private(set) var updateChannel: UpdateChannel
    @Published private(set) var updateStatusMessage: String = ""
    @Published private(set) var updateLog: [String] = []
    @Published private(set) var lastUpdateSucceeded: Bool?
    @Published private(set) var isUpdating: Bool = false

    private let provider: any UpdateProvider

    init(provider: (any UpdateProvider)? = nil) {
        let resolvedProvider = provider ?? Self.makeDefaultProvider()
        self.provider = resolvedProvider
        self.updateChannel = resolvedProvider.channel
    }

    func checkForUpdates() async -> UpdateResult {
        guard !isUpdating else { return .alreadyRunning }
        lastUpdateSucceeded = nil
        updateLog.removeAll()
        isUpdating = true

        let result = await provider.checkForUpdates(
            appendLog: { [weak self] line in
                self?.appendLog(line)
            },
            setStatus: { [weak self] message in
                self?.updateStatusMessage = message
            }
        )

        switch result {
        case .sparkleOpened:
            isUpdating = false
            lastUpdateSucceeded = nil
        case .homebrewCompleted:
            isUpdating = false
            lastUpdateSucceeded = true
        case .homebrewFailed:
            isUpdating = false
            lastUpdateSucceeded = false
        case .homebrewBinaryMissing:
            isUpdating = false
            lastUpdateSucceeded = false
        case .alreadyRunning:
            isUpdating = false
            lastUpdateSucceeded = nil
        }

        return result
    }

    var homebrewUpgradeCommand: String {
        provider.homebrewUpgradeCommand
    }

    private func appendLog(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updateLog.append(trimmed)
        if updateLog.count > 200 {
            updateLog.removeFirst(updateLog.count - 200)
        }
    }

    private static func makeDefaultProvider() -> any UpdateProvider {
        if isHomebrewManagedInstall() {
            return HomebrewUpdateProvider()
        }
        return SparkleUpdateProvider()
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
