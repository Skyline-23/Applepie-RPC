//
//  AppDelegate.swift
//  Applepie-RPC
//
//  Created by 김부성 on 4/19/25.
//

import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var pythonTask: Process?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 1) 메뉴 바 아이콘 생성
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "music.note.house", accessibilityDescription: "Applepie")
            button.action = #selector(toggleMenu(_:))
        }

        // 2) 메뉴 항목 구성
        let menu = NSMenu()
        menu.addItem(.init(title: "Pause Updates", action: #selector(pauseUpdates), keyEquivalent: "p"))
        menu.addItem(.init(title: "Resume Updates", action: #selector(resumeUpdates), keyEquivalent: "r"))
        menu.addItem(.separator())
        menu.addItem(.init(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu

        // 3) Python 데몬 실행
        launchPythonDaemon()
    }

    @objc func toggleMenu(_ sender: Any?) {
        // 메뉴를 현재 마우스 위치에 팝업
        statusItem.menu?.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    func launchPythonDaemon() {
        guard let binURL = Bundle.main.url(forResource: "applepie-rpc", withExtension: nil) else {
            print("❌ Python binary not found")
            return
        }
        let task = Process()
        task.executableURL = binURL
        task.arguments = []  // 데몬 모드 기본 실행
        task.standardOutput = Pipe()
        task.standardError  = Pipe()
        do {
            try task.run()
            pythonTask = task
        } catch {
            print("❌ Failed to run Python:", error)
        }
    }

    @objc func pauseUpdates() {
        writeCommand("PAUSE")
    }

    @objc func resumeUpdates() {
        writeCommand("RESUME")
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

    @objc func quit() {
        // SIGINT 보내서 Python 쪽 cleanup_and_exit 호출
        pythonTask?.interrupt()
        NSApp.terminate(nil)
    }
}
