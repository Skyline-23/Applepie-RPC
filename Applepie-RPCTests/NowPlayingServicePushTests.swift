import Foundation
import Testing
@testable import Applepie_RPC

final actor StubPushATVService: ATVServiceProviding {
    private let fetchResult: PyatvService.ATVFetchResult
    private var continuation: AsyncStream<PyatvService.ATVFetchResult>.Continuation?
    private var bufferedResults: [PyatvService.ATVFetchResult] = []

    init(fetchResult: PyatvService.ATVFetchResult) {
        self.fetchResult = fetchResult
    }

    func getATVProps(host: String) async -> PyatvService.ATVFetchResult {
        fetchResult
    }

    func makePushStream(host: String) async -> AsyncStream<PyatvService.ATVFetchResult> {
        AsyncStream(
            PyatvService.ATVFetchResult.self,
            bufferingPolicy: .bufferingNewest(10)
        ) { continuation in
            Task {
                self.setContinuation(continuation)
            }
        }
    }

    func emit(_ result: PyatvService.ATVFetchResult) {
        guard let continuation else {
            bufferedResults.append(result)
            return
        }
        continuation.yield(result)
    }

    func hasSubscriber() -> Bool {
        continuation != nil
    }

    func pairDeviceBeginSync(host: String) async -> Bool { false }
    func pairDeviceFinishSync(host: String, pin: Int) async -> String? { nil }
    func cancelPairing(host: String) async -> Bool { false }
    func isPairingNeeded(host: String) async -> Bool { false }
    func clearCache() async -> Bool { true }

    private func setContinuation(_ continuation: AsyncStream<PyatvService.ATVFetchResult>.Continuation) {
        self.continuation = continuation
        for result in bufferedResults {
            continuation.yield(result)
        }
        bufferedResults.removeAll()
    }
}

@MainActor
struct NowPlayingServicePushTests {
    private func waitUntil(
        timeout: TimeInterval = 1.0,
        condition: @escaping () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await condition()
    }

    @Test
    func appliesRemotePushUpdateImmediately() async {
        let nowPlayingService = NowPlayingService()
        let atvService = StubPushATVService(
            fetchResult: PyatvService.ATVFetchResult(connection: .connected, data: nil)
        )
        await nowPlayingService.setATVService(atvService)

        nowPlayingService.start(interval: 60, host: "192.168.0.133")
        let pushSubscriberReady = await waitUntil {
            await atvService.hasSubscriber()
        }
        #expect(pushSubscriberReady)

        await atvService.emit(
            PyatvService.ATVFetchResult(
                connection: .connected,
                data: PyatvService.ATVProps(
                    trackID: "track-2",
                    title: "Track From Push",
                    artist: "Artist",
                    album: "Album",
                    position: 2,
                    duration: 180
                )
            )
        )

        let receivedPush = await waitUntil {
            await MainActor.run {
                nowPlayingService.playingData?.title == "Track From Push"
            }
        }

        #expect(receivedPush)
        #expect(nowPlayingService.deviceConnection == .connected)
        #expect(nowPlayingService.playingData?.trackID == "track-2")
        #expect(nowPlayingService.playingData?.title == "Track From Push")

        nowPlayingService.stop()
    }

    @Test
    func ignoresPushDisconnectWhilePollingOwnsRecovery() async {
        let nowPlayingService = NowPlayingService()
        let atvService = StubPushATVService(
            fetchResult: PyatvService.ATVFetchResult(
                connection: .connected,
                data: PyatvService.ATVProps(
                    trackID: "poll-track",
                    title: "Track From Poll",
                    artist: "Artist",
                    album: "Album",
                    position: 15,
                    duration: 180
                )
            )
        )
        await nowPlayingService.setATVService(atvService)

        nowPlayingService.start(interval: 0.5, host: "192.168.0.133")

        let pushSubscriberReady = await waitUntil {
            await atvService.hasSubscriber()
        }
        #expect(pushSubscriberReady)

        let receivedPollingData = await waitUntil(timeout: 1.5) {
            await MainActor.run {
                nowPlayingService.deviceConnection == .connected &&
                nowPlayingService.playingData?.title == "Track From Poll"
            }
        }
        #expect(receivedPollingData)

        await atvService.emit(
            PyatvService.ATVFetchResult(connection: .disconnected, data: nil)
        )

        try? await Task.sleep(nanoseconds: 150_000_000)

        #expect(nowPlayingService.deviceConnection == .connected)
        #expect(nowPlayingService.playingData?.title == "Track From Poll")

        nowPlayingService.stop()
    }
}
