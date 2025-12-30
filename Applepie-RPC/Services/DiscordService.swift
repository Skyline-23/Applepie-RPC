//
//  DiscordService.swift
//  Applepie-RPC
//
//  Created by 김부성 on 4/21/25.
//

import Foundation
import PylibKit_Mac
import MusicKit

class DiscordService {
    private var rpc: Pypresence.Client.ClientInstance?
    private let clientID: String
    private let executor: PythonExecutor
    private var rpcLoop: AsyncioLoop?
    private let musicService = AppleMusicService()

    /// Factory to create and initialize a DiscordService.
    static func create(
        clientID: String,
        executor: PythonExecutor
    ) async -> DiscordService {
        let service = DiscordService(clientID: clientID, executor: executor)
        await service.start()
        return service
    }

    init(clientID: String, executor: PythonExecutor) {
        self.clientID = clientID
        self.executor = executor
        self.musicService.clearCache()
    }

    private func ensureRpcLoop() async -> AsyncioLoop {
        if let rpcLoop {
            return rpcLoop
        }
        let loop = await executor.createAsyncioLoop()
        rpcLoop = loop
        return loop
    }

    /// Calls the pypresence set_activity on the Python thread.
    func setActivity(
        trackID: String?,
        title: String,
        artist: String?,
        album: String?,
        position: Double,
        duration: Double
    ) async {
        // If there's no current track, clear any existing activity and skip update
        if title.isEmpty {
            await clearActivity()
            return
        }

        if rpc == nil {
            await start()
        }

        guard let rpc else {
            print("[DiscordService] RPC is not initialized")
            return
        }

        let extras: [String: String]
        if let trackID = trackID {
            extras = await musicService.fetchTrackExtras(lookupKey: trackID, isStoreID: true)
        } else {
            let lookupKey = title + " " + (artist ?? "") + " " + (album ?? "")
            extras = await musicService.fetchTrackExtras(lookupKey: lookupKey, isStoreID: false)
        }

        let artworkUrl = extras["artworkUrl"]
        let iTunesUrl = extras["iTunesUrl"]

        let details = String(title.prefix(128))
        let stateSource = (artist?.isEmpty == false) ? artist! : "Music.app"
        let state = String(stateSource.prefix(128))
        let largeText: String?
        if let album, !album.isEmpty {
            largeText = String(album.prefix(128))
        } else {
            largeText = nil
        }

        var buttonsPayload: [[String: Any]] = []
        if let iTunesUrl, !iTunesUrl.isEmpty {
            buttonsPayload.append([
                "label": "Play on Apple Music",
                "url": iTunesUrl
            ])
        } else {
            let query = "\(title) \(album ?? "")".trimmingCharacters(in: .whitespacesAndNewlines)
            if !query.isEmpty {
                let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
                let countryCode = Locale.current.region?.identifier.lowercased() ?? "us"
                let searchUrl = "https://music.apple.com/\(countryCode)/search?term=\(encoded)"
                buttonsPayload.append([
                    "label": "Search on Apple Music",
                    "url": searchUrl
                ])
            }
        }

        let now = Int(Date().timeIntervalSince1970)
        let pos = max(0, Int(position))
        let dur = max(0, Int(duration))
        let remaining = max(0, dur - pos)
        let start = dur > 0 ? now - pos : nil
        let end = dur > 0 ? now + remaining : nil

        do {
            _ = try await rpc.set_activity(
                activity_type: .lISTENING,
                state: state,
                details: details,
                start: start,
                end: end,
                large_image: artworkUrl ?? "appicon",
                large_text: largeText,
                buttons: buttonsPayload.isEmpty ? nil : buttonsPayload,
                instance: false
            )
        } catch {
            let message = String(describing: error)
            if message.localizedCaseInsensitiveContains("buttons") {
                do {
                    _ = try await rpc.set_activity(
                        activity_type: .lISTENING,
                        state: state,
                        details: details,
                        start: start,
                        end: end,
                        large_image: artworkUrl ?? "appicon",
                        large_text: largeText,
                        buttons: nil,
                        instance: false
                    )
                } catch {
                    print("[DiscordService] Failed to set activity: \(error)")
                }
            } else {
                print("[DiscordService] Failed to set activity: \(error)")
            }
        }
    }

