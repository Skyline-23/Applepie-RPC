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
            debugLog("[SwiftData] Failed to create default ModelContainer:", error)
            do {
                let inMemory = ModelConfiguration(isStoredInMemoryOnly: true)
                return try ModelContainer(for: AppSettings.self, configurations: inMemory)
            } catch {
                errorLog("[SwiftData] Failed to create in-memory ModelContainer:", error)
                fatalError("Failed to create any ModelContainer: \(error)")
            }

        }
    }()
    
    var body: some Scene {
        MenuBarExtra {
            MainMenuView()
                .environment(\.modelContext, delegate.container?.mainContext ?? defaultContainer.mainContext)
                .environmentObject(delegate.nowPlayingService)
                .environmentObject(delegate.updaterService)
        } label: {
            Label {
                Text(localizable: .appName)
            } icon: {
                Image("MenuBarIcon")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)
            }
            .labelStyle(.iconOnly)
        }
        .menuBarExtraStyle(.window)
    }
    
    private func showAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
    }
}

struct StatusDot: View {
    let state: ConnectionState

    private var color: Color {
        state == .connected ? Color(NSColor.systemGreen) : Color(NSColor.systemRed)
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
    }
}

struct StatusRow: View {
    let title: LocalizedStringKey
    let state: ConnectionState

    private var statusKey: LocalizableKey {
        state == .connected ? .connected : .disconnected
    }

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(state: state)
            Text(title)
                .font(.caption)
            Text(localizable: statusKey)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
    }
}

struct MainMenuView: View {
    @Query private var settings: [AppSettings]
    @Environment(\.modelContext) private var modelContext
    @State private var isHoveringQuit = false
    @State private var isHoveringClearCache = false
    @State private var isHoveringCheckUpdates = false
    @State private var selectedHost: String = .localizable(.localhostName)
    @State private var previousHost: String = .localizable(.localhostName)
    @State private var deviceMenuLayoutID = UUID()
    @State private var updatePopupWindow: NSWindow?
    @StateObject private var browser = AirPlayBrowser()
    @EnvironmentObject var nowPlayingService: NowPlayingService
    @EnvironmentObject var updaterService: UpdaterService
    
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
    
    private var effectiveDeviceConnection: ConnectionState {
        setting.isPaused ? .disconnected : nowPlayingService.deviceConnection
    }
    
    private func statusKey(for state: ConnectionState) -> LocalizableKey {
        state == .connected ? .connected : .disconnected
    }

    private var updateChannelName: String {
        switch updaterService.updateChannel {
        case .sparkle:
            return "Sparkle"
        case .homebrew:
            return "Homebrew"
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // App title with toggle switch and connection status
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(localizable: .appName)
                        .font(.headline)
                    Text(localizable: statusKey(for: effectiveDeviceConnection))
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
                            debugLog("Failed to save isPaused:", error)
                        }
                        if self.setting.isPaused {
                            nowPlayingService.stop()
                            Task {
                                await (NSApplication.shared.delegate as? AppDelegate)?
                                    .discordService?
                                    .clearActivity(allowStart: false)
                            }
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
                Text(localizable: .status)
                    .font(.caption)
                    .foregroundColor(.secondary)
                StatusRow(title: .localizable(.device), state: effectiveDeviceConnection)
                StatusRow(title: .localizable(.discord), state: nowPlayingService.discordConnection)
            }
            .padding(.vertical, 4)
            
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
                // SwiftUI `Picker(.menu)` sometimes renders centered on first load in MenuBarExtra.
                // A custom `Menu` avoids the initial layout glitch while keeping the same UX.
                Menu {
                    ForEach(browser.hosts, id: \.self) { host in
                        Button {
                            selectedHost = host
                        } label: {
                            if host == selectedHost {
                                Label(host, systemImage: "checkmark")
                            } else {
                                Text(host)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(selectedHost)
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color(NSColor.controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(Color(NSColor.separatorColor).opacity(0.6), lineWidth: 1)
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .id(deviceMenuLayoutID)
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, alignment: .leading)
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
            
            Button {
                Task {
                    if updaterService.updateChannel == .homebrew {
                        showUpdatePopup()
                    }

                    let result = await updaterService.checkForUpdates()
                    switch result {
                    case .sparkleOpened:
                        break
                    case .alreadyRunning:
                        if updaterService.updateChannel == .homebrew {
                            showUpdatePopup()
                        }
                    case .homebrewCompleted, .homebrewFailed, .homebrewBinaryMissing:
                        showUpdatePopup()
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 10, height: 10)
                        .padding(6)
                        .background(Circle().fill(Color(NSColor.quaternaryLabelColor)))
                    Text(localizable: .checkForUpdates)
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text(updateChannelName)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color(NSColor.tertiaryLabelColor).opacity(0.15))
                        .clipShape(Capsule())
                }
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color(NSColor.selectedControlColor).opacity(isHoveringCheckUpdates ? 0.18 : 0.0))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.clear, lineWidth: 0)
                )
            }
            .buttonStyle(PlainButtonStyle())
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
            .onHover { hovering in isHoveringCheckUpdates = hovering }
            
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
        .onAppear {
            // Force an additional layout pass. MenuBarExtra can occasionally give menu controls
            // an incorrect initial width until the user interacts with them.
            DispatchQueue.main.async {
                deviceMenuLayoutID = UUID()
            }
        }
    }
    
