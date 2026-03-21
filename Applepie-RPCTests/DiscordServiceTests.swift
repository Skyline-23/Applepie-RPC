import Testing
import PylibKit_Mac
@testable import Applepie_RPC

struct DiscordServiceTests {
    @Test
    func payloadUsesTrackTitleForListeningStatus() {
        let payload = DiscordService.makeActivityPayload(
            title: "Never Gonna Give You Up",
            artist: "Rick Astley",
            album: "Whenever You Need Somebody",
            artworkUrl: "https://example.com/artwork.jpg",
            iTunesUrl: "https://music.apple.com/us/song/example",
            start: 10,
            end: 20,
            countryCode: "us"
        )

        #expect(payload.statusDisplayType == .dETAILS)
        #expect(payload.name == "Apple Music")
        #expect(payload.details == "Never Gonna Give You Up")
        #expect(payload.state == "Rick Astley")
        #expect(payload.largeImage == "https://example.com/artwork.jpg")
        #expect(payload.largeText == "Whenever You Need Somebody")
        #expect(payload.smallImage == nil)
        #expect(payload.smallText == nil)
        #expect(
            payload.buttonsPayload == [[
                "label": "Play on Apple Music",
                "url": "https://music.apple.com/us/song/example"
            ]]
        )
    }

    @Test
    func payloadFallsBackToSearchButtonWithoutArtwork() {
        let payload = DiscordService.makeActivityPayload(
            title: "Track Name",
            artist: nil,
            album: "Album Name",
            artworkUrl: nil,
            iTunesUrl: nil,
            start: nil,
            end: nil,
            countryCode: "kr"
        )

        #expect(payload.statusDisplayType == .dETAILS)
        #expect(payload.state == "Music.app")
        #expect(payload.largeImage == nil)
        #expect(payload.largeText == "Album Name")
        #expect(payload.smallImage == nil)
        #expect(payload.smallText == nil)
        #expect(
            payload.buttonsPayload == [[
                "label": "Search on Apple Music",
                "url": "https://music.apple.com/kr/search?term=Track%20Name%20Album%20Name"
            ]]
        )
    }
}
