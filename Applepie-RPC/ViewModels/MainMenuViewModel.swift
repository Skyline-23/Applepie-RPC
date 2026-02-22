//
//  MainMenuViewModel.swift
//  Applepie-RPC
//

import Foundation

@MainActor
final class MainMenuViewModel: ObservableObject {
    @Published var selectedHost: String
    @Published private(set) var previousHost: String
    @Published private(set) var settings: AppSettingsSnapshot = .default

    private let deviceSwitchService: DeviceSwitchService
    private weak var nowPlayingService: NowPlayingService?
    private weak var playbackControlService: PlaybackControlService?
    private weak var updaterService: UpdaterService?
    private weak var settingsRepository: (any SettingsRepository)?
    private var settingsTask: Task<Void, Never>?

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
        updaterService: UpdaterService,
        settingsRepository: any SettingsRepository
    ) {
        self.nowPlayingService = nowPlayingService
        self.playbackControlService = playbackControlService
        self.updaterService = updaterService
        self.settingsRepository = settingsRepository
        self.settings = settingsRepository.current

        settingsTask?.cancel()
        settingsTask = Task { [weak self] in
            guard let self else { return }
            let stream = settingsRepository.makeSettingsStream()
            for await snapshot in stream {
                if Task.isCancelled { return }
                self.settings = snapshot
            }
        }
    }

    deinit {
        settingsTask?.cancel()
    }

    func setEnabled(_ isEnabled: Bool, currentHostIP: String) {
        let isPaused = !isEnabled
        settingsRepository?.setPaused(isPaused)

        guard let playbackControlService else { return }
        if isPaused {
            playbackControlService.pausePlayback()
        } else {
            playbackControlService.resumePlayback(
                interval: settings.updateInterval,
                host: currentHostIP
            )
        }
    }

    func updateInterval(
        _ interval: TimeInterval,
        currentHostIP: String
    ) {
        settingsRepository?.setUpdateInterval(interval)
        nowPlayingService?.updateTimer(interval, currentHostIP)
    }

    func selectHost(
        _ host: String,
        hostIPs: [String: String],
        requestPIN: @escaping @MainActor () async -> Int?,
        onPairingFailed: @escaping @MainActor () -> Void
    ) async {
        guard host != previousHost else { return }
        guard let nowPlayingService else { return }

        let result = await deviceSwitchService.switchHost(
            oldHost: previousHost,
            newHost: host,
            hostIPs: hostIPs,
            updateInterval: settings.updateInterval,
            nowPlayingService: nowPlayingService,
            requestPIN: requestPIN,
            onPairingFailed: onPairingFailed
        )
        selectedHost = result.selectedHost
        previousHost = result.previousHost
    }

    func resetToLocalhost() {
        guard let nowPlayingService else { return }
        let localhostName = String.localizable(.localhostName)
        let result = deviceSwitchService.resetToLocalhost(
            localhostName: localhostName,
            updateInterval: settings.updateInterval,
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
