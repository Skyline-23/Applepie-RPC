//
//  AppDelegate.swift
//  Applepie-RPC
//
//  Created by 김부성 on 4/19/25.
//

import Cocoa
import MusicKit
import ApplicationServices

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var discordService: (any DiscordServiceProviding)?
    var pyatvService: PyatvService?
    private let appContainer = AppContainer()
    var nowPlayingService: NowPlayingService { appContainer.nowPlayingService }
    var playbackControlService: PlaybackControlService { appContainer.playbackControlService }
    var updaterService: UpdaterService { appContainer.updaterService }
    var settingsRepository: SwiftDataSettingsRepository { appContainer.settingsRepository }
    var mainMenuViewModel: MainMenuViewModel { appContainer.mainMenuViewModel }
    private let syncPresenceUseCase = SyncPresenceUseCase()
    private let sentryBootstrapService = SentryBootstrapService()
    private var settingsObservationTask: Task<Void, Never>?

    override init() {
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            await appContainer.installPythonLogForwarders()
        }

        sentryBootstrapService.startIfConfigured()

        // Request Accessibility permission if needed
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            debugLog("[Lifecycle] Accessibility permission not granted")
            let alert = NSAlert()
            alert.messageText = .localizable(.permissionRequired)
            alert.informativeText = .localizable(.permissionRequiredDesc)
            alert.alertStyle = .warning
            alert.runModal()
            errorLog("[AppDelegate] Accessibility permission not granted; leaving app running.")
            return
        }

        let interval = settingsRepository.current.updateInterval

        settingsObservationTask?.cancel()
        settingsObservationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var previous = self.settingsRepository.current
            let stream = self.settingsRepository.makeSettingsStream()
            for await snapshot in stream {
                if Task.isCancelled { return }
                if snapshot.isPaused != previous.isPaused {
                    self.syncPresenceUseCase.handlePauseStateChanged()
                }
                if snapshot.updateInterval != previous.updateInterval {
                    self.discordService?.setClearInterval(snapshot.updateInterval)
                }
                if snapshot.includesBetaUpdates != previous.includesBetaUpdates {
                    self.updaterService.setIncludesBetaUpdates(snapshot.includesBetaUpdates)
                }
                previous = snapshot
            }
        }

        // Async RPC initialization and start updates
        Task { @MainActor in
            // Request Apple Music authorization once at startup
            let authStatus = await MusicAuthorization.request()
            let musicAuthorized = authStatus == .authorized
            if !musicAuthorized {
                debugLog("⚠️ Apple Music authorization denied: \(authStatus)")
            }

            let runtimeServices = await appContainer.makeRuntimeServices(
                musicAuthorized: musicAuthorized,
                updateInterval: interval
            )
            let discordService = runtimeServices.discordService
            let pyatvService = runtimeServices.pyatvService

            self.discordService = discordService
            self.pyatvService = pyatvService
            discordService.onConnectionStateChange = { [weak self] state in
                Task { @MainActor in
                    self?.nowPlayingService.setDiscordConnection(state)
                }
            }
            nowPlayingService.setDiscordConnection(discordService.connectionState)

            // Start periodic fetching in NowPlayingService
            nowPlayingService.start(interval: interval, host: "localhost")

            syncPresenceUseCase.start(
                discordService: discordService,
                playbackStateSource: nowPlayingService,
                isPaused: { [weak self] in
                    self?.settingsRepository.current.isPaused ?? false
                }
            )
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        debugLog("[AppDelegate] applicationWillTerminate")
        settingsObservationTask?.cancel()
        settingsObservationTask = nil
        syncPresenceUseCase.stop(clearPresence: true)
        nowPlayingService.stop()
    }
}
