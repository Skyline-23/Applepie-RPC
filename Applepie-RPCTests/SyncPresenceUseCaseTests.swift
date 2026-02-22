import Foundation
import Testing
@testable import Applepie_RPC

@MainActor
final class StubPlaybackStateSource: PlaybackStateStreaming {
    private var continuation: AsyncStream<PlaybackStateSnapshot>.Continuation?

    func makePlaybackStateStream() -> AsyncStream<PlaybackStateSnapshot> {
        AsyncStream(
            PlaybackStateSnapshot.self,
            bufferingPolicy: .bufferingNewest(10)
        ) { continuation in
            self.continuation = continuation
        }
    }

    func emit(_ snapshot: PlaybackStateSnapshot) {
        continuation?.yield(snapshot)
    }

    func finish() {
        continuation?.finish()
        continuation = nil
    }
}

@MainActor
final class SpyDiscordService: DiscordServiceProviding {
    struct ActivityPayload: Equatable {
        let trackID: String?
        let title: String
        let artist: String?
        let album: String?
        let position: Double
        let duration: Double
    }

    var connectionState: ConnectionState = .connected
    var onConnectionStateChange: ((ConnectionState) -> Void)?
    private(set) var activityPayloads: [ActivityPayload] = []
    private(set) var clearCount: Int = 0

    func setMusicKitEnabled(_ enabled: Bool) {}
    func setClearInterval(_ interval: TimeInterval) {}

    func setActivity(
        trackID: String?,
        title: String,
        artist: String?,
        album: String?,
        position: Double,
        duration: Double
    ) async {
        activityPayloads.append(
            ActivityPayload(
                trackID: trackID,
                title: title,
                artist: artist,
                album: album,
                position: position,
                duration: duration
            )
        )
    }

    func clearActivity(allowStart: Bool) async {
        clearCount += 1
    }
}

@MainActor
struct SyncPresenceUseCaseTests {
    private func waitForEventLoop() async {
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    private func snapshot(title: String?) -> PlaybackStateSnapshot {
        let playingData: PlayingData?
        if let title {
            playingData = PlayingData(
                trackID: nil,
                title: title,
                artist: "Artist",
                album: "Album",
                position: 5.0,
                duration: 180.0
            )
        } else {
            playingData = nil
        }

        return PlaybackStateSnapshot(
            playingData: playingData,
            deviceConnection: .connected
        )
    }

    @Test
    func emitsActivityWhenTrackChanges() async {
        let source = StubPlaybackStateSource()
        let discord = SpyDiscordService()
        let useCase = SyncPresenceUseCase()
        var paused = false

        useCase.start(
            discordService: discord,
            playbackStateSource: source,
            isPaused: { paused }
        )
        await waitForEventLoop()

        source.emit(snapshot(title: "Track A"))
        await waitForEventLoop()
        source.emit(snapshot(title: "Track B"))
        await waitForEventLoop()

        #expect(discord.activityPayloads.count >= 2)
        #expect(discord.activityPayloads.last?.title == "Track B")

        source.finish()
        useCase.stop(clearPresence: false)
    }

    @Test
    func clearsPresenceOnNilPlaybackState() async {
        let source = StubPlaybackStateSource()
        let discord = SpyDiscordService()
        let useCase = SyncPresenceUseCase()

        useCase.start(
            discordService: discord,
            playbackStateSource: source,
            isPaused: { false }
        )
        await waitForEventLoop()

        source.emit(snapshot(title: "Track A"))
        await waitForEventLoop()

        let beforeClear = discord.clearCount
        source.emit(snapshot(title: nil))
        await waitForEventLoop()

        #expect(discord.clearCount > beforeClear)

        source.finish()
        useCase.stop(clearPresence: false)
    }

    @Test
    func clearsPresenceWhenPausedFlagTurnsOn() async {
        let source = StubPlaybackStateSource()
        let discord = SpyDiscordService()
        let useCase = SyncPresenceUseCase()
        var paused = false

        useCase.start(
            discordService: discord,
            playbackStateSource: source,
            isPaused: { paused }
        )
        await waitForEventLoop()

        source.emit(snapshot(title: "Track A"))
        await waitForEventLoop()

        let beforeClear = discord.clearCount
        paused = true
        useCase.handlePauseStateChanged()
        await waitForEventLoop()

        #expect(discord.clearCount > beforeClear)

        source.finish()
        useCase.stop(clearPresence: false)
    }
}
