import XCTest
@testable import OpenIPTV

/// How a film is drawn on iPhone and iPad, from what the server says of its picture: Dolby Vision profile 5 has
/// no HDR10 or SDR base, so only libmpv's GPU output shows its colours right, with no Picture in Picture.
final class FilmSurfaceTests: XCTestCase {
    private func playback(videoSubType: String?) async throws -> EmbyPlayback {
        let subType = videoSubType.map { ", \"ExtendedVideoType\": \"DolbyVision\", \"ExtendedVideoSubType\": \"\($0)\"" } ?? ""
        let source = """
            {"Id": "ms1", "Protocol": "File", "Container": "mkv", "Path": "/films/film.mkv",
             "SupportsDirectPlay": true, "SupportsDirectStream": true,
             "MediaStreams": [{"Type": "Video", "Width": 3840\(subType)}, {"Type": "Audio", "Index": 1, "Language": "eng"}]}
            """
        let server = try LocalServer(answer: { target in
            if target.contains("/PlaybackInfo") {
                return (200, ["Content-Type": "application/json"], "{\"PlaySessionId\": \"ps1\", \"MediaSources\": [\(source)]}")
            }
            return (200, ["Content-Type": "application/json"], """
                {"Id": "film-0001", "Name": "Film", "Type": "Movie", "RunTimeTicks": 72000000000,
                 "ProductionLocations": ["United States of America"]}
                """)
        })
        defer { server.stop() }
        let account = EmbyAccount(serverURL: URL(string: "http://127.0.0.1:\(server.port)")!, serverName: "test", userId: "U1",
                                  userName: "viewer", accessToken: "tok")
        return try await EmbyClient(account: account, deviceId: "mac-test").playback(itemId: "film-0001", kind: "Movie")
    }

    func testDolbyVisionProfile5PlaysOnTheGPUWithNoPictureInPicture() async throws {
        let surface = try await playback(videoSubType: "DoviProfile50").surface
        XCTAssertEqual(surface, .gpu)
        XCTAssertFalse(surface.offersPictureInPicture)
    }

    func testEveryOtherFilmDrawsFramesWithPictureInPicture() async throws {
        for subType in ["DoviProfile81", "DoviProfile84", "DoviProfile76", "None", nil] {
            let surface = try await playback(videoSubType: subType).surface
            XCTAssertEqual(surface, .frames, "\(subType ?? "no Dolby Vision")")
            XCTAssertTrue(surface.offersPictureInPicture, "\(subType ?? "no Dolby Vision")")
        }
    }
}
