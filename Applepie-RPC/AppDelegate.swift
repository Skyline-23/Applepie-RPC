//
//  AppDelegate.swift
//  Applepie-RPC
//
//  Created by 김부성 on 4/19/25.
//

import Cocoa
import PythonKit
import SwiftData

class AppDelegate: NSObject, NSApplicationDelegate {
    var discordService: DiscordService?
    let nowPlayingService = NowPlayingService()
    private let pythonExecutor = PythonExecutor()
    private let pythonModuleActor: PythonModuleActor

    override init() {
        self.pythonModuleActor = PythonModuleActor(executor: pythonExecutor)
        super.init()
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 1) Set up Python environment
        pythonExecutor.setupEnvironment()
        // 2) Import the discord_service module
        pythonExecutor.importModule(named: "discord_service")
        // 3) Initialize embedded Python and Discord service
        if getenv("XCODE_RUNNING_FOR_PREVIEWS") == nil {
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
            // Create the Discord service
            let service = DiscordService(clientID: "1362417259154374696")
            self.discordService = service
            // Start periodic updates
            service.startPeriodicUpdates(interval: interval) {
                return self.nowPlayingService.fetchSync()
            }
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        // 4) Python 종료
        discordService?.clearActivity()
    }
}

// MARK: - Python Daemon and Utilities
private extension AppDelegate {
    func initializeEmbeddedPython() {
        // Initialize embedded Python via PythonKit
        guard let frameworksURL = Bundle.main.privateFrameworksURL else {
            print("Frameworks URL not found")
            return
        }
        // Point to libpython3.12.dylib
        let libPath = frameworksURL
            .appendingPathComponent("Python.framework")
            .appendingPathComponent("Versions/3.12")
            .appendingPathComponent("Python")
        PythonLibrary.useLibrary(at: libPath.path(percentEncoded: false))

        // Set PYTHONHOME to embedded python location
        let pythonHome = frameworksURL
            .appendingPathComponent("Python.framework")
            .appendingPathComponent("Versions/3.12")
        setenv("PYTHONHOME", pythonHome.path, 1)
        
        // Add embedded C‑extension modules to Python path
        let dynloadPath = Bundle.main.resourceURL!
            .appendingPathComponent("PythonSupport/lib-dynload").path
        let sys = Python.import("sys")
        sys.path.insert(0, dynloadPath)
        
        let stdlibPath = Bundle.main.resourceURL!
          .appendingPathComponent("PythonSupport/python/lib/python3.12").path
        sys.path.insert(1, stdlibPath)

        // Add pip-installed site-packages path
        let sitePackages = Bundle.main.resourceURL!
          .appendingPathComponent("PythonSupport/python/lib/python3.12/site-packages").path
        sys.path.insert(2, sitePackages)

        // Locate the bundled Python script file
        guard let scriptURL = Bundle.main.url(forResource: "applepie-rpc", withExtension: "py") else {
            print("applepie-rpc.py not found in bundle")
            return
        }
        let scriptDir = scriptURL.deletingLastPathComponent().path
        sys.path.append(scriptDir)
    }

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
