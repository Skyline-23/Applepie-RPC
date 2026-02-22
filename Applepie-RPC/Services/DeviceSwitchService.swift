//
//  DeviceSwitchService.swift
//  Applepie-RPC
//

import Foundation

@MainActor
final class DeviceSwitchService {
    struct SwitchResult {
        let selectedHost: String
        let previousHost: String
    }

    func switchHost(
        oldHost: String,
        newHost: String,
        hostIPs: [String: String],
        updateInterval: TimeInterval,
        nowPlayingService: NowPlayingService,
        requestPIN: @escaping @MainActor () async -> Int?,
        onPairingFailed: @escaping @MainActor () -> Void
    ) async -> SwitchResult {
        nowPlayingService.stop()

        let newHostIP = hostIPs[newHost] ?? ""
        debugLog("[UI] Device selection: \(oldHost) -> \(newHost) (ip=\(newHostIP))")
        guard !newHostIP.isEmpty else {
            debugLog("[UI] Device switch aborted: no IP resolved for \(newHost)")
            return SwitchResult(selectedHost: oldHost, previousHost: oldHost)
        }

        let needsPairing = await nowPlayingService.isPairingNeeded(host: newHostIP)
        debugLog("[UI] Pairing needed: \(needsPairing) (host=\(newHostIP))")
        if needsPairing {
            let began = await nowPlayingService.pairDeviceBegin(host: newHostIP)
            guard began else {
                onPairingFailed()
                return SwitchResult(selectedHost: oldHost, previousHost: oldHost)
            }

            if let pin = await requestPIN() {
                if let creds = await nowPlayingService.pairDeviceFinish(host: newHostIP, pin: pin) {
                    debugLog("[PyatvService] Pairing finished with credentials:", creds)
                    nowPlayingService.updateTimer(updateInterval, newHostIP)
                    return SwitchResult(selectedHost: newHost, previousHost: newHost)
                }
                debugLog("[PyatvService] Pairing failed")
                onPairingFailed()
                return SwitchResult(selectedHost: oldHost, previousHost: oldHost)
            }

            _ = await nowPlayingService.pairDeviceCancel(host: newHostIP)
            return SwitchResult(selectedHost: oldHost, previousHost: oldHost)
        }

        nowPlayingService.updateTimer(updateInterval, newHostIP)
        debugLog("[UI] Switched device to \(newHost) (ip=\(newHostIP))")
        return SwitchResult(selectedHost: newHost, previousHost: newHost)
    }

    func resetToLocalhost(
        localhostName: String,
        updateInterval: TimeInterval,
        nowPlayingService: NowPlayingService
    ) -> SwitchResult {
        nowPlayingService.updateTimer(updateInterval, "localhost")
        return SwitchResult(selectedHost: localhostName, previousHost: localhostName)
    }
}
