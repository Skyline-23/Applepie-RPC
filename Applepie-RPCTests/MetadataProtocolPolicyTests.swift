import PylibKit_Mac
import Testing
@testable import Applepie_RPC

struct MetadataProtocolPolicyTests {
    @Test
    func dropsAirPlayForHomePodWhenAlternativesExist() {
        let available: [Pyatv.Const.PyatvProtocol_] = [.mRP, .companion, .airPlay]

        let filtered = MetadataProtocolPolicy.metadataAvailableProtocols(
            available: available,
            deviceModel: .homePod
        )

        #expect(filtered == [.mRP, .companion])
    }

    @Test
    func keepsAirPlayForHomePodWhenItIsTheOnlyOption() {
        let filtered = MetadataProtocolPolicy.metadataAvailableProtocols(
            available: [.airPlay],
            deviceModel: .homePodMini
        )

        #expect(filtered == [.airPlay])
    }

    @Test
    func keepsAirPlayForNonHomePodDevices() {
        let available: [Pyatv.Const.PyatvProtocol_] = [.mRP, .airPlay]

        let filtered = MetadataProtocolPolicy.metadataAvailableProtocols(
            available: available,
            deviceModel: .appleTV4KGen3
        )

        #expect(filtered == available)
    }

    @Test
    func preservesSoftFailuresForHomePodNonAirPlaySessions() {
        #expect(
            MetadataProtocolPolicy.shouldPreserveConnectionOnSoftFailure(
                deviceModel: .homePodGen2,
                proto: .mRP
            )
        )
        #expect(
            MetadataProtocolPolicy.shouldPreserveConnectionOnSoftFailure(
                deviceModel: .homePodMini,
                proto: .companion
            )
        )
    }

    @Test
    func doesNotPreserveAirPlayOrNonHomePodSoftFailures() {
        #expect(
            !MetadataProtocolPolicy.shouldPreserveConnectionOnSoftFailure(
                deviceModel: .homePod,
                proto: .airPlay
            )
        )
        #expect(
            !MetadataProtocolPolicy.shouldPreserveConnectionOnSoftFailure(
                deviceModel: .appleTV4KGen3,
                proto: .mRP
            )
        )
    }
}
