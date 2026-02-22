//
//  DiscordServiceProviding.swift
//  Applepie-RPC
//

import Foundation

protocol DiscordServiceProviding: AnyObject {
    var connectionState: ConnectionState { get }
    var onConnectionStateChange: ((ConnectionState) -> Void)? { get set }

    func setMusicKitEnabled(_ enabled: Bool)
    func setClearInterval(_ interval: TimeInterval)
    func setActivity(
        trackID: String?,
        title: String,
        artist: String?,
        album: String?,
        position: Double,
        duration: Double
    ) async
    func clearActivity(allowStart: Bool) async
}
