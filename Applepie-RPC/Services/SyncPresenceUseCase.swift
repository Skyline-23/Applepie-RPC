//
//  SyncPresenceUseCase.swift
//  Applepie-RPC
//

import Foundation

@MainActor
final class SyncPresenceUseCase {
    private var syncTask: Task<Void, Never>?
    private var latestSnapshot = PlaybackStateSnapshot(
        playingData: nil,
        deviceConnection: .unknown
    )
    private weak var discordService: (any DiscordServiceProviding)?
    private var isPausedProvider: (@MainActor () -> Bool)?

    func start(
        discordService: any DiscordServiceProviding,
        nowPlayingService: NowPlayingService,
        isPaused: @escaping @MainActor () -> Bool
    ) {
        stop(clearPresence: false)
        self.discordService = discordService
        self.isPausedProvider = isPaused

        syncTask = Task { [weak self] in
            guard let self else { return }
            let stream = nowPlayingService.makePlaybackStateStream()
            for await snapshot in stream {
                if Task.isCancelled { return }
                await self.consume(snapshot)
            }
        }
    }

    func handlePauseStateChanged() {
        Task { [weak self] in
            guard let self else { return }
            await self.syncPresence(snapshot: self.latestSnapshot)
        }
    }

    func stop(clearPresence: Bool) {
        syncTask?.cancel()
        syncTask = nil

        guard clearPresence else { return }
        Task { [weak self] in
            await self?.discordService?.clearActivity(allowStart: false)
        }
    }

    private func consume(_ snapshot: PlaybackStateSnapshot) async {
        latestSnapshot = snapshot
        await syncPresence(snapshot: snapshot)
    }

    private func syncPresence(snapshot: PlaybackStateSnapshot) async {
        guard let discordService else { return }

        let isPaused = isPausedProvider?() ?? false
        if isPaused {
            await discordService.clearActivity(allowStart: false)
            return
        }

        guard let data = snapshot.playingData else {
            await discordService.clearActivity(allowStart: false)
            return
        }

        let trimmedTitle = data.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            await discordService.clearActivity(allowStart: false)
            return
        }

        await discordService.setActivity(
            trackID: data.trackID,
            title: trimmedTitle,
            artist: data.artist,
            album: data.album,
            position: data.position,
            duration: data.duration
        )
    }
}
