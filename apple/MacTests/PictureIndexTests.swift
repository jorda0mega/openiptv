import XCTest
@testable import OpenIPTV

final class PictureIndexTests: XCTestCase {
    private func url(_ text: String) -> URL { URL(string: "http://server:8096/emby" + text)! }

    func testATitlePagesHeroPictureIsFoundForItsPlay() {
        var index = PictureIndex()
        let hero = url("/Items/m5/Images/Backdrop/0?tag=a1b2&maxWidth=1920&quality=90")
        index.note(hero)
        XCTAssertEqual(index.pictures(of: ["m5"]), [hero], "a title page's Play held no picture though its hero was on screen")
    }

    func testAnEpisodeRowsPictureIsFoundForThatEpisode() {
        var index = PictureIndex()
        let row = url("/Items/e203/Images/Primary?tag=c3&maxWidth=480")
        index.note(row)
        index.note(url("/Items/e204/Images/Primary?tag=c4&maxWidth=480"))
        XCTAssertEqual(index.pictures(of: ["e203"]), [row])
    }

    func testTheWidestPictureOfTheEpisodeOrItsShowComesFirst() {
        var index = PictureIndex()
        let thumb = url("/Items/e203/Images/Primary?maxWidth=180")
        let show = url("/Items/s1/Images/Backdrop/0?tag=d&maxWidth=1920")
        index.note(thumb)
        index.note(show)
        XCTAssertEqual(index.pictures(of: ["e203", "s1"]), [show, thumb])
    }

    func testAnAddressThatIsNoTitlesPictureIsLeftOut() {
        var index = PictureIndex()
        index.note(url("/Users/U1/Items/m5"))
        index.note(URL(string: "http://logo/7.png")!)
        XCTAssertEqual(index.pictures(of: ["m5"]), [])
    }
}
