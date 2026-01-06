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
    private var buttonsEnabled = true
    private let musicService = AppleMusicService()
    private let maxSecondsThreshold = 10_000.0
    private var lastTimingLogAt: Int = 0
    private var lastTimingLogKey: String = ""
    private var lastActivityKey: String?
    private var lastActivitySentAt: Date?
    private let minActivityUpdateInterval: TimeInterval = 15.0
    private(set) var connectionState: ConnectionState = .disconnected
    var onConnectionStateChange: ((ConnectionState) -> Void)?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt: Int = 0
    private let reconnectDelays: [Double] = [2, 4, 8, 15, 30, 60]

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
        setConnectionState(.disconnected)
    }

    func setMusicKitEnabled(_ enabled: Bool) {
        musicService.setMusicKitEnabled(enabled)
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
            debugLog("[DiscordService] RPC is not initialized")
            return
        }

        let activityKey = "\(trackID ?? "")|\(title)|\(artist ?? "")|\(album ?? "")"
        let nowDate = Date()
        if activityKey == lastActivityKey,
           let lastSentAt = lastActivitySentAt,
           nowDate.timeIntervalSince(lastSentAt) < minActivityUpdateInterval {
            return
        }

        let lookupKey = (title + " " + (artist ?? "") + " " + (album ?? ""))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let extras: [String: String]
        if let trackID = trackID, let storeID = Int(trackID), storeID > 0 {
            let storeExtras = await musicService.fetchTrackExtras(lookupKey: trackID, isStoreID: true)
            if storeExtras.isEmpty {
                extras = await musicService.fetchTrackExtras(lookupKey: lookupKey, isStoreID: false)
            } else {
                extras = storeExtras
            }
        } else {
            extras = await musicService.fetchTrackExtras(lookupKey: lookupKey, isStoreID: false)
        }

        let artworkUrl = extras["artworkUrl"]
        let iTunesUrl = extras["iTunesUrl"]

        let details = String(title.prefix(128))
        let stateSource = (artist?.isEmpty == false) ? artist : "Music.app"
        let state = String((stateSource ?? "Music.app").prefix(128))

        let largeText: String?
        if let album, !album.isEmpty {
            largeText = String(album.prefix(128))
        } else {
            largeText = nil
        }

        var buttonsPayload: [[String: String]] = []
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
        let timing = normalizedPlayback(position: position, duration: duration)
        let start = timing.map { now - $0.pos }
        let end = timing.map { (now - $0.pos) + $0.dur }
        let activityName = "Apple Music"
        let timingLogKey = "\(title)|\(artist ?? "")|\(album ?? "")"
        if now - lastTimingLogAt >= 5 || timingLogKey != lastTimingLogKey {
            debugLog("[DiscordService] timing raw pos=\(position) dur=\(duration) normalized=\(String(describing: timing)) now=\(now) start=\(String(describing: start)) end=\(String(describing: end))")
            lastTimingLogAt = now
            lastTimingLogKey = timingLogKey
        }

        var didSend = false
        do {
            try await withButtonsRef(buttonsPayload) { buttonsRef in
                if let buttonsRef {
                    _ = try await rpc.set_activity(
                        activity_type: .lISTENING,
                        state: state,
                        details: details,
                        name: activityName,
                        start: start,
                        end: end,
                        large_image: artworkUrl ?? "appicon",
                        large_text: largeText,
                        buttons: buttonsRef,
                        instance: false
                    )
                } else {
                    _ = try await rpc.set_activity(
                        activity_type: .lISTENING,
                        state: state,
                        details: details,
                        name: activityName,
                        start: start,
                        end: end,
                        large_image: artworkUrl ?? "appicon",
                        large_text: largeText,
                        instance: false
                    )
                }
            }
            didSend = true
        } catch {
            let message = String(describing: error)
            if message.localizedCaseInsensitiveContains("buttons") {
                buttonsEnabled = false
                do {
                    _ = try await rpc.set_activity(
                        activity_type: .lISTENING,
                        state: state,
                        details: details,
                        name: activityName,
                        start: start,
                        end: end,
                        large_image: artworkUrl ?? "appicon",
                        large_text: largeText,
                        instance: false
                    )
                    didSend = true
                } catch {
                    debugLog("[DiscordService] Failed to set activity: \(error)")
                }
            } else {
                debugLog("[DiscordService] Failed to set activity: \(error)")
                handleRpcFailure()
            }
        }
        if didSend {
            lastActivityKey = activityKey
            lastActivitySentAt = nowDate
        }
    }

    private func normalizedPlayback(
        position: Double,
        duration: Double
    ) -> (pos: Int, dur: Int)? {
        var pos = position
        var dur = duration
        if dur > maxSecondsThreshold, pos > maxSecondsThreshold {
            dur /= 1000.0
            pos /= 1000.0
        } else if dur > maxSecondsThreshold, pos <= maxSecondsThreshold {
            dur /= 1000.0
        } else if pos > maxSecondsThreshold, dur <= maxSecondsThreshold {
            pos /= 1000.0
        }
        guard dur > 0 else { return nil }
        if pos < 0 { pos = 0 }
        if pos >= dur { pos = max(0, dur - 1) }
        return (pos: max(0, Int(pos)), dur: max(1, Int(dur)))
    }

    /// Clears the activity on the Discord RPC connection.
    func clearActivity() async {
        guard let rpc else {
            debugLog("[DiscordService] RPC is nil")
            return
        }
        do {
            _ = try await rpc.clear_activity()
            lastActivityKey = nil
            lastActivitySentAt = nil
        } catch {
            debugLog("[DiscordService] Failed to clear activity: \(error)")
            handleRpcFailure()
        }
    }

    /// Manually start/restart the Discord RPC connection.
    private func start() async {
        guard rpc == nil else { return }
        debugLog("[DiscordService] start() called")
        do {
            let client = try await Pypresence.Client.ClientInstance.create(
                executor: executor,
                client_id: clientID
            )
            let loop = await ensureRpcLoop()
            _ = try await client.update_event_loop(loop: loop)
            _ = try await client.start()
            rpc = client
            setConnectionState(.connected)
            debugLog("[DiscordService] RPC start result: true")
        } catch {
            debugLog("[DiscordService] RPC start failed: \(error)")
            setConnectionState(.disconnected)
            scheduleReconnect()
        }
    }

    /// Manually stop the Discord RPC connection and clear activity.
    private func stop() async {
        guard let rpc else {
            debugLog("[DiscordService] RPC is nil")
            setConnectionState(.disconnected)
            return
        }
        cancelReconnect()
        debugLog("[DiscordService] stop() called")
        do {
            _ = try await rpc.clear_activity()
        } catch {
            debugLog("[DiscordService] Failed to clear activity: \(error)")
        }
        do {
            _ = try await rpc.close()
        } catch {
            debugLog("[DiscordService] Failed to close RPC: \(error)")
        }
        self.rpc = nil
        self.rpcLoop = nil
        self.buttonsEnabled = true
        self.lastActivityKey = nil
        self.lastActivitySentAt = nil
        setConnectionState(.disconnected)
        debugLog("[DiscordService] RPC stopped and cleared")
    }

    private func handleRpcFailure() {
        rpc = nil
        rpcLoop = nil
        lastActivityKey = nil
        lastActivitySentAt = nil
        setConnectionState(.disconnected)
        scheduleReconnect()
    }

    private func setConnectionState(_ state: ConnectionState) {
        guard connectionState != state else { return }
        connectionState = state
        if state == .connected {
            reconnectAttempt = 0
            cancelReconnect()
        }
        onConnectionStateChange?(state)
    }

    private func scheduleReconnect() {
        guard reconnectTask == nil else { return }
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if self.rpc != nil {
                    break
                }
                let index = min(self.reconnectAttempt, self.reconnectDelays.count - 1)
                let delay = self.reconnectDelays[index]
                self.reconnectAttempt += 1
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if Task.isCancelled {
                    break
                }
                await self.start()
            }
            self.reconnectTask = nil
        }
    }

    private func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    private func withButtonsRef<T>(
        _ buttons: [[String: String]],
        _ body: (ObjectRef?) async throws -> T
    ) async throws -> T {
        guard buttonsEnabled, !buttons.isEmpty else {
            return try await body(nil)
        }
        do {
            let namespace = await executor.makeNamespace(callables: [:])
            try await namespace.buttons.setValue(buttons)
            let ref = try await namespace.buttons.objectRef()
            return try await body(ref)
        } catch {
            debugLog("[DiscordService] Failed to build buttons payload:", error)
            return try await body(nil)
        }
    }
}

