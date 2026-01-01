import Foundation
import Sparkle

@MainActor
final class UpdaterService: ObservableObject {
    private let updaterController: SPUStandardUpdaterController

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        updaterController.updater.automaticallyChecksForUpdates = true
        updaterController.updater.automaticallyDownloadsUpdates = true
    }

    func checkForUpdates() {
        updaterController.updater.checkForUpdates()
    }
}
