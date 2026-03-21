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

struct PlaybackStateSnapshot: Equatable {
    let playingData: PlayingData?
    let deviceConnection: ConnectionState
    let discordConnection: ConnectionState

    init(
        playingData: PlayingData?,
        deviceConnection: ConnectionState,
        discordConnection: ConnectionState = .unknown
    ) {
        self.playingData = playingData
        self.deviceConnection = deviceConnection
        self.discordConnection = discordConnection
    }
}

actor PlaybackStateStreamHub {
    private var continuations: [UUID: AsyncStream<PlaybackStateSnapshot>.Continuation] = [:]

    func add(
        id: UUID,
        continuation: AsyncStream<PlaybackStateSnapshot>.Continuation
    ) {
        continuations[id] = continuation
    }

    func remove(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    func broadcast(_ snapshot: PlaybackStateSnapshot) {
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }
}

/// Encapsulates now-playing fetch logic via AppleScript.
class NowPlayingService: ObservableObject {
    @Published var playingData: PlayingData?
    @Published var deviceConnection: ConnectionState = .unknown
    @Published var discordConnection: ConnectionState = .unknown

    private let pollingUseCase: PlaybackPollingUseCase
    private let fetchAdapter: PlaybackFetchAdapter
    private let streamHub = PlaybackStateStreamHub()
    private var pollingTask: Task<Void, Never>?
    private var pushTask: Task<Void, Never>?
    @Published private(set) var updateInterval: TimeInterval = 5.0
    private var currentFetchHost: String?
    private var currentFetchInterval: TimeInterval?
    private var atvService: (any ATVServiceProviding)?

    init(
        pollingUseCase: PlaybackPollingUseCase = PlaybackPollingUseCase(),
        fetchAdapter: PlaybackFetchAdapter = PlaybackFetchAdapter()
    ) {
        self.pollingUseCase = pollingUseCase
        self.fetchAdapter = fetchAdapter
    }

    private func makePlayingData(from result: PlaybackFetchResult) -> PlayingData? {
        guard let metadata = result.metadata else { return nil }

        let trimmedTitle = metadata.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return nil }

        let trimmedArtist = metadata.artist?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAlbum = metadata.album?.trimmingCharacters(in: .whitespacesAndNewlines)

        return PlayingData(
            trackID: metadata.trackID,
            title: trimmedTitle,
            artist: (trimmedArtist?.isEmpty == true) ? nil : trimmedArtist,
            album: (trimmedAlbum?.isEmpty == true) ? nil : trimmedAlbum,
            position: metadata.position,
            duration: metadata.duration
        )
    }

    private func snapshot() -> PlaybackStateSnapshot {
        PlaybackStateSnapshot(
            playingData: playingData,
            deviceConnection: deviceConnection,
            discordConnection: discordConnection
        )
    }

    private func publishSnapshot() {
        let currentSnapshot = snapshot()
        Task {
            await streamHub.broadcast(currentSnapshot)
        }
    }

    @MainActor
    private func applyFetchResult(_ result: PlaybackFetchResult) {
        deviceConnection = result.connection
        let newData = makePlayingData(from: result)
        if playingData != newData {
            playingData = newData
        }
        publishSnapshot()
    }

    func makePlaybackStateStream() -> AsyncStream<PlaybackStateSnapshot> {
        let id = UUID()
        let initialSnapshot = snapshot()

        return AsyncStream(
            PlaybackStateSnapshot.self,
            bufferingPolicy: .bufferingNewest(1)
        ) { [streamHub] continuation in
            Task {
                await streamHub.add(id: id, continuation: continuation)
                continuation.yield(initialSnapshot)
            }
            continuation.onTermination = { _ in
                Task {
                    await streamHub.remove(id: id)
                }
            }
        }
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
        debugLog("[NowPlayingService] start interval=\(interval)s host=\(host)")

        pollingTask?.cancel()
        pushTask?.cancel()
        pollingTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.pollingUseCase.makeStream(
                interval: interval,
                host: host,
                fetcher: self.fetchAdapter
            )

            for await result in stream {
                if Task.isCancelled { break }
                await MainActor.run {
                    self.applyFetchResult(result)
                }
            }
        }

        guard host != "localhost" else {
            pushTask = nil
            return
        }

        guard let atvService else {
            debugLog("[NowPlayingService] ATV service not ready; polling only host=\(host)")
            pushTask = nil
            return
        }

        pushTask = Task { [weak self] in
            guard let self else { return }
            let stream = await atvService.makePushStream(host: host)

            for await result in stream {
                if Task.isCancelled { break }
                await MainActor.run {
                    guard self.currentFetchHost == host else { return }
                    if result.connection == .disconnected {
                        debugLog("[NowPlayingService] Ignoring transient push disconnect host=\(host)")
                        return
                    }
                    self.applyFetchResult(
                        PlaybackFetchResult(
                            connection: result.connection,
                            metadata: result.data.map {
                                PlaybackMetadata(
                                    trackID: $0.trackID,
                                    title: $0.title,
                                    artist: $0.artist,
                                    album: $0.album,
                                    position: $0.position,
                                    duration: $0.duration
                                )
                            }
                        )
                    )
                }
            }
        }
    }
    
    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        pushTask?.cancel()
        pushTask = nil
        currentFetchHost = nil
        currentFetchInterval = nil
        deviceConnection = .disconnected
        playingData = nil
        publishSnapshot()
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
        playingData = nil
        pollingTask?.cancel()
        pollingTask = nil
        pushTask?.cancel()
        pushTask = nil
        currentFetchHost = nil
        currentFetchInterval = nil
        publishSnapshot()
        start(interval: newInterval, host: newHost)
    }

    func setDiscordConnection(_ state: ConnectionState) {
        guard discordConnection != state else { return }
        discordConnection = state
        publishSnapshot()
    }

    /// Inject an ATV metadata service for Apple TV/HomePod hosts.
    func setATVService(_ service: any ATVServiceProviding) async {
        atvService = service
        await fetchAdapter.setATVService(service)
    }
    
    /// Begin pairing: shows PIN on Apple TV.
    func pairDeviceBegin(host: String) async -> Bool {
        guard let service = atvService else {
            debugLog("[NowPlayingService] Pair begin requested before ATV service ready host=\(host)")
            return false
        }
        return await service.pairDeviceBeginSync(host: host)
    }

    /// Finish pairing with entered PIN.
    func pairDeviceFinish(host: String, pin: Int) async -> String? {
        guard let service = atvService else {
            debugLog("[NowPlayingService] Pair finish requested before ATV service ready host=\(host)")
            return nil
        }
        return await service.pairDeviceFinishSync(host: host, pin: pin)
    }
    
    /// Cancel pairing
    func pairDeviceCancel(host: String) async -> Bool {
        guard let service = atvService else {
            debugLog("[NowPlayingService] Pair cancel requested before ATV service ready host=\(host)")
            return false
        }
        return await service.cancelPairing(host: host)
    }
    
    /// Check pairing needed
    func isPairingNeeded(host: String) async -> Bool {
        if host == "localhost" {
            return false
        }
        guard let service = atvService else {
            debugLog("[NowPlayingService] Pairing check requested before ATV service ready host=\(host)")
            return false
        }
        return await service.isPairingNeeded(host: host)
    }
    
    func clearCache() async -> Bool {
        guard let service = atvService else { return false }
        return await service.clearCache()
    }
}
