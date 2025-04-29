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
import Combine

@main
struct ApplepieRPCApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    // Fallback container if AppDelegate's container is not available
    private let defaultContainer: ModelContainer = {
        do {
            return try ModelContainer(for: AppSettings.self)
        } catch {
            fatalError("Failed to create fallback ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        MenuBarExtra(.localizable(.appName), systemImage: "music.note.house") {
            MainMenuView()
                .environment(\.modelContext, delegate.container?.mainContext ?? defaultContainer.mainContext)
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
    @State private var selectedHost: String = .localizable(.localhostName)
    @State private var previousHost: String = .localizable(.localhostName)
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

    /// Returns the IP address for the currently selected host.
    private var currentHostIP: String {
        browser.serviceIPs[selectedHost] ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 4) {
                Text(.localizable(.updateInterval))
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
                                nowPlayingService.updateTimer($0, browser.serviceIPs[selectedHost] ?? "")
                            }
                        ),
                        in: 1...15
                    )
                    .padding(.horizontal, -12)
                    .padding(.vertical, -12)
                    Text(.localizable(.llds(Int(self.setting.updateInterval))))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            // Device Selection
            VStack(alignment: .leading, spacing: 4) {
                Text(.localizable(.device))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Picker(.localizable(.device), selection: $selectedHost) {
                    ForEach(browser.hosts, id: \.self) { host in
                        Text(host)
                            .tag(host)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .onChange(of: selectedHost) { newHost in
                    switchHost(to: newHost)
                }
            }
            .padding(.vertical, 4)

            // Now Playing Info
            VStack(alignment: .leading, spacing: 4) {
                Text(.localizable(.nowPlaying))
                    .font(.caption)
                    .foregroundColor(.secondary)
                let title = nowPlayingService.playingData?.title ?? ""
                Text(title.isEmpty ? .localizable(.noInformation) : title)
                    .italic(title.isEmpty)
            }
            .padding(.vertical, 4)

            Button {
                do {
                    self.setting.isPaused.toggle()
                    try modelContext.save()
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
                    Text(self.setting.isPaused ? .localizable(.resumeUpdates) : .localizable(.pauseUpdates))
                    Spacer()
                    Text(.localizable(.r))
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
                    Text(.localizable(.quit))
                    Spacer()
                    Text(.localizable(.q))
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
                    switchHost(to: "localhost")
                    if await nowPlayingService.clearCache() {
                        showAlert(message: .localizable(.cacheClearedSuccessfully))
                    } else {
                        showAlert(message: .localizable(.cacheClearingFailed))
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
                    Text(.localizable(.clearCache))
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
    
    // MARK: - Methods

    /// Handle switching to a new host: stop updates, perform pairing if needed, then resume.
    private func switchHost(to newHost: String) {
        let oldHost = previousHost
        // Stop now-playing updates for old device
        nowPlayingService.stop()
        Task {
            let newHostIP = browser.serviceIPs[newHost] ?? ""
            if await nowPlayingService.isPairingNeeded(host: newHostIP) {
                // Begin pairing: show PIN on Apple TV
                let began = await nowPlayingService.pairDeviceBegin(host: newHostIP)
                guard began, let pin = promptForPIN(host: newHost) else {
                    // Revert selection on failure
                    selectedHost = oldHost
                    return
                }
                guard let creds = await nowPlayingService.pairDeviceFinish(host: newHostIP, pin: pin) else {
                    selectedHost = oldHost
                    return
                }
                print("[PyatvService] Pairing finished with credentials:", creds)
            }
            nowPlayingService.updateTimer(setting.updateInterval, currentHostIP)
            previousHost = newHost
        }
    }

    private func showAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
    }
    
    /// Presents a modal dialog to ask user for the pairing PIN.
    private func promptForPIN(host: String) -> Int? {
        let alert = NSAlert()
        alert.messageText = .localizable(.enterPairingPINNumber)
        alert.informativeText = .localizable(.enterThe4PINNumbersOnTheScreen)
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        alert.accessoryView = input
        alert.addButton(withTitle: .localizable(.confirm))
        alert.addButton(withTitle: .localizable(.deny))
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn, let pin = Int(input.stringValue) else {
            return nil
        }
        return pin
    }
}
