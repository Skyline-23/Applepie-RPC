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
            if let initial = settingsList.first {
                writeCommand(initial.isPaused ? "PAUSE" : "RESUME")
                writeCommand("INTERVAL:\(Int(initial.updateInterval))")
            }
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

    
    // ───────────────────────────────────────────────────────────────
    // MARK: – Python 데몬 실행/종료 및 명령 쓰기
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

struct MainMenuView: View {
    @Query private var settings: [AppSettings]
    @Environment(\.modelContext) private var modelContext
    @State private var isHoveringPause = false
    @State private var isHoveringQuit = false

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
