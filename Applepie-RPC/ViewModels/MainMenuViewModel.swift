//
//  MainMenuViewModel.swift
//  Applepie-RPC
//

import Foundation

@MainActor
final class MainMenuViewModel: ObservableObject {
    @Published private(set) var selectedHost: String
    @Published private(set) var previousHost: String
    @Published private(set) var hosts: [String]
    @Published private(set) var settings: AppSettingsSnapshot
    @Published private(set) var deviceConnection: ConnectionState = .unknown
    @Published private(set) var discordConnection: ConnectionState = .unknown
    @Published private(set) var currentTitle: String = ""
    @Published private(set) var updateChannel: AppUpdateChannel
    @Published private(set) var updateStatusMessage: String = ""
    @Published private(set) var updateLog: [String] = []
    @Published private(set) var lastUpdateSucceeded: Bool?
    @Published private(set) var isUpdating: Bool = false
    @Published var shouldShowUpdatePopup: Bool = false

    private let localhostName: String
    private let localhostIPAddress = "localhost"

    private let deviceSwitchService: DeviceSwitchService
    private let nowPlayingService: NowPlayingService
    private let playbackControlService: PlaybackControlService
    private let updaterService: UpdaterService
    private let settingsRepository: any SettingsRepository
    private let airPlayBrowser: AirPlayBrowser

    private var serviceIPs: [String: String]

    private var settingsTask: Task<Void, Never>?
    private var playbackStateTask: Task<Void, Never>?
    private var discoveryTask: Task<Void, Never>?
    private var updaterTask: Task<Void, Never>?

    init(
        localhostName: String = .localizable(.localhostName),
        deviceSwitchService: DeviceSwitchService? = nil,
        nowPlayingService: NowPlayingService,
        playbackControlService: PlaybackControlService,
        updaterService: UpdaterService,
        settingsRepository: any SettingsRepository,
        airPlayBrowser: AirPlayBrowser
    ) {
        self.localhostName = localhostName
        self.selectedHost = localhostName
        self.previousHost = localhostName
        self.hosts = Self.normalizedHosts(
            airPlayBrowser.hosts,
            localhostName: localhostName
        )
        self.settings = settingsRepository.current
        self.updateChannel = updaterService.updateChannel

        var resolvedIPs = airPlayBrowser.serviceIPs
        if resolvedIPs[localhostName] == nil {
            resolvedIPs[localhostName] = localhostIPAddress
        }
        self.serviceIPs = resolvedIPs

        self.deviceSwitchService = deviceSwitchService ?? DeviceSwitchService()
        self.nowPlayingService = nowPlayingService
        self.playbackControlService = playbackControlService
        self.updaterService = updaterService
        self.settingsRepository = settingsRepository
        self.airPlayBrowser = airPlayBrowser

        applyPlaybackSnapshot(
            PlaybackStateSnapshot(
                playingData: nowPlayingService.playingData,
                deviceConnection: nowPlayingService.deviceConnection,
                discordConnection: nowPlayingService.discordConnection
            )
        )
        applyUpdaterSnapshot(updaterService.currentState)
        startObservations()
    }

    deinit {
        settingsTask?.cancel()
        playbackStateTask?.cancel()
        discoveryTask?.cancel()
        updaterTask?.cancel()
    }

    var effectiveDeviceConnection: ConnectionState {
        settings.isPaused ? .disconnected : deviceConnection
    }

    var updateChannelName: String {
        switch updateChannel {
        case .sparkle:
            return "Sparkle"
        case .homebrew:
            return "Homebrew"
        }
    }

    var homebrewUpgradeCommand: String {
        updaterService.homebrewUpgradeCommand
    }

    var latestUpdateLogLine: String? {
        updateLog.last
    }

    var canCopyHomebrewCommand: Bool {
        guard updateChannel == .homebrew else { return false }
        guard !isUpdating else { return false }
        return lastUpdateSucceeded == false
    }

    var canRelaunchApplication: Bool {
        guard updateChannel == .homebrew else { return false }
        guard !isUpdating else { return false }
        return lastUpdateSucceeded == true
    }

    func setEnabled(_ isEnabled: Bool) {
        let isPaused = !isEnabled
        settingsRepository.setPaused(isPaused)

        if isPaused {
            playbackControlService.pausePlayback()
            return
        }

        playbackControlService.resumePlayback(
            interval: settings.updateInterval,
            host: currentHostIPAddress()
        )
    }

    func updateInterval(_ interval: TimeInterval) {
        settingsRepository.setUpdateInterval(interval)
        nowPlayingService.updateTimer(interval, currentHostIPAddress())
    }

