//
//  AppContainer.swift
//  Applepie-RPC
//

import Foundation
import PylibKit_Mac

@MainActor
final class AppContainer {
    struct RuntimeServices {
        let discordService: any DiscordServiceProviding
        let pyatvService: PyatvService
    }

    let nowPlayingService: NowPlayingService
    let playbackControlService: PlaybackControlService
    let updaterService: UpdaterService
    let settingsRepository: SwiftDataSettingsRepository
    let airPlayBrowser: AirPlayBrowser
    let mainMenuViewModel: MainMenuViewModel
    let pythonExecutor: PythonExecutor

    private let discordClientID: String

    init(
        nowPlayingService: NowPlayingService = NowPlayingService(),
        settingsRepository: SwiftDataSettingsRepository? = nil,
        pythonExecutor: PythonExecutor = PythonExecutor(threadName: "PylibKitThread"),
        discordClientID: String = "1362417259154374696"
    ) {
        self.nowPlayingService = nowPlayingService
        self.playbackControlService = PlaybackControlService(nowPlayingService: nowPlayingService)
        self.updaterService = UpdaterService()
        self.settingsRepository = settingsRepository ?? SwiftDataSettingsRepository()
        self.airPlayBrowser = AirPlayBrowser()
        self.pythonExecutor = pythonExecutor
        self.discordClientID = discordClientID
        self.mainMenuViewModel = MainMenuViewModel(
            nowPlayingService: nowPlayingService,
            playbackControlService: playbackControlService,
            updaterService: updaterService,
            settingsRepository: self.settingsRepository,
            airPlayBrowser: airPlayBrowser
        )
    }

    func installPythonLogForwarders() async {
        await pythonExecutor.installPythonLogForwarders(logLevel: .info)
    }

    func makeRuntimeServices(
        musicAuthorized: Bool,
        updateInterval: TimeInterval
    ) async -> RuntimeServices {
        let discordService = await DiscordService.create(
            clientID: discordClientID,
            executor: pythonExecutor
        )
        let pyatvService = await PyatvService.create(
            executor: pythonExecutor
        )

        await nowPlayingService.setATVService(pyatvService)
        playbackControlService.setDiscordService(discordService)
        discordService.setMusicKitEnabled(musicAuthorized)
        discordService.setClearInterval(updateInterval)

        return RuntimeServices(
            discordService: discordService,
            pyatvService: pyatvService
        )
    }
}
