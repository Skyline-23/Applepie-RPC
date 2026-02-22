//
//  AppDelegate.swift
//  Applepie-RPC
//
//  Created by 김부성 on 4/19/25.
//

import Cocoa
import SwiftData
import MusicKit
import Combine
import ApplicationServices

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var discordService: (any DiscordServiceProviding)?
    var pyatvService: PyatvService?
    private let appContainer = AppContainer()
    var nowPlayingService: NowPlayingService { appContainer.nowPlayingService }
    var playbackControlService: PlaybackControlService { appContainer.playbackControlService }
    var updaterService: UpdaterService { appContainer.updaterService }
    private var cancellables = Set<AnyCancellable>()
    private let appSettingsService = AppSettingsService()
    private let syncPresenceUseCase = SyncPresenceUseCase()
    private let sentryBootstrapService = SentryBootstrapService()

    var container: ModelContainer? { appSettingsService.container }

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

        let interval = appSettingsService.loadOrCreate()

        // Observe SwiftData save notifications to refresh AppSettings
        appSettingsService
            .observeChanges { [weak self] updated, previousPaused in
                guard let self else { return }
                guard updated.isPaused != previousPaused else { return }
                self.syncPresenceUseCase.handlePauseStateChanged()
            }
            .store(in: &cancellables)

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
            nowPlayingService.$updateInterval
                .removeDuplicates()
                .sink { [weak self] newInterval in
                    self?.discordService?.setClearInterval(newInterval)
                }
                .store(in: &cancellables)
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
                nowPlayingService: nowPlayingService,
                isPaused: { [weak self] in
                    self?.appSettingsService.isPaused ?? false
                }
            )
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        debugLog("[AppDelegate] applicationWillTerminate")
        syncPresenceUseCase.stop(clearPresence: true)
        nowPlayingService.stop()
    }
}
