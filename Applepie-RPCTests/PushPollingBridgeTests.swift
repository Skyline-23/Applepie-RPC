import Foundation
import Testing
@testable import Applepie_RPC

struct PushPollingBridgeTests {
    private func makeResult() -> PyatvService.ATVFetchResult {
        PyatvService.ATVFetchResult(
            connection: .connected,
            data: PyatvService.ATVProps(
                trackID: "track-1",
                title: "Track",
                artist: "Artist",
                album: "Album",
                position: 42,
                duration: 180
            )
        )
    }

    @Test
    func returnsFreshPushResultForPolling() {
        let now = Date()
        let result = makeResult()
        let bridged = PushPollingBridge.resultForPolling(
            latestResult: result,
            receivedAt: now.addingTimeInterval(-1),
            hasActiveConnection: false,
            ttl: 2,
            now: now
        )

        #expect(bridged?.connection == .connected)
        #expect(bridged?.data?.trackID == "track-1")
        #expect(bridged?.data?.title == "Track")
    }

    @Test
    func keepsStaleConnectedPushResultWhilePushSessionIsActive() {
        let now = Date()
        let result = makeResult()
        let bridged = PushPollingBridge.resultForPolling(
            latestResult: result,
            receivedAt: now.addingTimeInterval(-30),
            hasActiveConnection: true,
            ttl: 2,
            now: now
        )

        #expect(bridged?.connection == .connected)
        #expect(bridged?.data?.trackID == "track-1")
        #expect(bridged?.data?.title == "Track")
    }

    @Test
    func dropsStalePushResultWhenNoActivePushSessionExists() {
        let now = Date()
        let result = makeResult()

        #expect(
            PushPollingBridge.resultForPolling(
                latestResult: result,
                receivedAt: now.addingTimeInterval(-30),
                hasActiveConnection: false,
                ttl: 2,
                now: now
            ) == nil
        )
    }

    @Test
    func dropsDisconnectedPushResult() {
        let now = Date()
        let result = PyatvService.ATVFetchResult(connection: .disconnected, data: nil)

        #expect(
            PushPollingBridge.resultForPolling(
                latestResult: result,
                receivedAt: now.addingTimeInterval(-1),
                hasActiveConnection: true,
                ttl: 2,
                now: now
            ) == nil
        )
    }
}
