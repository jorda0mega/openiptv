#if DEBUG
import XCTest
@testable import OpenIPTV

final class NetworkStatusTests: XCTestCase {
    private func firstReading(_ status: NetworkStatus) -> Conditions.Network {
        let deadline = Date().addingTimeInterval(3)
        while status.network == .unknown, Date() < deadline { usleep(20_000) }
        return status.network
    }

    private func macLinkIsUnmetered() throws {
        try XCTSkipUnless(firstReading(NetworkStatus(debugNetwork: nil)) == .unmetered, "the Mac's own link isn't unmetered")
    }

    func testMeteredAtSecondsReadsTheMacsLinkUntilThenAndAPhoneNetworkAfter() throws {
        try macLinkIsUnmetered()
        let status = NetworkStatus(debugNetwork: "metered@1.5")
        XCTAssertEqual(firstReading(status), .unmetered)
        XCTAssertTrue(status.knownUnmetered)
        usleep(1_000_000)
        XCTAssertEqual(status.network, .unmetered, "1 s after launch")
        usleep(1_000_000)
        XCTAssertEqual(status.network, .expensive, "2 s after launch, with no change of the Mac's link")
        XCTAssertFalse(status.knownUnmetered)
    }

    func testLowDataAtSecondsTurnsToLowDataModeThen() throws {
        try macLinkIsUnmetered()
        let status = NetworkStatus(debugNetwork: "lowData@0.5")
        XCTAssertEqual(firstReading(status), .unmetered)
        usleep(1_000_000)
        XCTAssertEqual(status.network, .constrained)
    }

    func testMeteredAloneIsAPhoneNetworkFromLaunch() throws {
        try macLinkIsUnmetered()
        XCTAssertEqual(firstReading(NetworkStatus(debugNetwork: "metered")), .expensive)
        XCTAssertEqual(firstReading(NetworkStatus(debugNetwork: "metered@0")), .expensive)
    }

    @MainActor
    func testASwitchToAPhoneNetworkStopsAFetchAheadTheChoiceRefuses() async throws {
        try macLinkIsUnmetered()
        let status = NetworkStatus(debugNetwork: "metered@1")
        XCTAssertEqual(firstReading(status), .unmetered)
        let device = Conditions(network: .unmetered, playing: false, lowPower: false, thermal: .nominal, memoryWarned: false,
                                freeDisk: .init(bytes: 10_000_000_000, countsPurgeable: true), phoneNetwork: .none)
        let lane = Lane(.bytes, atOnce: 1) {
            var now = device
            now.network = status.network
            return now
        }
        let shelf = Shelf<String, Int>(.init(lane: lane, lifetime: .seconds(60))) { _ in
            try await Task.sleep(for: .seconds(4))
            return 1
        }
        let began = ContinuousClock.now
        let fetched = await shelf.warm("film", for: Interest(at: .continueWatching, .likely))
        XCTAssertNil(fetched, "a card's start went on over the phone network with None")
        XCTAssertLessThan(ContinuousClock.now - began, .seconds(3))
    }

    func testAnUnreadableSwitchReadsTheMacsLink() throws {
        try macLinkIsUnmetered()
        for value in ["metered@soon", "cellular@5", ""] {
            XCTAssertEqual(firstReading(NetworkStatus(debugNetwork: value)), .unmetered, value)
        }
    }
}
#endif
