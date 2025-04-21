//
//  AppDelegate.swift
//  Applepie-RPC
//
//  Created by 김부성 on 4/19/25.
//

import Cocoa
import Darwin
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var pythonTask: Process?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 3) Python 데몬 실행 (프리뷰 제외)
        if getenv("XCODE_RUNNING_FOR_PREVIEWS") == nil {
//            launchPythonDaemon()
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
        guard let binURL = Bundle.main.url(forResource: "applepie-rpc", withExtension: nil) else {
            return
        }
        print("Launching Python daemon at: \(binURL.path)")
        let task = Process()
        task.executableURL = binURL

        let outPipe = Pipe(), errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError  = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            if let str = String(data: handle.availableData, encoding: .utf8),
               !str.isEmpty {
                print("🐍 stdout:", str.trimmingCharacters(in: .newlines))
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            if let str = String(data: handle.availableData, encoding: .utf8),
               !str.isEmpty {
                print("🐍 stderr:", str.trimmingCharacters(in: .newlines))
            }
        }

        do {
            try task.run()
            pythonTask = task
            task.terminationHandler = { p in
                DispatchQueue.main.async {
                    print("❌ Python daemon terminated with exit code \(p.terminationStatus)")
                }
            }
        } catch {
            print("❌ Failed to run Python:", error)
        }
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
