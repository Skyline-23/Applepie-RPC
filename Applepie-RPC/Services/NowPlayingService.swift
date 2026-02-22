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
    @Published var deviceConnection: ConnectionState = .unknown
    @Published var discordConnection: ConnectionState = .unknown

    private let pollingUseCase: PlaybackPollingUseCase
    private let fetchAdapter: PlaybackFetchAdapter
    private var pollingTask: Task<Void, Never>?
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
                    self.deviceConnection = result.connection
                    let newData = self.makePlayingData(from: result)
                    if self.playingData != newData {
                        self.playingData = newData
                    }
                }
            }
        }
    }
    
    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        currentFetchHost = nil
        currentFetchInterval = nil
        deviceConnection = .disconnected
        playingData = nil
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
        currentFetchHost = nil
        currentFetchInterval = nil
        start(interval: newInterval, host: newHost)
    }

    func setDiscordConnection(_ state: ConnectionState) {
        guard discordConnection != state else { return }
        discordConnection = state
    }

    /// Inject an ATV metadata service for Apple TV/HomePod hosts.
    func setATVService(_ service: any ATVServiceProviding) async {
        atvService = service
        await fetchAdapter.setATVService(service)
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
