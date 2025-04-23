//
//  AppDelegate.swift
//  Applepie-RPC
//
//  Created by 김부성 on 4/19/25.
//

import Cocoa
import SwiftData

class AppDelegate: NSObject, NSApplicationDelegate {
    var discordService: DiscordService?
    let nowPlayingService = NowPlayingService()
    private let pythonExecutor = PythonExecutor()

    override init() {
        super.init()
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Load saved update interval from AppSettings
        var interval: Double = 1.0
        do {
            let container = try ModelContainer(for: AppSettings.self)
            let list = try container.mainContext.fetch(FetchDescriptor<AppSettings>())
            if let setting = list.first {
                interval = setting.updateInterval
            }
        } catch {
            print("Failed to fetch updateInterval:", error)
        }

        // 3) Async RPC initialization and start updates
        Task { @MainActor in
            // 1) Set up Python environment synchronously
            await pythonExecutor.setupEnvironment()

            // 2) Create and initialize the DiscordService using the async factory
            let service = await DiscordService.create(
                clientID: "1362417259154374696",
                executor: pythonExecutor
            )
            self.discordService = service
            service.startPeriodicUpdates(interval: interval) {
                return self.nowPlayingService.fetchSync()
            }
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        // 4) Python 종료
        Task {
            await discordService?.clearActivity()
        }
    }
}

// MARK: - Python Daemon and Utilities
private extension AppDelegate {
    func writeCommand(_ cmd: String) {
        let cmdURL = URL(fileURLWithPath: "/tmp/applepie_rpc_cmd")
        let data = (cmd + "\n").data(using: .utf8)!
        if FileManager.default.fileExists(atPath: cmdURL.path) {
            if let handle = try? FileHandle(forWritingTo: cmdURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            try? data.write(to: cmdURL)
        }
    }
}
