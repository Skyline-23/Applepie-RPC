//
//  DiscordService.swift
//  Applepie-RPC
//
//  Created by 김부성 on 4/21/25.
//

import Foundation
import PythonKit

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
                              detailsProvider: @escaping () -> (itunesID: String?, details: String, artist: String?, album: String?, position: Double, duration: Double)) {
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
                let lookupKey = itunesID ?? title // Use iTunes ID if available, otherwise use track name
                var extras = await self.musicService.fetchTrackExtras(trackID: lookupKey)
                if extras["artworkUrl"]?.isEmpty ?? true {
                    extras = await self.musicService.searchTrackExtras(name: title, artist: album ?? "", album: album)
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
}

/// Service to fetch artwork and iTunes URL from iTunes Lookup API.
class AppleMusicService {
    private let cache = TrackExtrasCache()
    private let session = URLSession.shared
    
    /// Fetch artworkUrl (512x512) and iTunes URL for a given track ID.
    func fetchTrackExtras(trackID: String,
                          country: String = Locale.current.region?.identifier.lowercased() ?? "us") async -> [String: String] {
        // 1) Check cache
        if let cached = cache.get(trackID: trackID) {
            return cached
        }
        // 2) Build URL
        guard let url = URL(string: "https://itunes.apple.com/lookup?id=\(trackID)&country=\(country)") else {
            return [:]
        }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return [:]
            }
            struct LookupResponse: Codable {
                struct Result: Codable {
                    let artworkUrl100: String?
                    let trackViewUrl: String?
                }
                let results: [Result]
            }
            let lookup = try JSONDecoder().decode(LookupResponse.self, from: data)
            if let first = lookup.results.first {
                let artwork = first.artworkUrl100?.replacingOccurrences(of: "100x100bb", with: "512x512bb") ?? ""
                let info: [String: String] = [
                    "artworkUrl": artwork,
                    "iTunesUrl": first.trackViewUrl ?? ""
                ]
                cache.set(info, for: trackID)
                return info
            }
        } catch {
            print("AppleMusicService.fetchTrackExtras error:", error)
        }
        return [:]
    }
    
    /// Fallback search-based lookup via iTunes Search API.
    func searchTrackExtras(name: String,
                           artist: String,
                           album: String?,
                           country: String = Locale.current.region?.identifier.lowercased() ?? "us") async -> [String: String] {
        let query = "\(artist) \(name)"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "https://itunes.apple.com/search?term=\(query)&entity=musicTrack&limit=1&country=\(country)") else {
            return [:]
        }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return [:]
            }
            struct SearchResponse: Codable {
                struct Track: Codable {
                    let artworkUrl100: String?
                    let trackViewUrl: String?
                }
                let results: [Track]
            }
            let search = try JSONDecoder().decode(SearchResponse.self, from: data)
            if let first = search.results.first {
                let artwork = first.artworkUrl100?.replacingOccurrences(of: "100x100bb", with: "512x512bb") ?? ""
                return ["artworkUrl": artwork, "iTunesUrl": first.trackViewUrl ?? ""]
            }
        } catch {
            print("AppleMusicService.searchTrackExtras error:", error)
        }
        return [:]
    }
}
