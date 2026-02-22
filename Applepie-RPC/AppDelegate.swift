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
import Dispatch
import Sentry

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var discordService: (any DiscordServiceProviding)?
    var pyatvService: PyatvService?
    private let appContainer = AppContainer()
    var nowPlayingService: NowPlayingService { appContainer.nowPlayingService }
    var playbackControlService: PlaybackControlService { appContainer.playbackControlService }
    var updaterService: UpdaterService { appContainer.updaterService }
    private var cancellables = Set<AnyCancellable>()
    private var appSettings: AppSettings?
    private var lastObservedPausedState: Bool?
    private let presenceCoordinator = DiscordPresenceCoordinator()

    var container: ModelContainer?

    override init() {
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            await appContainer.installPythonLogForwarders()
        }

        startSentryIfConfigured()

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

        // Load saved update interval from AppSettings
        var interval: Double = 1.0
        do {
            self.container = try ModelContainer(for: AppSettings.self)
            let list = try container?.mainContext.fetch(FetchDescriptor<AppSettings>())
            if let setting = list?.first {
                self.appSettings = setting
            } else {
                let newSetting = AppSettings()
                container?.mainContext.insert(newSetting)
                self.appSettings = newSetting
            }
            if let setting = self.appSettings {
                interval = setting.updateInterval
                lastObservedPausedState = setting.isPaused
            }
        } catch {
            debugLog("Failed to fetch AppSettings:", error)
        }

        // Observe SwiftData save notifications to refresh AppSettings
        NotificationCenter.default
            .publisher(for: ModelContext.didSave)
            .sink { [weak self] _ in
                guard let self = self, let context = self.container?.mainContext else { return }
                if let updated = try? context.fetch(FetchDescriptor<AppSettings>()).first {
                    let previousPaused = self.lastObservedPausedState ?? false
                    self.appSettings = updated
                    self.lastObservedPausedState = updated.isPaused

                    self.presenceCoordinator.handlePauseTransition(
                        isPaused: updated.isPaused,
                        wasPaused: previousPaused,
                        discordService: self.discordService
                    )
                }
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

            await discordService.clearActivity(allowStart: true)

            // Start periodic fetching in NowPlayingService
            nowPlayingService.start(interval: interval, host: "localhost")

            presenceCoordinator.start(
                discordService: discordService,
                nowPlayingService: nowPlayingService,
                isPaused: { [weak self] in
                    self?.appSettings?.isPaused == true
                }
            )
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        debugLog("[AppDelegate] applicationWillTerminate")
        presenceCoordinator.stop()
        nowPlayingService.stop()

        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await discordService?.clearActivity(allowStart: false)
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 1.0)
    }

    private func startSentryIfConfigured() {
        let info = Bundle.main.infoDictionary ?? [:]
        let rawDSN = info["SentryDSN"] as? String
        let dsn = rawDSN?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if dsn.isEmpty || dsn.contains("SENTRY_DSN") || dsn.contains("$(") {
            debugLog("[Sentry] DSN not configured; skipping Sentry init")
            return
        }

        let environmentFromInfo = (info["SentryEnvironment"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let version = (info["CFBundleShortVersionString"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
        let bundleID = Bundle.main.bundleIdentifier ?? "Applepie-RPC"

        SentrySDK.start { options in
            options.dsn = dsn
            options.releaseName = version
            if let env = environmentFromInfo, !env.isEmpty {
                options.environment = env
            } else {
                options.environment = "production"
            }
            options.enableCrashHandler = true
            options.attachStacktrace = true
        }

        SentrySDK.configureScope { scope in
            scope.setTag(value: bundleID, key: "bundle_id")
            scope.setTag(value: version, key: "app_version")
        }
    }
}
