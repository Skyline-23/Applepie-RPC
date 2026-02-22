import Foundation
import Sparkle

@MainActor
final class UpdaterService: ObservableObject {
    enum UpdateChannel: Equatable {
        case sparkle
        case homebrew
    }

    enum UpdateResult: Equatable {
        case sparkleOpened
        case alreadyRunning
        case homebrewCompleted
        case homebrewFailed(Int32)
        case homebrewBinaryMissing
    }

    @Published private(set) var updateChannel: UpdateChannel
    @Published private(set) var updateStatusMessage: String = ""
    @Published private(set) var updateLog: [String] = []
    @Published private(set) var lastUpdateSucceeded: Bool?
    @Published private(set) var isUpdating: Bool = false

    /// `nil` when updates are managed externally (e.g. Homebrew).
    private let updaterController: SPUStandardUpdaterController?

    init() {
        if Self.isHomebrewManagedInstall() {
            updateChannel = .homebrew
            updaterController = nil
            return
        }

        updateChannel = .sparkle
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        controller.updater.automaticallyChecksForUpdates = true
        controller.updater.automaticallyDownloadsUpdates = true
        updaterController = controller
    }

    func checkForUpdates() async -> UpdateResult {
        guard !isUpdating else { return .alreadyRunning }
        lastUpdateSucceeded = nil
        updateLog.removeAll()

        switch updateChannel {
        case .sparkle:
            updateStatusMessage = "Sparkle update window opened."
            appendLog("Sparkle update check requested.")
            updaterController?.updater.checkForUpdates()
            return .sparkleOpened
        case .homebrew:
            return await runHomebrewUpdate()
        }
    }

    var homebrewUpgradeCommand: String {
        "brew upgrade --cask applepie-rpc"
    }

    private func runHomebrewUpdate() async -> UpdateResult {
        guard let brewPath = resolveHomebrewPath() else {
            updateStatusMessage = "Homebrew not found."
            appendLog("Homebrew binary not found in PATH, /opt/homebrew/bin, /usr/local/bin")
            return .homebrewBinaryMissing
        }

        let command = "\(brewPath) update && \(brewPath) upgrade --cask applepie-rpc"
        isUpdating = true
        updateStatusMessage = "Updating via Homebrew..."
        appendLog("Using Homebrew: \(brewPath)")
        appendLog("$ \(command)")

        let status = await runShellCommand(command)
        isUpdating = false

        if status == 0 {
            updateStatusMessage = "Homebrew update completed successfully."
            appendLog("Update completed.")
            lastUpdateSucceeded = true
            return .homebrewCompleted
        } else {
            updateStatusMessage = "Homebrew update failed (exit \(status))."
            appendLog("Update failed with exit code \(status).")
            lastUpdateSucceeded = false
            return .homebrewFailed(status)
        }
    }

    private func resolveHomebrewPath() -> String? {
        let envCandidates = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { String($0) + "/brew" }
        let fallbackCandidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        let allCandidates = envCandidates + fallbackCandidates
        return allCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func runShellCommand(_ command: String) async -> Int32 {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let consume: (Data) -> Void = { [weak self] data in
                guard !data.isEmpty, let self else { return }
                Task { @MainActor in
                    self.consumeOutput(data)
                }
            }

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                consume(handle.availableData)
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                consume(handle.availableData)
            }

            process.terminationHandler = { proc in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil

                let trailingStdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let trailingStderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                Task { @MainActor in
                    self.consumeOutput(trailingStdout)
                    self.consumeOutput(trailingStderr)
                    continuation.resume(returning: proc.terminationStatus)
                }
            }

            do {
                try process.run()
            } catch {
                Task { @MainActor in
                    self.appendLog("Failed to start Homebrew process: \(error.localizedDescription)")
                }
                continuation.resume(returning: -1)
            }
        }
    }

    private func consumeOutput(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
        for line in text.split(whereSeparator: \.isNewline) {
            appendLog(String(line))
        }
    }

    private func appendLog(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updateLog.append(trimmed)
        if updateLog.count > 200 {
            updateLog.removeFirst(updateLog.count - 200)
        }
    }

    /// Best-effort detection to avoid Homebrew-managed app bundles being modified by Sparkle.
    /// Sparkle self-updates are great for direct installs, but fight with cask-managed upgrades.
    private static func isHomebrewManagedInstall() -> Bool {
        let resolvedBundlePath = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        if resolvedBundlePath.contains("/Caskroom/") {
            return true
        }

        // If the cask exists, prefer Homebrew as the update authority.
        // This is intentionally conservative; users can still update via Homebrew even if the app
        // was moved to /Applications.
        let caskName = "applepie-rpc"
        let candidateCaskrooms = [
            "/opt/homebrew/Caskroom/\(caskName)",
            "/usr/local/Caskroom/\(caskName)"
        ]
        return candidateCaskrooms.contains { FileManager.default.fileExists(atPath: $0) }
    }
}
