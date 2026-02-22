//
//  DiscordPresenceCoordinator.swift
//  Applepie-RPC
//

import Foundation
import Combine

@MainActor
final class DiscordPresenceCoordinator {
    private var activityUpdateTask: Task<Void, Never>?
    private var periodicClearTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    func start(
        discordService: any DiscordServiceProviding,
        nowPlayingService: NowPlayingService,
        isPaused: @escaping @MainActor @Sendable () -> Bool
    ) {
        stop()

        nowPlayingService.$playingData
            .prepend(nowPlayingService.playingData)
            .sink { [weak self] data in
                guard let self else { return }
                self.activityUpdateTask?.cancel()
                self.activityUpdateTask = Task { [weak self] in
                    guard self != nil else { return }
                    if await MainActor.run(body: { isPaused() }) {
                        await discordService.clearActivity(allowStart: false)
                        return
                    }
                    guard let data else {
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
                        artist: data.artist ?? "",
                        album: data.album,
                        position: data.position,
                        duration: data.duration
                    )
                }
            }
            .store(in: &cancellables)

        periodicClearTask = Task { [weak self] in
            var lastClearedAt: Date?
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard self != nil else { return }

                let shouldClear = await MainActor.run {
                    isPaused() || nowPlayingService.playingData == nil
                }

                if shouldClear {
                    let now = Date()
                    if lastClearedAt == nil || now.timeIntervalSince(lastClearedAt ?? now) >= 3 {
                        await discordService.clearActivity(allowStart: false)
                        lastClearedAt = now
                    }
                } else {
                    lastClearedAt = nil
                }
            }
        }
    }

    func handlePauseTransition(
        isPaused: Bool,
        wasPaused: Bool,
        discordService: (any DiscordServiceProviding)?
    ) {
        guard isPaused, isPaused != wasPaused else { return }
        activityUpdateTask?.cancel()
        Task { [weak discordService] in
            await discordService?.clearActivity(allowStart: false)
        }
    }

    func stop() {
        activityUpdateTask?.cancel()
        activityUpdateTask = nil
        periodicClearTask?.cancel()
        periodicClearTask = nil
        cancellables.removeAll()
    }
}
