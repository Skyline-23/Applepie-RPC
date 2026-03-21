import Testing
@testable import Applepie_RPC

struct PlaybackTransitionHeuristicsTests {
    @Test
    func discardsSameMarkerWhenTimelineRewindsNearStart() {
        let previous = PlaybackTimelineSnapshot(
            trackID: "123",
            title: "Old Track",
            artist: "Artist",
            album: "Album",
            position: 97,
            duration: 180
        )
        let current = PlaybackTimelineSnapshot(
            trackID: "123",
            title: "Old Track",
            artist: "Artist",
            album: "Album",
            position: 1,
            duration: 180
        )

        #expect(
            PlaybackTransitionHeuristics.shouldDiscardLikelyStaleRemoteSnapshot(
                previous: previous,
                current: current
            )
        )
    }

    @Test
    func keepsNaturalProgressOnSameMarker() {
        let previous = PlaybackTimelineSnapshot(
            trackID: "123",
            title: "Track",
            artist: "Artist",
            album: "Album",
            position: 12,
            duration: 180
        )
        let current = PlaybackTimelineSnapshot(
            trackID: "123",
            title: "Track",
            artist: "Artist",
            album: "Album",
            position: 18,
            duration: 180
        )

        #expect(
            !PlaybackTransitionHeuristics.shouldDiscardLikelyStaleRemoteSnapshot(
                previous: previous,
                current: current
            )
        )
    }

    @Test
    func keepsDifferentMarkerEvenWhenTimelineResets() {
        let previous = PlaybackTimelineSnapshot(
            trackID: "123",
            title: "Track A",
            artist: "Artist",
            album: "Album",
            position: 97,
            duration: 180
        )
        let current = PlaybackTimelineSnapshot(
            trackID: "456",
            title: "Track B",
            artist: "Artist",
            album: "Album",
            position: 1,
            duration: 180
        )

        #expect(
            !PlaybackTransitionHeuristics.shouldDiscardLikelyStaleRemoteSnapshot(
                previous: previous,
                current: current
            )
        )
    }
}
