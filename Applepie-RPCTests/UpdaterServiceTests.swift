import SwiftData
import Testing
@testable import Applepie_RPC

@MainActor
final class StubUpdateProvider: UpdateProvider {
    let channel: AppUpdateChannel
    let supportsBetaUpdates: Bool
    let homebrewUpgradeCommand: String
    private(set) var updateTrack: AppUpdateTrack

    init(
        channel: AppUpdateChannel = .sparkle,
        updateTrack: AppUpdateTrack = .stable,
        supportsBetaUpdates: Bool = true,
        homebrewUpgradeCommand: String = "brew upgrade --cask applepie-rpc"
    ) {
        self.channel = channel
        self.updateTrack = updateTrack
        self.supportsBetaUpdates = supportsBetaUpdates
        self.homebrewUpgradeCommand = homebrewUpgradeCommand
    }

    func setIncludesBetaUpdates(_ enabled: Bool) {
        guard supportsBetaUpdates else { return }
        updateTrack = enabled ? .beta : .stable
    }

    func checkForUpdates(
        appendLog: @MainActor @escaping (String) -> Void,
        setStatus: @MainActor @escaping (String) -> Void
    ) async -> AppUpdateResult {
        .alreadyRunning
    }
}

@MainActor
struct UpdaterServiceTests {
    @Test
    func storesBetaPreferenceInSettingsSnapshot() throws {
        let container = try ModelContainer(
            for: AppSettings.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let repository = SwiftDataSettingsRepository(modelContainer: container)

        repository.setIncludesBetaUpdates(true)

        #expect(repository.current.includesBetaUpdates)
    }

    @Test
    func forwardsBetaPreferenceToUpdaterProvider() {
        let provider = StubUpdateProvider()
        let updaterService = UpdaterService(
            provider: provider,
            includesBetaUpdates: false
        )

        updaterService.setIncludesBetaUpdates(true)

        #expect(updaterService.currentState.updateTrack == .beta)
        #expect(updaterService.currentState.supportsBetaUpdates)
    }

    @Test
    func homebrewProviderUsesUpdateIfNeededCommand() {
        let provider = HomebrewUpdateProvider(caskName: "applepie-rpc")

        #expect(
            provider.homebrewUpgradeCommand ==
            "brew update-if-needed && HOMEBREW_NO_AUTO_UPDATE=1 brew upgrade --cask applepie-rpc"
        )
        #expect(provider.updateTrack == .stable)
        #expect(!provider.supportsBetaUpdates)
    }

    @Test
    func homebrewBetaProviderUsesBetaCaskCommand() {
        let provider = HomebrewUpdateProvider(caskName: "applepie-rpc@beta")

        #expect(
            provider.homebrewUpgradeCommand ==
            "brew update-if-needed && HOMEBREW_NO_AUTO_UPDATE=1 brew upgrade --cask applepie-rpc@beta"
        )
        #expect(provider.updateTrack == .beta)
        #expect(!provider.supportsBetaUpdates)
    }
}
