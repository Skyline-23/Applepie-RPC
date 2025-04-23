//
//  Applepie_RPCApp.swift
//  Applepie-RPC
//
//  Created by 김부성 on 4/19/25.
//

import SwiftUI
import AppKit
import ModernSlider
import SwiftData
import Darwin
import Foundation
import Network

@main
struct ApplepieRPCApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(for: AppSettings.self)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }

        // Send initial daemon command based on stored setting
        do {
            let settingsList = try container.mainContext.fetch(FetchDescriptor<AppSettings>())
        } catch {
            print("Failed to fetch AppSettings at launch:", error)
        }
    }

    var body: some Scene {
        MenuBarExtra("Applepie", systemImage: "music.note.house") {
            MainMenuView()
                .environment(\.modelContext, container.mainContext)
        }
        .menuBarExtraStyle(.window)
    }

    private func showAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
    }
}

struct MainMenuView: View {
    @Query private var settings: [AppSettings]
    @Environment(\.modelContext) private var modelContext
    @State private var isHoveringPause = false
    @State private var isHoveringQuit = false
    @State private var selectedHost: String = "Local"
    @StateObject private var browser = AirPlayBrowser()
    @State private var showNowPlaying = false
    @State private var localNowPlaying: String = ""

    var body: some View {
        let setting = settings.first ?? {
            let new = AppSettings()
            modelContext.insert(new)
            return new
        }()

        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Update Interval")
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack {
                    ModernSlider(
                        systemImage: "clock",
                        sliderWidth: 180,
                        sliderHeight: 16,
                        value: Binding(
                            get: { setting.updateInterval },
                            set: { setting.updateInterval = $0 }
                        ),
                        in: 1...15
                    )
                    .padding(.horizontal, -12)
                    .padding(.vertical, -12)
                    Text("\(Int(setting.updateInterval))s")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            // Device Selection
            VStack(alignment: .leading, spacing: 4) {
                Text("Device")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Picker("Device", selection: $selectedHost) {
                    ForEach(browser.hosts, id: \.self) { host in
                        Text(host == "Local" ? "내 Mac" : host)
                            .tag(host)
                    }
                }
                .frame(width: 140)
                .onChange(of: selectedHost) { newHost in
                    if newHost == "Local" {
                        if let delegate = NSApp.delegate as? AppDelegate {
                            delegate.nowPlayingService.fetchAsync { result in
                                localNowPlaying = result
                            }
                        }
                    } else if let port = browser.servicePorts[newHost] {
                        browser.fetchNowPlaying(host: newHost, port: port)
                    }
                }
            }
            .padding(.vertical, 4)

            // Now Playing Info
            VStack(alignment: .leading, spacing: 4) {
                Text("Now Playing")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if selectedHost == "Local" {
                    if localNowPlaying.isEmpty {
                        Text("정보 없음").italic()
                    } else {
                        Text(localNowPlaying)
                    }
                } else {
                    if browser.nowPlaying.isEmpty {
                        Text("정보 없음").italic()
                    } else {
                        ScrollView {
                            Text(browser.nowPlaying)
                                .font(.system(size: 11, weight: .regular, design: .monospaced))
                        }
                        .frame(height: 60)
                    }
                }
                Button("Refresh") {
                    // Trigger a fresh query for selected AirPlay device
                    if selectedHost == "Local" {
                        if let delegate = NSApp.delegate as? AppDelegate {
                            delegate.nowPlayingService.fetchAsync { result in
                                localNowPlaying = result
                            }
                        }
                    } else if let port = browser.servicePorts[selectedHost] {
                        browser.fetchNowPlaying(host: selectedHost, port: port)
                    }
                }
                .buttonStyle(BorderlessButtonStyle())
            }
            .padding(.vertical, 4)
            .onAppear {
                if selectedHost == "Local" {
                    if let delegate = NSApp.delegate as? AppDelegate {
                        delegate.nowPlayingService.fetchAsync { result in
                            localNowPlaying = result
                        }
                    }
                }
            }

            Button {
                // Send command based on current paused state, then toggle
                writeCommand(setting.isPaused ? "RESUME" : "PAUSE")
                do {
                    try modelContext.save()
                    setting.isPaused.toggle()
                } catch {
                    print("Failed to save isPaused:", error)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: setting.isPaused ? "play.fill" : "pause.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 8, height: 8)
                        .padding(6)
                        .background(Circle().fill(Color(NSColor.quaternaryLabelColor)))
                    Text(setting.isPaused ? "Resume Updates" : "Pause Updates")
                    Spacer()
                    Text("⌘R")
                        .font(.system(size: 11))
                        .foregroundColor(.primary.opacity(0.5))
                }
            }
            .buttonStyle(PlainButtonStyle())
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
            .onHover { hovering in isHoveringPause = hovering }
            .background(isHoveringPause ? Color(NSColor.selectedControlColor).opacity(0.2) : Color.clear)
            .cornerRadius(4)
            .keyboardShortcut("r")

            Button {
                NSApp.terminate(nil)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "xmark")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 8, height: 8)
                        .padding(6)
                        .background(Circle().fill(Color(NSColor.quaternaryLabelColor)))
                    Text("Quit")
                    Spacer()
                    Text("⌘Q")
                        .font(.system(size: 11))
                        .foregroundColor(.primary.opacity(0.5))
                }
            }
            .buttonStyle(PlainButtonStyle())
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
            .onHover { hovering in isHoveringQuit = hovering }
            .background(isHoveringQuit ? Color(NSColor.selectedControlColor).opacity(0.2) : Color.clear)
            .cornerRadius(4)
            .keyboardShortcut("q")
        }
        .padding(10)
        .frame(width: 225)
        .onAppear {
            if let delegate = NSApp.delegate as? AppDelegate {
                delegate.discordService?.startPeriodicUpdates(interval: setting.updateInterval) {
                    return delegate.nowPlayingService.fetchSync()
                }
            }
        }
        .onChange(of: setting.updateInterval) { newInterval in
            if let delegate = NSApp.delegate as? AppDelegate {
                delegate.discordService?.startPeriodicUpdates(interval: newInterval) {
                    return delegate.nowPlayingService.fetchSync()
                }
            }
        }
        .onChange(of: localNowPlaying) { _ in
            if let delegate = NSApp.delegate as? AppDelegate {
                delegate.discordService?.startPeriodicUpdates(interval: setting.updateInterval) {
                    return delegate.nowPlayingService.fetchSync()
                }
            }
        }
        .onChange(of: browser.nowPlaying) { _ in
            if let delegate = NSApp.delegate as? AppDelegate {
                delegate.discordService?.startPeriodicUpdates(interval: setting.updateInterval) {
                    return delegate.nowPlayingService.fetchSync()
                }
            }
        }
    }

    private func showAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
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
