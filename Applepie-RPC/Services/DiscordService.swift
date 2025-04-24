//
//  DiscordService.swift
//  Applepie-RPC
//
//  Created by 김부성 on 4/21/25.
//

import Foundation
import PythonKit
import MusicKit

class DiscordService: PythonService {
    private var initRPC: PythonObject? = nil
    private var setActivityFunc: PythonObject? = nil
    private var clearActivityFunc: PythonObject? = nil
    private var rpc: PythonObject? = nil
    private var timer: Timer?
    private let clientID: String
    private let musicService = AppleMusicService()
    
    /// Factory to create and initialize a DiscordService on the Python thread.
    static public func create(
        clientID: String,
        executor: PythonExecutor
    ) async -> DiscordService {
        // Perform all PythonKit work on the Python thread
        let service = await executor.createOnPythonThread {
            DiscordService(clientID: clientID, executor: executor)
        }
        // Initialize RPC using executor’s async API
        await executor.importModule(named: "discord_service")
        if let mod = await executor.module(named: "discord_service") {
            // Perform all Python-related assignments on the dedicated Python thread
            await executor.performAsync { [service] in
                service.initRPC = mod.init_rpc_sync
                service.setActivityFunc = mod.set_activity
                service.clearActivityFunc = mod.clear_activity
                if let initRPC = service.initRPC {
                    service.rpc = initRPC(service.clientID)
                }
            }
            print("[DiscordService] RPC object initialized: \(service.rpc != nil)")
        }
        return service
    }
    
    init(clientID: String, executor: PythonExecutor) {
        self.clientID = clientID
        super.init(executor: executor)
        
        self.musicService.clearCache()
    }
    
    /// Calls the Python set_activity wrapper on the dedicated Python thread.
    func setActivity(title: String,
                     artist: String,
                     album: String?,
                     position: Double,
                     duration: Double,
                     artworkUrl: String?,
                     itunesUrl: String?,
                     source: String) async {
        guard let rpc = self.rpc else {
            print("[DiscordService] RPC is not initialized")
            return
        }
        guard let setFunc = self.setActivityFunc else {
            print("[DiscordService] setActivityFunc is not initialized")
            return
        }
        await callPython {
            let pyMeta: PythonObject = [
                "title": PythonObject(title),
                "artist": PythonObject(artist),
                "album": PythonObject(album ?? ""),
                "position": PythonObject(position),
                "duration": PythonObject(duration),
                "artworkUrl": PythonObject(artworkUrl ?? ""),
                "itunes_id": PythonObject(itunesUrl ?? "")
            ]
            let pySource = PythonObject(source)
            let countryCode = Locale.current.region?.identifier.lowercased() ?? "us"
            let pyCountry = PythonObject(countryCode)
            _ = setFunc(rpc, pyMeta, pySource, pyCountry)
        }
    }
    
    /// Clears the activity on the dedicated Python thread.
    func clearActivity() async {
        guard let rpc = self.rpc else {
            print("[DiscordService] RPC is not initialized")
            return
        }
        guard let clearFunc = self.clearActivityFunc else {
            print("[DiscordService] clearActivityFunc is not initialized")
            return
        }
        await callPython {
            _ = clearFunc(rpc)
        }
    }
    
    /// Begin sending activity at a regular interval using full playback data.
    /// - Parameters:
    ///   - interval: seconds between each update
    ///   - detailsProvider: returns (trackID, details, artist?, album?, position, duration)
    func startPeriodicUpdates(interval: TimeInterval,
                              detailsProvider: @escaping () -> (itunesID: String?, title: String, artist: String?, album: String?, position: Double, duration: Double)) {
        print("[DiscordService] startPeriodicUpdates interval: \(interval)")
        self.timer?.invalidate()
        self.timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task {
                // 1) Core playback data
                let (itunesID, title, artist, album, position, duration) = detailsProvider()
                // If there's no current track, clear any existing activity and skip update
                if title.isEmpty {
                    await self.clearActivity()
                    return
                }
                let extras: [String: String]
                if let itunesID = itunesID {
                    extras = await self.musicService.fetchTrackExtras(lookupKey: itunesID, isStoreID: true)
                } else {
                    let lookupKey = title + " " + (artist ?? "") + " " + (album ?? "")
                    extras = await self.musicService.fetchTrackExtras(lookupKey: lookupKey, isStoreID: false)
                }
                    
                let artwork = extras["artworkUrl"]
                let iTunes  = extras["iTunesUrl"]
                // 3) Update Discord
                await self.setActivity(
                    title: title,
                    artist: artist ?? "",
                    album: album,
                    position: position,
                    duration: duration,
                    artworkUrl: artwork,
                    itunesUrl: iTunes,
                    source: "Music.app"
                )
            }
        }
        RunLoop.main.add(self.timer!, forMode: .common)
    }
    
    /// Stop the periodic updates.
    func stopPeriodicUpdates() {
        print("[DiscordService] stopPeriodicUpdates called")
        timer?.invalidate()
        timer = nil
    }
    
    /// Manually start/restart the Discord RPC connection.
    func start() {
        print("[DiscordService] start() called")
        guard let initRPCFunc = initRPC else {
            print("[DiscordService] initRPC function is not initialized")
            return
        }
        rpc = initRPCFunc(clientID)
        print("[DiscordService] RPC start result: \(rpc != nil)")
    }
    
    /// Manually stop the Discord RPC connection and clear activity.
    func stop() {
        print("[DiscordService] stop() called")
        Task {
            // Safely clear if function exists
            guard let clearFunc = clearActivityFunc, let rpcObj = rpc else {
                print("[DiscordService] clearActivity function or rpc is nil")
                return
            }
            await callPython {
                _ = clearFunc(rpcObj)
            }
            self.rpc = nil
            print("[DiscordService] RPC stopped and cleared")
        }
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
