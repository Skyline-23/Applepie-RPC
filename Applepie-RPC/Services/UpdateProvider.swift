//
//  UpdateProvider.swift
//  Applepie-RPC
//

import Foundation
@preconcurrency import Sparkle

enum AppUpdateChannel: Equatable {
    case sparkle
    case homebrew
}

enum AppUpdateTrack: Equatable {
    case stable
    case beta
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
    var updateTrack: AppUpdateTrack { get }
    var supportsBetaUpdates: Bool { get }
    var homebrewUpgradeCommand: String { get }
    func setIncludesBetaUpdates(_ enabled: Bool)

    func checkForUpdates(
        appendLog: @MainActor @escaping (String) -> Void,
        setStatus: @MainActor @escaping (String) -> Void
    ) async -> AppUpdateResult
}

@MainActor
final class SparkleUpdateProvider: NSObject, UpdateProvider, SPUUpdaterDelegate {
    let channel: AppUpdateChannel = .sparkle
    let supportsBetaUpdates = true
    let homebrewUpgradeCommand = "brew upgrade --cask applepie-rpc"

    private var updaterController: SPUStandardUpdaterController!
    private var includesBetaUpdates: Bool

    var updateTrack: AppUpdateTrack {
        includesBetaUpdates ? .beta : .stable
    }

    private static let betaFeedURLString =
        "https://raw.githubusercontent.com/Skyline-23/Applepie-RPC/update-feed/beta/appcast.xml"

    init(includesBetaUpdates: Bool = false) {
        self.includesBetaUpdates = includesBetaUpdates
        super.init()
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
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

    func setIncludesBetaUpdates(_ enabled: Bool) {
        guard includesBetaUpdates != enabled else { return }
        includesBetaUpdates = enabled
        updaterController.updater.resetUpdateCycleAfterShortDelay()
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        includesBetaUpdates ? Self.betaFeedURLString : nil
    }
}

@MainActor
final class HomebrewUpdateProvider: UpdateProvider {
    static let betaCaskName = "applepie-rpc@beta"

    let channel: AppUpdateChannel = .homebrew
    let supportsBetaUpdates = false
    let homebrewUpgradeCommand: String
    let updateTrack: AppUpdateTrack

    private let caskName: String

    init(caskName: String = "applepie-rpc") {
        self.caskName = caskName
        self.homebrewUpgradeCommand = Self.makeUpgradeCommand(caskName: caskName)
        self.updateTrack = caskName == Self.betaCaskName ? .beta : .stable
    }

    func setIncludesBetaUpdates(_ enabled: Bool) {}

    func checkForUpdates(
        appendLog: @MainActor @escaping (String) -> Void,
        setStatus: @MainActor @escaping (String) -> Void
    ) async -> AppUpdateResult {
        guard let brewPath = resolveHomebrewPath() else {
            setStatus("Homebrew not found.")
            appendLog("Homebrew binary not found in PATH, /opt/homebrew/bin, /usr/local/bin")
            return .homebrewBinaryMissing
        }

        let refreshArguments = ["update-if-needed"]
        let upgradeArguments = ["upgrade", "--cask", caskName]
        let upgradeEnvironment = ["HOMEBREW_NO_AUTO_UPDATE": "1"]

        appendLog("Using Homebrew: \(brewPath)")
        setStatus("Checking Homebrew metadata...")
        appendLog("$ \(brewPath) \(refreshArguments.joined(separator: " "))")

        let refreshStatus = await runCommand(
            executablePath: brewPath,
            arguments: refreshArguments,
            environment: nil,
            appendLog: appendLog
        )
        guard refreshStatus == 0 else {
            setStatus("Homebrew metadata refresh failed (exit \(refreshStatus)).")
            appendLog("Metadata refresh failed with exit code \(refreshStatus).")
            return .homebrewFailed(refreshStatus)
        }

        setStatus("Upgrading via Homebrew...")
        appendLog("$ HOMEBREW_NO_AUTO_UPDATE=1 \(brewPath) \(upgradeArguments.joined(separator: " "))")

        let status = await runCommand(
            executablePath: brewPath,
            arguments: upgradeArguments,
            environment: upgradeEnvironment,
            appendLog: appendLog
        )
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

    private static func makeUpgradeCommand(caskName: String) -> String {
        "brew update-if-needed && HOMEBREW_NO_AUTO_UPDATE=1 brew upgrade --cask \(caskName)"
    }

    private func runCommand(
        executablePath: String,
        arguments: [String],
        environment: [String: String]?,
        appendLog: @MainActor @escaping (String) -> Void
    ) async -> Int32 {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            if let environment {
                process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in
                    new
                }
            }

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
