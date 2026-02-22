//
//  NowPlayingService.swift
//  Applepie-RPC
//
//  Created by 김부성 on 4/23/25.
//

import Foundation
import Combine
import AppKit

/// Simple struct to represent now-playing data.
struct PlayingData: Equatable {
    let trackID: String?
    let title: String
    let artist: String?
    let album: String?
    let position: Double
    let duration: Double
}

/// Encapsulates now-playing fetch logic via AppleScript.
class NowPlayingService: ObservableObject {
    @Published var playingData: PlayingData?
    @Published var deviceConnection: ConnectionState = .unknown
    @Published var discordConnection: ConnectionState = .unknown

    private var pollingTask: Task<Void, Never>?
    @Published private(set) var updateInterval: TimeInterval = 5.0
    private var lastDeviceConnectedAt: Date?
    private var currentFetchHost: String?
    private var currentFetchInterval: TimeInterval?

    private var atvService: (any ATVServiceProviding)?

    private struct FetchResult {
        let connection: ConnectionState
        let trackID: String?
        let title: String
        let artist: String?
        let album: String?
        let position: Double
        let duration: Double
    }

    private func makePlayingData(from result: FetchResult) -> PlayingData? {
        let trimmedTitle = result.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return nil }

        let trimmedArtist = result.artist?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAlbum = result.album?.trimmingCharacters(in: .whitespacesAndNewlines)