    // MARK: - Methods
    
    /// Handle switching to a new host: stop updates, perform pairing if needed, then resume.
    private func switchHost(to newHost: String) {
        let oldHost = previousHost
        // Stop now-playing updates for old device
        nowPlayingService.stop()
        Task {
            let newHostIP = browser.serviceIPs[newHost] ?? ""
            debugLog("[UI] Device selection: \(oldHost) -> \(newHost) (ip=\(newHostIP))")
            guard !newHostIP.isEmpty else {
                debugLog("[UI] Device switch aborted: no IP resolved for \(newHost)")
                selectedHost = oldHost
                return
            }

            let needsPairing = await nowPlayingService.isPairingNeeded(host: newHostIP)
            debugLog("[UI] Pairing needed: \(needsPairing) (host=\(newHostIP))")
            if needsPairing {
                let began = await nowPlayingService.pairDeviceBegin(host: newHostIP)
                guard began else {
                    showAlert(message: .localizable(.pairingFailed))
                    selectedHost = oldHost
                    return
                }
                // Await PIN input
                if let pin = await showPINWindow() {
                    if let creds = await nowPlayingService.pairDeviceFinish(host: newHostIP, pin: pin) {
                        debugLog("[PyatvService] Pairing finished with credentials:", creds)
                        nowPlayingService.updateTimer(setting.updateInterval, newHostIP)
                        previousHost = newHost
                    } else {
                        debugLog("[PyatvService] Pairing failed")
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
            debugLog("[UI] Switched device to \(newHost) (ip=\(newHostIP))")
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

    private func copyHomebrewCommandToClipboard() {
        let command = updaterService.homebrewUpgradeCommand
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        showAlert(message: "\(String.localizable(.homebrewCommandCopied))\n\n\(command)")
    }

    private func showUpdatePopup() {
        if let window = updatePopupWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let popup = UpdateProgressPopupView(
            updaterService: updaterService,
            onClose: {
                self.updatePopupWindow?.orderOut(nil)
            },
            onCopyCommand: {
                self.copyHomebrewCommandToClipboard()
            }
        )

        let hostingController = NSHostingController(rootView: popup)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Applepie Update"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.setContentSize(NSSize(width: 390, height: 185))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        updatePopupWindow = window
    }
}

struct UpdateProgressPopupView: View {
    @ObservedObject var updaterService: UpdaterService
    let onClose: () -> Void
    let onCopyCommand: () -> Void

    private var shouldShowCopyButton: Bool {
        guard !updaterService.isUpdating else { return false }
        guard let success = updaterService.lastUpdateSucceeded else { return false }
        return !success
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if updaterService.isUpdating {
                    ProgressView()
                        .controlSize(.small)
                } else if let success = updaterService.lastUpdateSucceeded {
                    Image(systemName: success ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(success ? Color(NSColor.systemGreen) : Color(NSColor.systemRed))
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundColor(.secondary)
                }

                Text("Updating Applepie")
                    .font(.headline)
            }

            Text(updaterService.updateStatusMessage.isEmpty ? "Preparing update..." : updaterService.updateStatusMessage)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .lineLimit(2)

            if let latest = updaterService.updateLog.last {
                Text(latest)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.top, 2)
            }

            Spacer()

            HStack {
                if shouldShowCopyButton {
                    Button("Copy Homebrew Command", action: onCopyCommand)
                        .buttonStyle(.bordered)
                }

                Spacer()

                Button("Close", action: onClose)
                    .buttonStyle(.borderedProminent)
                    .disabled(updaterService.isUpdating)
            }
        }
        .padding(14)
        .frame(width: 390, height: 185, alignment: .topLeading)
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
