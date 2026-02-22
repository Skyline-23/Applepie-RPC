//
//  PlaybackControlService.swift
//  Applepie-RPC
//

import Foundation

@MainActor
final class PlaybackControlService: ObservableObject {
    private let nowPlayingService: NowPlayingService
    private weak var discordService: (any DiscordServiceProviding)?

    init(nowPlayingService: NowPlayingService) {
        self.nowPlayingService = nowPlayingService
    }

    func setDiscordService(_ service: any DiscordServiceProviding) {
        discordService = service
    }

    func pausePlayback() {
        nowPlayingService.stop()
        Task { [weak self] in
            await self?.discordService?.clearActivity(allowStart: false)
        }
    }

    func resumePlayback(interval: TimeInterval, host: String) {
        nowPlayingService.updateTimer(interval, host)
    }
}