// MARK: - Track Extras Caching and Lookup

/// Simple in-memory and UserDefaults-backed cache for track extras.
class TrackExtrasCache {
    private struct CacheEntry: Codable {
        let info: [String: String]
        let timestamp: TimeInterval
    }

    private let userDefaultsKey = "TrackExtrasCache"
    private let maxEntries = 200
    private let ttl: TimeInterval = 7 * 24 * 60 * 60
    private var cache: [String: CacheEntry]

    init() {
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let decoded = try? JSONDecoder().decode([String: CacheEntry].self, from: data) {
            cache = decoded
        } else if let legacy = UserDefaults.standard.dictionary(forKey: userDefaultsKey) as? [String: [String: String]] {
            let now = Date().timeIntervalSince1970
            cache = legacy.mapValues { CacheEntry(info: $0, timestamp: now) }
            persist()
        } else {
            cache = [:]
        }
        pruneExpired()
    }

    func get(trackID: String) -> [String: String]? {
        guard let entry = cache[trackID] else { return nil }
        if isExpired(entry) {
            cache.removeValue(forKey: trackID)
            persist()
            return nil
        }
        return entry.info
    }

    func set(_ info: [String: String], for trackID: String) {
        let now = Date().timeIntervalSince1970
        cache[trackID] = CacheEntry(info: info, timestamp: now)
        pruneExpired()
        pruneToLimit()
        persist()
    }

