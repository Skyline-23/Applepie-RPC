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
    @State private var isHoveringQuit = false
    @State private var isHoveringClearCache = false
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
            // App title with toggle switch and connection status
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(localizable: .appName)
                        .font(.headline)
                    Text(localizable: !setting.isPaused ? .connected : .disconnected)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Toggle(.localizable(.appName), isOn: Binding(
                    get: { !self.setting.isPaused },
                    set: { newValue in
                        self.setting.isPaused = !newValue
                        do {
                            try modelContext.save()
                        } catch {
                            print("Failed to save isPaused:", error)
                        }
                        if self.setting.isPaused {
                            nowPlayingService.stop()
                        } else {
                            nowPlayingService.updateTimer(self.setting.updateInterval, currentHostIP)
                        }
                    }
                ))
                .toggleStyle(SwitchToggleStyle())
                .labelsHidden()
            }
            .padding(.bottom, 8)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(localizable: .updateInterval)
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
                    Text(localizable: .llds(Int(self.setting.updateInterval)))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            // Device Selection
            VStack(alignment: .leading, spacing: 4) {
                Text(localizable: .device)
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
                    // Only perform switch if the host truly changed
                    guard newHost != previousHost else { return }
                    switchHost(to: newHost)
                }
            }
            .padding(.vertical, 4)
            
            // Now Playing Info
            VStack(alignment: .leading, spacing: 4) {
                Text(localizable: .nowPlaying)
                    .font(.caption)
                    .foregroundColor(.secondary)
                let title = nowPlayingService.playingData?.title ?? ""
                Text(title.isEmpty ? .localizable(.noInformation) : title)
                    .bold()
            }
            .padding(.vertical, 4)
            
            // Clear all stored pairing credentials
            Button {
                Task {
                    resetToLocalhost()
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
                    Text(localizable: .clearCache)
                    Spacer()
                }
            }
            .buttonStyle(PlainButtonStyle())
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
            .onHover { hovering in isHoveringClearCache = hovering }
            .background(isHoveringClearCache ? Color(NSColor.selectedControlColor).opacity(0.2) : Color.clear)
            .cornerRadius(4)
            
            // Quit application
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
                    Text(localizable: .quit)
                    Spacer()
                    Text(localizable: .q)
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
                let began = await nowPlayingService.pairDeviceBegin(host: newHostIP)
                guard began else {
                    showAlert(message: .localizable(.pairingFailed))
                    selectedHost = oldHost
                    return
                }
                // Await PIN input
                if let pin = await showPINWindow() {
                    if let creds = await nowPlayingService.pairDeviceFinish(host: newHostIP, pin: pin) {
                        print("[PyatvService] Pairing finished with credentials:", creds)
                        nowPlayingService.updateTimer(setting.updateInterval, newHostIP)
                        previousHost = newHost
                    } else {
                        print("[PyatvService] Pairing failed")
                        showAlert(message: .localizable(.pairingFailed))
                        selectedHost = oldHost
                    }
                } else {
                    _ = await nowPlayingService.pairDeviceCancel(host: newHostIP)
                    selectedHost = oldHost
                }
                return
            }
            nowPlayingService.updateTimer(setting.updateInterval, newHostIP)
            previousHost = newHost
        }
    }
    
    private func resetToLocalhost() {
        // Reset to localhost
        selectedHost = .localizable(.localhostName)
        previousHost = .localizable(.localhostName)
        nowPlayingService.updateTimer(setting.updateInterval, "localhost")
    }
    
    /// Display PIN entry window and await user input
    private func showPINWindow() async -> Int? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Int?, Never>) in
            var pinWindow: NSWindow? = nil
            // Create SwiftUI content view
            let contentView = PINPromptWindow { pin in
                pinWindow?.close()
                continuation.resume(returning: pin)
            }
            // Wrap in hosting controller
            let hostingController = NSHostingController(rootView: contentView)
            // Create window
            pinWindow = NSWindow(contentViewController: hostingController)
            pinWindow?.titleVisibility = .hidden
            pinWindow?.titlebarAppearsTransparent = true
            pinWindow?.isOpaque = false
            pinWindow?.backgroundColor = .clear
            pinWindow?.styleMask = [.titled, .closable]
            // Insert fullSizeContentView and customize titlebar buttons
            pinWindow?.styleMask.insert(.fullSizeContentView)
            pinWindow?.standardWindowButton(.closeButton)?.isHidden = true
            pinWindow?.standardWindowButton(.miniaturizeButton)?.isHidden = true
            pinWindow?.standardWindowButton(.zoomButton)?.isHidden = true
            pinWindow?.isMovableByWindowBackground = true
            // Set window content size and recenter
            pinWindow?.setContentSize(NSSize(width: 350, height: 200))
            pinWindow?.center()
            pinWindow?.level = .floating
            pinWindow?.makeKeyAndOrderFront(nil)
        }
    }
    
    
    private func showAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
    }
}

