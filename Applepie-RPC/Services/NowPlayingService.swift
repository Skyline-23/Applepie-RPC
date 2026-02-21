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

    private var timerCancellable: AnyCancellable?
    @Published private(set) var updateInterval: TimeInterval = 5.0
    private var host: String = "localhost"
    private var isFetching = false
    private var lastDeviceConnectedAt: Date?
    private var fetchTask: Task<Void, Never>?
    private var currentFetchHost: String?
    private var currentFetchInterval: TimeInterval?

    private var atvService: PyatvService?

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
           timerCancellable != nil {
            debugLog("[NowPlayingService] Skipping start; already fetching host=\(host) interval=\(interval)s")
            return
        }

        currentFetchHost = host
        currentFetchInterval = interval
        self.updateInterval = interval
        self.host = host
        self.deviceConnection = .unknown
        self.playingData = nil
        self.lastDeviceConnectedAt = nil
        debugLog("[NowPlayingService] start interval=\(interval)s host=\(host)")

        timerCancellable?.cancel()
        fetchTask?.cancel()
        fetchTask = nil
        isFetching = false

        timerCancellable = Timer
            .publish(every: updateInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                guard !self.isFetching else { return }
                self.isFetching = true

                self.fetchTask = Task { [weak self] in
                    guard let self else { return }
                    defer { self.isFetching = false }

                    let result = await self.fetch(host: host)
                    if Task.isCancelled { return }

                    let now = Date()
                    let disconnectGrace = min(max(5.0, self.updateInterval * 1.5), 20.0)
                    let resolvedConnection: ConnectionState

                    if result.connection == .connected {
                        self.lastDeviceConnectedAt = now
                        resolvedConnection = .connected
                    } else if let last = self.lastDeviceConnectedAt,
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
            }
    }
    
    func stop() {
        timerCancellable?.cancel()
        timerCancellable = nil
        fetchTask?.cancel()
        fetchTask = nil
        currentFetchHost = nil
        currentFetchInterval = nil
        isFetching = false
        deviceConnection = .disconnected
        lastDeviceConnectedAt = nil
        playingData = nil
    }

    /// Update the fetch interval & host.
    func updateTimer(_ newInterval: TimeInterval, _ newHost: String) {
        if currentFetchHost == newHost,
           currentFetchInterval == newInterval,
           timerCancellable != nil {
            debugLog("[NowPlayingService] updateTimer no-op host=\(newHost) interval=\(newInterval)s")
            return
        }

        debugLog("[NowPlayingService] updateTimer interval=\(newInterval)s host=\(newHost)")
        deviceConnection = .unknown
        lastDeviceConnectedAt = nil
        playingData = nil
        fetchTask?.cancel()
        fetchTask = nil
        currentFetchHost = nil
        currentFetchInterval = nil
        isFetching = false
        start(interval: newInterval, host: newHost)
    }

    func setDiscordConnection(_ state: ConnectionState) {
        guard discordConnection != state else { return }
        discordConnection = state
    }

    /// Inject a PyatvService for Apple TV/HomePod hosts.
    func setATVService(_ service: PyatvService) {
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
