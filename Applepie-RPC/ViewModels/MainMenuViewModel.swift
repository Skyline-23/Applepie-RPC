//
//  MainMenuViewModel.swift
//  Applepie-RPC
//

import Foundation

@MainActor
final class MainMenuViewModel: ObservableObject {
    @Published var selectedHost: String
    @Published private(set) var previousHost: String

    private let deviceSwitchService: DeviceSwitchService
    private weak var nowPlayingService: NowPlayingService?
    private weak var playbackControlService: PlaybackControlService?
    private weak var updaterService: UpdaterService?

    init(
        localhostName: String = .localizable(.localhostName),
        deviceSwitchService: DeviceSwitchService? = nil
    ) {
        self.selectedHost = localhostName
        self.previousHost = localhostName
        self.deviceSwitchService = deviceSwitchService ?? DeviceSwitchService()
    }

    func configure(
        nowPlayingService: NowPlayingService,
        playbackControlService: PlaybackControlService,
        updaterService: UpdaterService
    ) {
        self.nowPlayingService = nowPlayingService
        self.playbackControlService = playbackControlService
        self.updaterService = updaterService
    }

    func setPaused(
        _ isPaused: Bool,
        setting: AppSettings,
        save: () -> Void,
        currentHostIP: String
    ) {
        setting.isPaused = isPaused
        save()

        guard let playbackControlService else { return }
        if setting.isPaused {
            playbackControlService.pausePlayback()
        } else {
            playbackControlService.resumePlayback(
                interval: setting.updateInterval,
                host: currentHostIP
            )
        }
    }

    func updateInterval(
        _ interval: TimeInterval,
        setting: AppSettings,
        currentHostIP: String
    ) {
        setting.updateInterval = interval
        nowPlayingService?.updateTimer(interval, currentHostIP)
    }

    func selectHost(
        _ host: String,
        hostIPs: [String: String],
        updateInterval: TimeInterval,
        requestPIN: @escaping @MainActor () async -> Int?,
        onPairingFailed: @escaping @MainActor () -> Void
    ) async {
        guard host != previousHost else { return }
        guard let nowPlayingService else { return }

        let result = await deviceSwitchService.switchHost(
            oldHost: previousHost,
            newHost: host,
            hostIPs: hostIPs,
            updateInterval: updateInterval,
            nowPlayingService: nowPlayingService,
            requestPIN: requestPIN,
            onPairingFailed: onPairingFailed
        )
        selectedHost = result.selectedHost
        previousHost = result.previousHost
    }

    func resetToLocalhost(updateInterval: TimeInterval) {
        guard let nowPlayingService else { return }
        let localhostName = String.localizable(.localhostName)
        let result = deviceSwitchService.resetToLocalhost(
            localhostName: localhostName,
            updateInterval: updateInterval,
            nowPlayingService: nowPlayingService
        )
        selectedHost = result.selectedHost
        previousHost = result.previousHost
    }

    func updateChannelName() -> String {
        guard let updaterService else { return "Sparkle" }
        switch updaterService.updateChannel {
        case .sparkle:
            return "Sparkle"
        case .homebrew:
            return "Homebrew"
        }
    }
}