        return PlayingData(
            trackID: result.trackID,
            title: trimmedTitle,
            artist: (trimmedArtist?.isEmpty == true) ? nil : trimmedArtist,
            album: (trimmedAlbum?.isEmpty == true) ? nil : trimmedAlbum,
            position: result.position,
            duration: result.duration
        )
    }

    /// Start fetching now-playing data periodically.
    func start(interval: TimeInterval, host: String) {
        if currentFetchHost == host,
           currentFetchInterval == interval,
           pollingTask != nil {
            debugLog("[NowPlayingService] Skipping start; already fetching host=\(host) interval=\(interval)s")
            return
        }

        currentFetchHost = host
        currentFetchInterval = interval
        self.updateInterval = interval
        self.deviceConnection = .unknown
        self.playingData = nil
        self.lastDeviceConnectedAt = nil
        debugLog("[NowPlayingService] start interval=\(interval)s host=\(host)")

        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                await self.performFetch(host: host)
                if Task.isCancelled { break }

                let sleepSeconds = max(0.5, interval)
                let sleepNanos = UInt64(sleepSeconds * 1_000_000_000)
                try? await Task.sleep(nanoseconds: sleepNanos)
            }
        }
    }

    private func performFetch(host: String) async {
        let result = await fetch(host: host)
        if Task.isCancelled { return }

        let now = Date()
        let disconnectGrace = min(max(5.0, updateInterval * 1.5), 20.0)
        let resolvedConnection: ConnectionState

        if result.connection == .connected {
            lastDeviceConnectedAt = now
            resolvedConnection = .connected
        } else if let last = lastDeviceConnectedAt,
                  now.timeIntervalSince(last) <= disconnectGrace {
            resolvedConnection = .connected
        } else {
            resolvedConnection = result.connection
        }

        await MainActor.run {
            self.deviceConnection = resolvedConnection
            let newData = self.makePlayingData(from: result)
            if self.playingData != newData {
                self.playingData = newData
            }
        }
    }
    
    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        currentFetchHost = nil
        currentFetchInterval = nil
        deviceConnection = .disconnected
        lastDeviceConnectedAt = nil
        playingData = nil
    }

    /// Update the fetch interval & host.
    func updateTimer(_ newInterval: TimeInterval, _ newHost: String) {
        if currentFetchHost == newHost,
           currentFetchInterval == newInterval,
           pollingTask != nil {
            debugLog("[NowPlayingService] updateTimer no-op host=\(newHost) interval=\(newInterval)s")
            return
        }

        debugLog("[NowPlayingService] updateTimer interval=\(newInterval)s host=\(newHost)")
        deviceConnection = .unknown
        lastDeviceConnectedAt = nil
        playingData = nil
        pollingTask?.cancel()
        pollingTask = nil
        currentFetchHost = nil
        currentFetchInterval = nil
        start(interval: newInterval, host: newHost)
    }

    func setDiscordConnection(_ state: ConnectionState) {
        guard discordConnection != state else { return }
        discordConnection = state
    }

    /// Inject an ATV metadata service for Apple TV/HomePod hosts.
    func setATVService(_ service: any ATVServiceProviding) {
        self.atvService = service
    }

    /// Synchronously fetch now playing info with fulld metadata, including artist.
    private func fetchLocal() -> FetchResult {
        let musicRunning = !NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.Music")
            .isEmpty
        guard musicRunning else {
            return FetchResult(
                connection: .disconnected,
                trackID: nil,
                title: "",
                artist: nil,
                album: nil,
                position: 0.0,
                duration: 0.0
            )
        }
        let script = """
        tell application "Music"
            if player state is playing then
                set t to name of current track
                set al to album of current track
                set ar to artist of current track
                set pos to player position
                set dur to duration of current track
                return "|" & t & "|" & ar & "|" & al & "|" & pos & "|" & dur
            else
                return ""
            end if
        end tell
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let connected: ConnectionState = process.terminationStatus == 0 ? .connected : .disconnected
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let raw = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let parts = raw.split(separator: "|").map(String.init)
            let title    = parts.count > 0 ? parts[0] : ""
            let artist   = parts.count > 1 ? parts[1] : ""
            let album    = parts.count > 2 ? parts[2] : ""
            let position = parts.count > 3 ? Double(parts[3]) ?? 0.0 : 0.0
            let duration = parts.count > 4 ? Double(parts[4]) ?? 0.0 : 0.0
            return FetchResult(
                connection: connected,
                trackID: nil,
                title: title,
                artist: artist,
                album: album,
                position: position,
                duration: duration
            )
        } catch {
            return FetchResult(
                connection: .disconnected,
                trackID: nil,
                title: "",
                artist: nil,
                album: nil,
                position: 0.0,
                duration: 0.0
            )
        }
    }

    /// Fetch now playing info, using AppleScript for local or PyatvService for remote hosts.
    private func fetch(host: String) async -> FetchResult {
        if host == "localhost" {
            return fetchLocal()
        } else if let service = atvService {
            let result = await service.getATVProps(host: host)
            if let props = result.data {
                return FetchResult(
                    connection: result.connection,
                    trackID: props.trackID,
                    title: props.title,
                    artist: props.artist,
                    album: props.album,
                    position: props.position,
                    duration: props.duration
                )
            }
            return FetchResult(
                connection: result.connection,
                trackID: nil,
                title: "",
                artist: nil,
                album: nil,
                position: 0.0,
                duration: 0.0
            )
        }
        return FetchResult(
            connection: .disconnected,
            trackID: nil,
            title: "",
            artist: nil,
            album: nil,
            position: 0.0,
            duration: 0.0
        )
    }
    
    /// Begin pairing: shows PIN on Apple TV.
    func pairDeviceBegin(host: String) async -> Bool {
        guard let service = atvService else { return false }
        return await service.pairDeviceBeginSync(host: host)
    }

    /// Finish pairing with entered PIN.
    func pairDeviceFinish(host: String, pin: Int) async -> String? {
        guard let service = atvService else { return nil }
        return await service.pairDeviceFinishSync(host: host, pin: pin)
    }
    
    /// Cancel pairing
    func pairDeviceCancel(host: String) async -> Bool {
        guard let service = atvService else { return false }
        return await service.cancelPairing(host: host)
    }
    
    /// Check pairing needed
    func isPairingNeeded(host: String) async -> Bool {
        if host == "localhost" {
            return false
        }
        guard let service = atvService else { return false }
        return await service.isPairingNeeded(host: host)
    }
    
    func clearCache() async -> Bool {
        guard let service = atvService else { return false }
        return await service.clearCache()
    }
}
