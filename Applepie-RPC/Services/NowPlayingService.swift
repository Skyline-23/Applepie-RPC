//
//  NowPlayingService.swift
//  Applepie-RPC
//
//  Created by 김부성 on 4/23/25.
//

import Foundation

/// Encapsulates now-playing fetch logic via AppleScript.
class NowPlayingService {
    /// Synchronously fetch now playing info with fulld metadata, including artist.
    func fetchSync() -> (itunesID: String?, title: String, artist: String?, album: String?, position: Double, duration: Double) {
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
            let title   = parts.count > 0 ? parts[0] : ""
            let artist  = parts.count > 1 ? parts[1] : ""
            let album   = parts.count > 2 ? parts[2] : ""
            let position = parts.count > 3 ? Double(parts[3]) ?? 0.0 : 0.0
            let duration = parts.count > 4 ? Double(parts[4]) ?? 0.0 : 0.0
            return (itunesID: nil, title: title, artist: artist, album: album, position: position, duration: duration)
        } catch {
            return (itunesID: nil, title: "", artist: nil, album: nil, position: 0.0, duration: 0.0)
        }
    }

    /// Asynchronously fetch now playing info.
    func fetchAsync(completion: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
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
            var result = ""
            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                result = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            } catch {
                print("NowPlayingService async error:", error)
            }
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }
}