    /// Clears the activity on the Discord RPC connection.
    func clearActivity() async {
        await stop()
    }

    /// Manually start/restart the Discord RPC connection.
    private func start() async {
        guard rpc == nil else { return }
        print("[DiscordService] start() called")
        do {
            let client = try await Pypresence.Client.ClientInstance.create(
                executor: executor,
                client_id: clientID
            )
            let loop = await ensureRpcLoop()
            _ = try await client.update_event_loop(loop: loop)
            _ = try await client.start()
            rpc = client
            print("[DiscordService] RPC start result: true")
        } catch {
            print("[DiscordService] RPC start failed: \(error)")
        }
    }

    /// Manually stop the Discord RPC connection and clear activity.
    private func stop() async {
        guard let rpc else {
            print("[DiscordService] RPC is nil")
            return
        }
        print("[DiscordService] stop() called")
        do {
            _ = try await rpc.clear_activity()
        } catch {
            print("[DiscordService] Failed to clear activity: \(error)")
        }
        do {
            _ = try await rpc.close()
        } catch {
            print("[DiscordService] Failed to close RPC: \(error)")
        }
        self.rpc = nil
        self.rpcLoop = nil
        print("[DiscordService] RPC stopped and cleared")
    }
}

// MARK: - Track Extras Caching and Lookup

/// Simple in-memory and UserDefaults-backed cache for track extras.
class TrackExtrasCache {
    private let userDefaultsKey = "TrackExtrasCache"
    private var cache: [String: [String: String]]

    init() {
        cache = UserDefaults.standard.dictionary(forKey: userDefaultsKey) as? [String: [String: String]] ?? [:]
    }

    func get(trackID: String) -> [String: String]? {
        return cache[trackID]
    }

    func set(_ info: [String: String], for trackID: String) {
        cache[trackID] = info
        UserDefaults.standard.set(cache, forKey: userDefaultsKey)
    }

    /// Clears all cached track extras from memory and UserDefaults.
    func clear() {
        cache.removeAll()
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
    }
}

/// Service to fetch artwork and iTunes URL from Apple Music catalog via MusicKit.
class AppleMusicService {
    private let cache = TrackExtrasCache()

    /// Fetch artworkUrl (512x512) and track URL using MusicKit lookup or HTTP search fallback, with caching.
    func fetchTrackExtras(lookupKey key: String, isStoreID: Bool) async -> [String: String] {
        // 1) Return cached if present
        if let cached = cache.get(trackID: key) {
            return cached
        }

        var info: [String: String] = [:]

        // 2) If storeID is numeric, try MusicKit lookup
        if isStoreID {
            let request = MusicCatalogResourceRequest<Song>(
                matching: \.id,
                equalTo: MusicItemID(key)
            )
            do {
                let response = try await request.response()
                if let song = response.items.first, let artwork = song.artwork,
                   let artURL = artwork.url(width: 512, height: 512)?.absoluteString {
                    let trackUrl = song.url?.absoluteString ?? ""
                    info = ["artworkUrl": artURL, "iTunesUrl": trackUrl]
                }
            } catch {
                print("AppleMusicService (MusicKit) lookup error:", error)
            }
        } else {
            do {
                var searchRequest = MusicCatalogSearchRequest(term: key, types: [Song.self])
                searchRequest.limit = 1
                let searchResponse = try await searchRequest.response()
                if let song = searchResponse.songs.first, let artwork = song.artwork,
                   let artURL = artwork.url(width: 512, height: 512)?.absoluteString {
                    let trackUrl = song.url?.absoluteString ?? ""
                    info = ["artworkUrl": artURL, "iTunesUrl": trackUrl]
                }
            } catch {
                print("AppleMusicService MusicKit search error:", error)
            }
        }

        // 4) Cache and return (even if empty)
        cache.set(info, for: key)
        return info
    }

    /// Clear the cache for track extras.
    func clearCache() {
        cache.clear()
    }
}

private struct LookupResponse: Codable {
    struct Result: Codable {
        let artworkUrl100: String?
        let trackViewUrl: String?
    }
    let results: [Result]
}
