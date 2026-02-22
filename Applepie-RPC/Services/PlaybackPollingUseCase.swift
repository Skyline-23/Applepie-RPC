//
//  PlaybackPollingUseCase.swift
//  Applepie-RPC
//

import Foundation
import AppKit

struct PlaybackMetadata: Equatable {
    let trackID: String?
    let title: String
    let artist: String?
    let album: String?
    let position: Double
    let duration: Double
}

struct PlaybackFetchResult {
    let connection: ConnectionState
    let metadata: PlaybackMetadata?
}

protocol PlaybackFetching: AnyObject {
    func fetch(host: String) async -> PlaybackFetchResult
}

actor PlaybackFetchAdapter: PlaybackFetching {
    private var atvService: (any ATVServiceProviding)?

    func setATVService(_ service: any ATVServiceProviding) {
        atvService = service
    }

    func fetch(host: String) async -> PlaybackFetchResult {
        if host == "localhost" {
            return fetchLocal()
        }

        guard let service = atvService else {
            return PlaybackFetchResult(connection: .disconnected, metadata: nil)
        }

        let result = await service.getATVProps(host: host)
        guard let props = result.data else {
            return PlaybackFetchResult(connection: result.connection, metadata: nil)
        }
        return PlaybackFetchResult(
            connection: result.connection,
            metadata: PlaybackMetadata(
                trackID: props.trackID,
                title: props.title,
                artist: props.artist,
                album: props.album,
                position: props.position,
                duration: props.duration
            )
        )
    }

    private func fetchLocal() -> PlaybackFetchResult {
        let musicRunning = !NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.Music")
            .isEmpty
        guard musicRunning else {
            return PlaybackFetchResult(connection: .disconnected, metadata: nil)
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
            let title = parts.count > 0 ? parts[0] : ""
            let artist = parts.count > 1 ? parts[1] : ""
            let album = parts.count > 2 ? parts[2] : ""
            let position = parts.count > 3 ? Double(parts[3]) ?? 0.0 : 0.0
            let duration = parts.count > 4 ? Double(parts[4]) ?? 0.0 : 0.0

            return PlaybackFetchResult(
                connection: connected,
                metadata: PlaybackMetadata(
                    trackID: nil,
                    title: title,
                    artist: artist,
                    album: album,
                    position: position,
                    duration: duration
                )
            )
        } catch {
            return PlaybackFetchResult(connection: .disconnected, metadata: nil)
        }
    }
}

actor PlaybackPollingUseCase {
    private var lastConnectedAt: Date?

    func makeStream(
        interval: TimeInterval,
        host: String,
        fetcher: any PlaybackFetching
    ) -> AsyncStream<PlaybackFetchResult> {
        lastConnectedAt = nil
        let pollInterval = max(0.5, interval)

        return AsyncStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    // Keep polling cadence strict: if one fetch overruns the interval,
                    // cancel it and start a new cycle.
                    let cycleStartedAt = Date()
                    let fetched = await self.fetchWithDeadline(
                        timeout: pollInterval,
                        host: host,
                        fetcher: fetcher
                    )
                    if Task.isCancelled { break }

                    let rawConnection = fetched?.connection ?? .disconnected
                    let resolved = self.resolveConnection(
                        raw: rawConnection,
                        interval: interval
                    )
                    continuation.yield(
                        PlaybackFetchResult(connection: resolved, metadata: fetched?.metadata)
                    )

                    let elapsed = Date().timeIntervalSince(cycleStartedAt)
                    let remaining = pollInterval - elapsed
                    if remaining > 0 {
                        try? await Task.sleep(
                            nanoseconds: UInt64(remaining * 1_000_000_000)
                        )
                    }
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func fetchWithDeadline(
        timeout: TimeInterval,
        host: String,
        fetcher: any PlaybackFetching
    ) async -> PlaybackFetchResult? {
        let timeoutNanos = UInt64(max(0.1, timeout) * 1_000_000_000)
        return await withTaskGroup(of: PlaybackFetchResult?.self) { group in
            group.addTask {
                await fetcher.fetch(host: host)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanos)
                return nil
            }

            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func resolveConnection(
        raw: ConnectionState,
        interval: TimeInterval
    ) -> ConnectionState {
        let now = Date()
        let disconnectGrace = min(max(5.0, interval * 1.5), 20.0)

        if raw == .connected {
            lastConnectedAt = now
            return .connected
        }

        if let lastConnectedAt,
           now.timeIntervalSince(lastConnectedAt) <= disconnectGrace {
            return .connected
        }

        return raw
    }
}
