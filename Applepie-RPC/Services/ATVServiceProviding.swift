//
//  ATVServiceProviding.swift
//  Applepie-RPC
//

import Foundation

protocol ATVServiceProviding: AnyObject {
    func getATVProps(host: String) async -> PyatvService.ATVFetchResult
    func makePushStream(host: String) async -> AsyncStream<PyatvService.ATVFetchResult>
    func pairDeviceBeginSync(host: String) async -> Bool
    func pairDeviceFinishSync(host: String, pin: Int) async -> String?
    func cancelPairing(host: String) async -> Bool
    func isPairingNeeded(host: String) async -> Bool
    func clearCache() async -> Bool
}
