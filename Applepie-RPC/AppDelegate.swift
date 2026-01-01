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
import PylibKit_Mac
import Sparkle

class AppDelegate: NSObject, NSApplicationDelegate {
    var discordService: DiscordService?
    var pyatvService: PyatvService?
    let nowPlayingService = NowPlayingService()
    private let pythonExecutor = PythonExecutor(threadName: "PylibKitThread")
    private var cancellables = Set<AnyCancellable>()
    private var appSettings: AppSettings?
    var container: ModelContainer?
    private var updaterController: SPUStandardUpdaterController?
    
    override init() {
        super.init()
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Request Accessibility permission if needed
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            let alert = NSAlert()
            alert.messageText = .localizable(.permissionRequired)
            alert.informativeText = .localizable(.permissionRequiredDesc)
            alert.alertStyle = .warning
            alert.runModal()
            NSApp.terminate(nil)
        }
        
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        if let updater = updaterController?.updater {
            updater.automaticallyChecksForUpdates = true
            updater.automaticallyDownloadsUpdates = true
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
                    self.appSettings = updated
                }
            }
            .store(in: &cancellables)
        
        // Async RPC initialization and start updates
        Task { @MainActor in
            // Request Apple Music authorization once at startup
            let authStatus = await MusicAuthorization.request()
            guard authStatus == .authorized else {
                debugLog("⚠️ Apple Music authorization denied: \(authStatus)")
                return
            }
            // Create and initialize the DiscordService using the async factory
            let discordService = await DiscordService.create(
                clientID: "1362417259154374696",
                executor: pythonExecutor
            )
            let pyatvService = await PyatvService.create(
                executor: pythonExecutor
            )
            
            self.discordService = discordService
            self.pyatvService = pyatvService
            nowPlayingService.setATVService(pyatvService)
            discordService.onConnectionStateChange = { [weak self] state in
                Task { @MainActor in
                    self?.nowPlayingService.setDiscordConnection(state)
                }
            }
            nowPlayingService.setDiscordConnection(discordService.connectionState)
            
            // Start periodic fetching in NowPlayingService
            nowPlayingService.start(interval: interval, host: "localhost")
            
            // Subscribe to updates and forward to DiscordService
            nowPlayingService.$playingData
                .sink { [weak self] data in
                    guard
                        let self = self,
                        let discord = self.discordService,
                        let setting = self.appSettings
                    else {
                        return
                    }
                    Task {
                        if setting.isPaused {
                            await discord.clearActivity()
                            return
                        }
                        if let data = data {
                            await discord.setActivity(
                                trackID: data.trackID,
                                title: data.title,
                                artist: data.artist ?? "",
                                album: data.album,
                                position: data.position,
                                duration: data.duration
                            )
                        } else {
                            await discord.clearActivity()
                        }
                    }
                }
                .store(in: &cancellables)
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        // 4) Python 종료
        Task {
            await discordService?.clearActivity()
        }
    }
}