    func selectHost(
        _ host: String,
        requestPIN: @escaping @MainActor () async -> Int?,
        onPairingFailed: @escaping @MainActor () -> Void
    ) async {
        guard host != previousHost else { return }

        let result = await deviceSwitchService.switchHost(
            oldHost: previousHost,
            newHost: host,
            hostIPs: serviceIPs,
            updateInterval: settings.updateInterval,
            nowPlayingService: nowPlayingService,
            requestPIN: requestPIN,
            onPairingFailed: onPairingFailed
        )
        selectedHost = result.selectedHost
        previousHost = result.previousHost
    }

    func resetToLocalhost() {
        let result = deviceSwitchService.resetToLocalhost(
            localhostName: localhostName,
            updateInterval: settings.updateInterval,
            nowPlayingService: nowPlayingService
        )
        selectedHost = result.selectedHost
        previousHost = result.previousHost
    }

    func clearCache() async -> Bool {
        resetToLocalhost()
        return await nowPlayingService.clearCache()
    }

    func dismissUpdatePopup() {
        shouldShowUpdatePopup = false
    }

    func checkForUpdates() async {
        if updateChannel == .homebrew {
            shouldShowUpdatePopup = true
        }

        let result = await updaterService.checkForUpdates()
        switch result {
        case .sparkleOpened:
            break
        case .alreadyRunning:
            if updateChannel == .homebrew {
                shouldShowUpdatePopup = true
            }
        case .homebrewCompleted, .homebrewFailed, .homebrewBinaryMissing:
            shouldShowUpdatePopup = true
        }
    }

    func relaunchApplication() {
        _ = updaterService.relaunchApplication()
    }

    private func startObservations() {
        settingsTask?.cancel()
        settingsTask = Task { [weak self] in
            guard let self else { return }
            let stream = settingsRepository.makeSettingsStream()
            for await snapshot in stream {
                if Task.isCancelled { return }
                self.settings = snapshot
            }
        }

        playbackStateTask?.cancel()
        playbackStateTask = Task { [weak self] in
            guard let self else { return }
            let stream = nowPlayingService.makePlaybackStateStream()
            for await snapshot in stream {
                if Task.isCancelled { return }
                self.applyPlaybackSnapshot(snapshot)
            }
        }

        discoveryTask?.cancel()
        discoveryTask = Task { [weak self] in
            guard let self else { return }
            let stream = airPlayBrowser.makeDiscoveryStream()
            for await snapshot in stream {
                if Task.isCancelled { return }
                self.applyDiscoverySnapshot(snapshot)
            }
        }

        updaterTask?.cancel()
        updaterTask = Task { [weak self] in
            guard let self else { return }
            let stream = updaterService.makeStateStream()
            for await snapshot in stream {
                if Task.isCancelled { return }
                self.applyUpdaterSnapshot(snapshot)
            }
        }
    }

    private func applyPlaybackSnapshot(_ snapshot: PlaybackStateSnapshot) {
        deviceConnection = snapshot.deviceConnection
        discordConnection = snapshot.discordConnection

        let title = snapshot.playingData?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        currentTitle = title
    }

    private func applyDiscoverySnapshot(_ snapshot: AirPlayDiscoverySnapshot) {
        hosts = Self.normalizedHosts(snapshot.hosts, localhostName: localhostName)
        serviceIPs = snapshot.serviceIPs
        if serviceIPs[localhostName] == nil {
            serviceIPs[localhostName] = localhostIPAddress
        }

        if !hosts.contains(selectedHost) {
            resetToLocalhost()
        }
    }

    private func applyUpdaterSnapshot(_ snapshot: UpdaterStateSnapshot) {
        updateChannel = snapshot.updateChannel
        updateStatusMessage = snapshot.updateStatusMessage
        updateLog = snapshot.updateLog
        lastUpdateSucceeded = snapshot.lastUpdateSucceeded
        isUpdating = snapshot.isUpdating
    }

    private func currentHostIPAddress() -> String {
        ipAddress(for: selectedHost)
    }

    private func ipAddress(for host: String) -> String {
        if host == localhostName {
            return localhostIPAddress
        }
        return serviceIPs[host] ?? ""
    }

    private static func normalizedHosts(
        _ discoveredHosts: [String],
        localhostName: String
    ) -> [String] {
        var ordered: [String] = [localhostName]
        for host in discoveredHosts where host != localhostName {
            if !ordered.contains(host) {
                ordered.append(host)
            }
        }
        return ordered
    }
}