    /// Clears all cached track extras from memory and UserDefaults.
    func clear() {
        cache.removeAll()
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
    }

    private func isExpired(_ entry: CacheEntry) -> Bool {
        let now = Date().timeIntervalSince1970
        return now - entry.timestamp > ttl
    }

    private func pruneExpired() {
        let now = Date().timeIntervalSince1970
        cache = cache.filter { now - $0.value.timestamp <= ttl }
    }

    private func pruneToLimit() {
        guard cache.count > maxEntries else { return }
        let sortedKeys = cache.sorted { $0.value.timestamp < $1.value.timestamp }
        let excess = cache.count - maxEntries
        for (index, pair) in sortedKeys.enumerated() where index < excess {
            cache.removeValue(forKey: pair.key)
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(cache) {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        }
    }
}

/// Service to fetch artwork and iTunes URL from Apple Music catalog via MusicKit.
class AppleMusicService {
    private let cache = TrackExtrasCache()
    private var musicKitEnabled = true

    func setMusicKitEnabled(_ enabled: Bool) {
        musicKitEnabled = enabled
    }

    /// Fetch artworkUrl (512x512) and track URL using MusicKit lookup or HTTP search fallback, with caching.
    func fetchTrackExtras(lookupKey key: String, isStoreID: Bool) async -> [String: String] {
        // 1) Return cached if present
        if let cached = cache.get(trackID: key) {
            return cached
        }

        var info: [String: String] = [:]

        // 2) If storeID is numeric, try MusicKit lookup
        if isStoreID {
            guard let storeID = Int(key), storeID > 0 else {
                let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    cache.set(info, for: key)
                    return info
                }
                return await fetchTrackExtras(lookupKey: trimmed, isStoreID: false)
            }
            if musicKitEnabled {
                let request = MusicCatalogResourceRequest<Song>(
                    matching: \.id,
                    equalTo: MusicItemID(String(storeID))
                )
                do {
                    let response = try await request.response()
                    if let song = response.items.first, let artwork = song.artwork,
                       let artURL = artwork.url(width: 512, height: 512)?.absoluteString {
                        let trackUrl = song.url?.absoluteString ?? ""
                        info = ["artworkUrl": artURL, "iTunesUrl": trackUrl]
                    }
                } catch {
                    debugLog("AppleMusicService (MusicKit) lookup error:", error)
                }
            }
            if info.isEmpty {
                info = await fetchITunesLookup(storeID: storeID)
            }
        } else {
            if musicKitEnabled {
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
                    debugLog("AppleMusicService MusicKit search error:", error)
                }
            }
            if info.isEmpty {
                info = await fetchITunesSearch(term: key)
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

    private func fetchITunesLookup(storeID: Int) async -> [String: String] {
        guard let url = URL(string: "https://itunes.apple.com/lookup?id=\(storeID)&entity=song") else {
            return [:]
        }
        return await fetchITunesInfo(url: url)
    }

    private func fetchITunesSearch(term: String) async -> [String: String] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
        guard let url = URL(string: "https://itunes.apple.com/search?term=\(encoded)&media=music&entity=song&limit=1") else {
            return [:]
        }
        return await fetchITunesInfo(url: url)
    }

    private func fetchITunesInfo(url: URL) async -> [String: String] {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(LookupResponse.self, from: data)
            guard let result = response.results.first else { return [:] }
            let artwork = result.artworkUrl100?.replacingOccurrences(of: "100x100", with: "512x512")
            let trackUrl = result.trackViewUrl ?? ""
            var info: [String: String] = [:]
            if let artwork, !artwork.isEmpty {
                info["artworkUrl"] = artwork
            }
            if !trackUrl.isEmpty {
                info["iTunesUrl"] = trackUrl
            }
            return info
        } catch {
            debugLog("AppleMusicService iTunes fallback error:", error)
            return [:]
        }
    }
}

private struct LookupResponse: Codable {
    struct Result: Codable {
        let artworkUrl100: String?
        let trackViewUrl: String?
    }
    let results: [Result]
}