struct PINPromptWindow: View {
    @State private var digits = ["", "", "", ""]
    var onComplete: (Int?) -> Void
    
    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 4) {
                Text(localizable: .enterPairingPINNumber)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text(localizable: .enterThe4PINNumbersOnTheScreen)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            PINEntryView(digits: $digits)  // Update PINEntryView to accept binding
            HStack(spacing: 12) {
                Button("Deny") {
                    // Cancel pairing session on Python side
                    onComplete(nil)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .tint(.secondary)
                Button("Confirm") {
                    let pin = Int(digits.joined())
                    onComplete(pin)
                }
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)
                .controlSize(.large)
            }
        }
        .onChange(of: digits) { newDigits in
            if newDigits.allSatisfy({ $0.count == 1 }) {
                if let pin = Int(newDigits.joined()) {
                    onComplete(pin)
                }
            }
        }
        .padding(20)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.95))
        .cornerRadius(12)
        .frame(width: 300)
    }
}

/// A NSTextField subclass that only accepts numeric input and handles delete-backward.
class NumericDeleteAwareTextField: NSTextField {
    override func keyDown(with event: NSEvent) {
        // Allow digits and backspace (keyCode 51)
        if let chars = event.characters, chars.allSatisfy({ $0.isNumber }) || event.keyCode == 51 {
            super.keyDown(with: event)
        } else {
            NSSound.beep()
        }
    }
}

// A NSTextField that notifies about delete-backward when its content is already empty
struct DeleteAwareTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onDeleteBackward: () -> Void
    var onTextChange: (String) -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NumericDeleteAwareTextField(string: "")
        field.focusRingType = .none
        field.placeholderString = placeholder
        field.isBezeled = false
        field.drawsBackground = false
        field.font = NSFont.systemFont(ofSize: 18)
        field.alignment = .center
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: DeleteAwareTextField

        init(parent: DeleteAwareTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            let newValue = field.stringValue.filter { $0.isNumber }.prefix(1)
            let newString = String(newValue)
            self.parent.text = newString
            self.parent.onTextChange(newString)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.deleteBackward(_:)) {
                if parent.text.isEmpty {
                    parent.onDeleteBackward()
                    return true
                }
            }
            return false
        }
    }
}

/// SwiftUI view for entering a 4-digit PIN
struct PINEntryView: View {
    @Binding var digits: [String]
    @FocusState private var focusIndex: Int?
    @State private var previousDigits = ["", "", "", ""]
    
    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<4, id: \.self) { idx in
                DeleteAwareTextField(
                    text: $digits[idx],
                    placeholder: "",
                    onDeleteBackward: {
                        if idx > 0 {
                            focusIndex = idx - 1
                        }
                    },
                    onTextChange: { first in
                        // Auto-advance when a digit was entered
                        if !first.isEmpty && idx < 3 {
                            focusIndex = idx + 1
                        }
                    }
                )
                .frame(width: 50, height: 50)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(focusIndex == idx ? Color.secondary.opacity(0.6) : Color.secondary.opacity(0.3))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                )
                .foregroundColor(Color(NSColor.controlTextColor))
                .font(.system(size: 18))
                .focused($focusIndex, equals: idx)
            }
        }
        .padding(8)
        .onAppear {
            focusIndex = 0
            previousDigits = digits
        }
    }
    
    /// Returns the concatenated PIN string
    func pinString() -> String {
        digits.joined()
    }
}
