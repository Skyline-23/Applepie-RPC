//
//  NowPlayingService.swift
//  Applepie-RPC
//
//  Created by 김부성 on 4/23/25.
//

import Foundation
import Combine

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

    private var timerCancellable: AnyCancellable?
    private var interval: TimeInterval = 5.0
    private var host: String = "localhost"

    private var atvService: PyatvService?

    /// Start fetching now-playing data periodically.
    func start(interval: TimeInterval, host: String) {
        self.interval = interval
        self.host = host
        timerCancellable?.cancel()
        timerCancellable = Timer
            .publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                Task {
                    let result = await self.fetch(host: host)
                    DispatchQueue.main.async {
                        self.playingData = PlayingData(
                            trackID: result.trackID,
                            title: result.title,
                            artist: result.artist,
                            album: result.album,
                            position: result.position,
                            duration: result.duration
                        )
                    }
                }
            }
    }
    
    func stop() {
        timerCancellable?.cancel()
        timerCancellable = nil
    }

    /// Update the fetch interval & host.
    func updateTimer(_ newInterval: TimeInterval, _ newHost: String) {
        start(interval: newInterval, host: newHost)
    }

    /// Inject a PyatvService for Apple TV/HomePod hosts.
    func setATVService(_ service: PyatvService) {
        self.atvService = service
    }

    /// Synchronously fetch now playing info with fulld metadata, including artist.
    private func fetchLocal() -> (trackID: String?, title: String, artist: String?, album: String?, position: Double, duration: Double) {
        let script = """
        tell application "Music"
            if player state is playing then
                set t to name of current track
                set al to album of current track
                set ar to artist of current track
                set pos to player position
                set dur to duration of current track
                return "#" & t & "#" & ar & "#" & al & "#" & pos & "#" & dur
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
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let raw = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let parts = raw.split(separator: "#", maxSplits: 5).map { String($0) }
            // parts: ["", title, artist, album, position, duration]
            let title    = parts.count > 1 ? parts[1] : ""
            let artist   = parts.count > 2 ? parts[2] : ""
            let album    = parts.count > 3 ? parts[3] : ""
            let position = parts.count > 4 ? Double(parts[4]) ?? 0.0 : 0.0
            let duration = parts.count > 5 ? Double(parts[5]) ?? 0.0 : 0.0
            return (trackID: nil, title: title, artist: artist, album: album, position: position, duration: duration)
        } catch {
            return (trackID: nil, title: "", artist: nil, album: nil, position: 0.0, duration: 0.0)
        }
    }

    /// Fetch now playing info, using AppleScript for local or PyatvService for remote hosts.
    func fetch(host: String) async -> (trackID: String?, title: String, artist: String?, album: String?, position: Double, duration: Double) {
        if host == "localhost" {
            return fetchLocal()
        } else if let service = atvService {
            if let props = await service.getATVProps(host: host) {
                return props
            }
        }
        return (nil, "", nil, nil, 0.0, 0.0)
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
    
    /// Check pairing needed
    func isPairingNeeded(host: String) async -> Bool {
        guard let service = atvService else { return false }
        return await service.isPairingNeeded(host: host)
    }
    
    func clearCache() async -> Bool {
        guard let service = atvService else { return false }
        return await service.removePairing()
    }
}
