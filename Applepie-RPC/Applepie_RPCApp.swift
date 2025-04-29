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
import Combine

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
                .environmentObject(delegate.nowPlayingService)
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
    @State private var selectedHost: String = "localhost"
    @State private var previousHost: String = "localhost"
    @StateObject private var browser = AirPlayBrowser()
    @EnvironmentObject var nowPlayingService: NowPlayingService

    /// Current AppSettings instance, creating one if missing
    private var setting: AppSettings {
        if let existing = settings.first {
            return existing
        } else {
            let newSetting = AppSettings()
            modelContext.insert(newSetting)
            return newSetting
        }
    }

    var body: some View {
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
                            get: { self.setting.updateInterval },
                            set: {
                                self.setting.updateInterval = $0
                                // Only update timer if not paused
                                if !self.setting.isPaused {
                                    nowPlayingService.updateTimer($0, browser.serviceIPs[selectedHost] ?? "")
                                }
                            }
                        ),
                        in: 1...15
                    )
                    .padding(.horizontal, -12)
                    .padding(.vertical, -12)
                    Text("\(Int(self.setting.updateInterval))s")
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
                        Text(host == "localhost" ? "내 Mac" : host)
                            .tag(host)
                    }
                }
                .frame(width: 140)
                .onChange(of: selectedHost) { newHost in
                    let oldHost = previousHost
                    // Stop now-playing updates for old device
                    nowPlayingService.stop()
                    Task {
                        let newHostIP = browser.serviceIPs[newHost] ?? ""
                        if await nowPlayingService.isPairingNeeded(host: newHostIP) {
                            // Begin pairing: show PIN on Apple TV
                            let began = await nowPlayingService.pairDeviceBegin(host: newHostIP)
                            guard began else {
                                // Revert on failure
                                selectedHost = oldHost
                                return
                            }
                            // Prompt user for PIN
                            guard let pin = promptForPIN(host: newHost) else {
                                selectedHost = oldHost
                                return
                            }
                            // Finish pairing with PIN
                            guard let creds = await nowPlayingService.pairDeviceFinish(host: newHostIP, pin: pin) else {
                                selectedHost = oldHost
                                return
                            }
                            print("[PyatvService] Pairing finished with credentials:", creds)
                        } else {
                            // Only resume updates if not paused
                            if !setting.isPaused {
                                nowPlayingService.updateTimer(setting.updateInterval, newHostIP)
                            }
                            previousHost = newHost
                        }
                        
                        // Only resume updates if not paused
                        if !setting.isPaused {
                            nowPlayingService.updateTimer(setting.updateInterval, newHostIP)
                        }
                        previousHost = newHost
                    }
                }
            }
            .padding(.vertical, 4)

            // Now Playing Info
            VStack(alignment: .leading, spacing: 4) {
                Text("Now Playing")
                    .font(.caption)
                    .foregroundColor(.secondary)
                let title = nowPlayingService.playingData?.title ?? ""
                Text(title.isEmpty ? "정보 없음" : title)
                    .italic(title.isEmpty)
            }
            .padding(.vertical, 4)

            Button {
                // Send command based on current paused state, then toggle
                let hostIP = browser.serviceIPs[selectedHost] ?? ""
                if self.setting.isPaused {
                    // Currently paused → resume updates
                    nowPlayingService.updateTimer(self.setting.updateInterval, hostIP)
                } else {
                    // Currently running → pause updates
                    nowPlayingService.stop()
                }
                do {
                    try modelContext.save()
                    self.setting.isPaused.toggle()
                } catch {
                    print("Failed to save isPaused:", error)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: self.setting.isPaused ? "play.fill" : "pause.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 8, height: 8)
                        .padding(6)
                        .background(Circle().fill(Color(NSColor.quaternaryLabelColor)))
                    Text(self.setting.isPaused ? "Resume Updates" : "Pause Updates")
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
            
            // Clear all stored pairing credentials
            Button {
                Task {
                    selectedHost = "localhost"
                    if await nowPlayingService.clearCache() {
                        showAlert(message: "Cache cleared successfully")
                    } else {
                        showAlert(message: "Cache clearing failed")
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "trash")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 8, height: 8)
                        .padding(6)
                        .background(Circle().fill(Color(NSColor.quaternaryLabelColor)))
                    Text("Clear Cache")
                    Spacer()
                }
            }
            .buttonStyle(PlainButtonStyle())
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
            .onHover { hovering in /* no hover state needed */ }
            .cornerRadius(4)
        }
        .padding(10)
        .frame(width: 225)
    }

    private func showAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
    }
    
    /// Presents a modal dialog to ask user for the pairing PIN.
    private func promptForPIN(host: String) -> Int? {
        let alert = NSAlert()
        alert.messageText = "페어링 PIN 입력"
        alert.informativeText = "기기(\(host)) 화면에 표시된 4자리 PIN 코드를 입력하세요."
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        alert.accessoryView = input
        alert.addButton(withTitle: "확인")
        alert.addButton(withTitle: "취소")
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn, let pin = Int(input.stringValue) else {
            return nil
        }
        return pin
    }
    
}
