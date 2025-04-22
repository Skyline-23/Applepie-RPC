//
//  AppDelegate.swift
//  Applepie-RPC
//
//  Created by 김부성 on 4/19/25.
//

import Cocoa
import Darwin
import SwiftUI
import PythonKit

class AppDelegate: NSObject, NSApplicationDelegate {
    var pythonTask: Process?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 3) Python 데몬 실행 (프리뷰 제외)
        if getenv("XCODE_RUNNING_FOR_PREVIEWS") == nil {
            launchPythonDaemon()
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        // Clean up if needed
        pythonTask?.terminate()
    }
}

// MARK: - Python Daemon and Utilities
private extension AppDelegate {
    func launchPythonDaemon() {
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
        
        print("🔍 libPath: \(libPath.path)")
        print("🔍 libPath exists: \(FileManager.default.fileExists(atPath: libPath.path))")

        print("🔍 pythonHomePath: \(pythonHome.path)")
        print("🔍 pythonHome exists: \(FileManager.default.fileExists(atPath: pythonHome.path))")
        
        // Add embedded C‑extension modules to Python path
        let dynloadPath = Bundle.main.resourceURL!
            .appendingPathComponent("PythonSupport/lib-dynload").path
        let sys = Python.import("sys")
        sys.path.insert(0, dynloadPath)
        
        print("🔍 dynloadPath: \(dynloadPath)")
        print("🔍 dynloadPath exists: \(FileManager.default.fileExists(atPath: dynloadPath))")
        
        let stdlibPath = Bundle.main.resourceURL!
          .appendingPathComponent("PythonSupport/python/lib/python3.12").path
        sys.path.insert(1, stdlibPath)

        // Add pip-installed site-packages path
        let sitePackages = Bundle.main.resourceURL!
          .appendingPathComponent("PythonSupport/python/lib/python3.12/site-packages").path
        sys.path.insert(2, sitePackages)
        print("🔍 sitePackages: \(sitePackages)")
        print("🔍 sitePackages exists: \(FileManager.default.fileExists(atPath: sitePackages))")

        print("🔍 stdlibPath: \(stdlibPath)")
        print("🔍 stdlibPath exists: \(FileManager.default.fileExists(atPath: stdlibPath))")
        
        // Locate the bundled Python script file
        guard let scriptURL = Bundle.main.url(forResource: "applepie-rpc", withExtension: "py") else {
            print("applepie-rpc.py not found in bundle")
            return
        }
        let scriptDir = scriptURL.deletingLastPathComponent().path
        sys.path.append(scriptDir)
        
        let runpy = Python.import("runpy")
        
        // Use runpy to execute the script as __main__
        runpy.run_path(scriptURL.path, run_name: "__main__")
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
