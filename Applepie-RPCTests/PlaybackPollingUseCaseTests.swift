import Testing
@testable import Applepie_RPC

final actor StubPlaybackFetcher: PlaybackFetching {
    private let results: [PlaybackFetchResult]
    private var cursor: Int = 0

    init(results: [PlaybackFetchResult]) {
        self.results = results
    }

    func fetch(host: String) async -> PlaybackFetchResult {
        guard !results.isEmpty else {
            return PlaybackFetchResult(connection: .disconnected, metadata: nil)
        }

        let index = min(cursor, results.count - 1)
        cursor += 1
        return results[index]
    }
}

struct PlaybackPollingUseCaseTests {
    @Test
    func keepsConnectedStateWithinGraceWindow() async {
        let useCase = PlaybackPollingUseCase()
        let fetcher = StubPlaybackFetcher(results: [
            PlaybackFetchResult(connection: .connected, metadata: nil),
            PlaybackFetchResult(connection: .disconnected, metadata: nil)
        ])

        let stream = await useCase.makeStream(interval: 1.0, host: "192.168.0.133", fetcher: fetcher)
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        let second = await iterator.next()

        #expect(first?.connection == .connected)
        #expect(second?.connection == .connected)
    }

    @Test
    func staysDisconnectedWithoutRecentConnectedState() async {
        let useCase = PlaybackPollingUseCase()
        let fetcher = StubPlaybackFetcher(results: [
            PlaybackFetchResult(connection: .disconnected, metadata: nil),
            PlaybackFetchResult(connection: .disconnected, metadata: nil)
        ])

        let stream = await useCase.makeStream(interval: 1.0, host: "192.168.0.133", fetcher: fetcher)
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        let second = await iterator.next()

        #expect(second?.connection == .disconnected)
    }
}
