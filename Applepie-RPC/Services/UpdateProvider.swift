//
//  UpdateProvider.swift
//  Applepie-RPC
//

import Foundation
import Sparkle

enum AppUpdateChannel: Equatable {
    case sparkle
    case homebrew
}

enum AppUpdateResult: Equatable {
    case sparkleOpened
    case alreadyRunning
    case homebrewCompleted
    case homebrewFailed(Int32)
    case homebrewBinaryMissing
}

@MainActor
protocol UpdateProvider {
    var channel: AppUpdateChannel { get }
    var homebrewUpgradeCommand: String { get }

    func checkForUpdates(
        appendLog: @MainActor @escaping (String) -> Void,
        setStatus: @MainActor @escaping (String) -> Void
    ) async -> AppUpdateResult
}

@MainActor
final class SparkleUpdateProvider: UpdateProvider {
    let channel: AppUpdateChannel = .sparkle
    let homebrewUpgradeCommand = "brew upgrade --cask applepie-rpc"

    private let updaterController: SPUStandardUpdaterController

    init() {
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        controller.updater.automaticallyChecksForUpdates = true
        controller.updater.automaticallyDownloadsUpdates = true
        self.updaterController = controller
    }

    func checkForUpdates(
        appendLog: @MainActor @escaping (String) -> Void,
        setStatus: @MainActor @escaping (String) -> Void
    ) async -> AppUpdateResult {
        appendLog("Sparkle update check requested.")
        setStatus("Sparkle update window opened.")
        updaterController.updater.checkForUpdates()
        return .sparkleOpened
    }
}

@MainActor
final class HomebrewUpdateProvider: UpdateProvider {
    let channel: AppUpdateChannel = .homebrew
    let homebrewUpgradeCommand = "brew upgrade --cask applepie-rpc"

    func checkForUpdates(
        appendLog: @MainActor @escaping (String) -> Void,
        setStatus: @MainActor @escaping (String) -> Void
    ) async -> AppUpdateResult {
        guard let brewPath = resolveHomebrewPath() else {
            setStatus("Homebrew not found.")
            appendLog("Homebrew binary not found in PATH, /opt/homebrew/bin, /usr/local/bin")
            return .homebrewBinaryMissing
        }

        let command = "\(brewPath) update && \(brewPath) upgrade --cask applepie-rpc"
        setStatus("Updating via Homebrew...")
        appendLog("Using Homebrew: \(brewPath)")
        appendLog("$ \(command)")

        let status = await runShellCommand(command, appendLog: appendLog)
        if status == 0 {
            setStatus("Homebrew update completed successfully.")
            appendLog("Update completed.")
            return .homebrewCompleted
        }

        setStatus("Homebrew update failed (exit \(status)).")
        appendLog("Update failed with exit code \(status).")
        return .homebrewFailed(status)
    }

    private func resolveHomebrewPath() -> String? {
        let envCandidates = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { String($0) + "/brew" }
        let fallbackCandidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        let allCandidates = envCandidates + fallbackCandidates
        return allCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func runShellCommand(
        _ command: String,
        appendLog: @MainActor @escaping (String) -> Void
    ) async -> Int32 {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let consume: (Data) -> Void = { data in
                guard !data.isEmpty else { return }
                let text = String(data: data, encoding: .utf8) ?? ""
                guard !text.isEmpty else { return }
                for line in text.split(whereSeparator: \.isNewline) {
                    let textLine = String(line)
                    Task { @MainActor in
                        appendLog(textLine)
                    }
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

                consume(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                consume(stderrPipe.fileHandleForReading.readDataToEndOfFile())
                continuation.resume(returning: proc.terminationStatus)
            }

            do {
                try process.run()
            } catch {
                Task { @MainActor in
                    appendLog("Failed to start Homebrew process: \(error.localizedDescription)")
                }
                continuation.resume(returning: -1)
            }
        }
    }
}
