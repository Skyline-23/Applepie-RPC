//
//  DiscordService.swift
//  Applepie-RPC
//
//  Created by 김부성 on 4/21/25.
//

import PythonKit
import Foundation
import Dispatch

class DiscordService {
    private var initRPC: PythonObject = Python.None
    private var setActivityFunc: PythonObject = Python.None
    private var clearActivityFunc: PythonObject = Python.None
    private var rpc: PythonObject? = nil
    private var timer: Timer?
    private let clientID: String
    private let musicService = AppleMusicService()
    
    init(clientID: String) {
        self.clientID = clientID
        print("[DiscordService] init with clientID: \(clientID)")
        // Initialize PythonKit and RPC on main thread
        let module = Python.import("discord_service")
        print("[DiscordService] Imported discord_service module")
        initRPC = module.init_rpc_sync
        setActivityFunc = module.set_activity
        clearActivityFunc = module.clear_activity
        rpc = initRPC(clientID)
        print("[DiscordService] RPC object initialized: \(rpc != nil)")
    }
    
    /// Calls the Python set_activity wrapper with full playback metadata.
    @MainActor
    func setActivity(details: String,
                     state: String,
                     album: String?,
                     position: Double,
                     duration: Double,
                     artworkUrl: String?,
                     itunesUrl: String?,
                     source: String) {
        guard let rpc = self.rpc else { return }
        // Build Python metadata dict exactly as `make_activity` expects
        let pyMeta: PythonObject = [
            "title": PythonObject(details),
            "artist": PythonObject(state),
            "album": PythonObject(album ?? ""),
            "position": PythonObject(position),
            "duration": PythonObject(duration),
            "artworkUrl": PythonObject(artworkUrl ?? ""),
            "itunes_id": PythonObject(itunesUrl ?? "")
        ]
        let pySource = PythonObject(source)
        // Determine the user's region code for the iTunes Lookup
        let countryCode = Locale.current.region?.identifier.lowercased() ?? "us"
        let pyCountry = PythonObject(countryCode)
        print(self.setActivityFunc(rpc, pyMeta, pySource, pyCountry))
    }
    
    @MainActor
    func clearActivity() {
        print("[DiscordService] clearActivity called")
        if let rpc = self.rpc {
            _ = self.clearActivityFunc(rpc)
        }
    }
    
    /// Begin sending activity at a regular interval using full playback data.
    /// - Parameters:
    ///   - interval: seconds between each update
    ///   - detailsProvider: returns (trackID, details, album?, position, duration)
    @MainActor
    func startPeriodicUpdates(interval: TimeInterval,
                              detailsProvider: @escaping () -> (itunesID: String?, details: String, album: String?, position: Double, duration: Double)) {
        print("[DiscordService] startPeriodicUpdates interval: \(interval)")
        self.timer?.invalidate()
        self.timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task {
                // 1) Core playback data
                let (itunesID, details, album, position, duration) = detailsProvider()
                // If there's no current track, clear any existing activity and skip update
                if details.isEmpty {
                    await self.clearActivity()
                    return
                }
                let lookupKey = itunesID ?? details // Use iTunes ID if available, otherwise use track name
                var extras = await self.musicService.fetchTrackExtras(trackID: lookupKey)
                if extras["artworkUrl"]?.isEmpty ?? true {
                    extras = await self.musicService.searchTrackExtras(name: details, artist: album ?? "", album: album)
                }
                let artwork = extras["artworkUrl"]
                let iTunes  = extras["iTunesUrl"]
                // 3) Update Discord
                await self.setActivity(details: details,
                                 state: album ?? "",
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
        rpc = initRPC(clientID)
        print("[DiscordService] RPC start result: \(rpc != nil)")
    }
    
    /// Manually stop the Discord RPC connection and clear activity.
    func stop() {
        print("[DiscordService] stop() called")
        Task { @MainActor in
            self.clearActivity()
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
