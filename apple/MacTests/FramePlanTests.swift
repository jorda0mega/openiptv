import XCTest
@testable import OpenIPTV

final class FramePlanTests: XCTestCase {
    private let film = PixelSize(width: 1920, height: 1080)
    private let phone = PixelSize(width: 2622, height: 1206)

    func testFitDrawsTheFilmsShapeAtMostItsOwnSize() {
        XCTAssertEqual(FramePlan.make(video: film, screen: phone, window: nil, fill: false),
                       FramePlan(size: PixelSize(width: 1920, height: 1080), fills: false))
    }

    func testFitUprightDrawsNoMoreThanTheScreenShows() {
        let upright = PixelSize(width: 1206, height: 2622)
        XCTAssertEqual(FramePlan.make(video: film, screen: upright, window: nil, fill: false).size, PixelSize(width: 1206, height: 678))
    }

    func testFillDrawsTheScreensShapeFromThePartShown() {
        let plan = FramePlan.make(video: film, screen: phone, window: nil, fill: true)
        XCTAssertTrue(plan.fills)
        XCTAssertEqual(plan.size, PixelSize(width: 1920, height: 882))
    }

    func testTheWindowFitsAndWinsOverFill() {
        let plan = FramePlan.make(video: film, screen: phone, window: PixelSize(width: 640, height: 360), fill: true)
        XCTAssertEqual(plan, FramePlan(size: PixelSize(width: 640, height: 360), fills: false))
    }

    func testFourKIsDrawnAtAbout1080p() {
        let uhd = PixelSize(width: 3840, height: 2160)
        let big = PixelSize(width: 2732, height: 2048)
        XCTAssertEqual(FramePlan.make(video: uhd, screen: big, window: nil, fill: false).size, PixelSize(width: 1920, height: 1080))
    }

    func testOffScreenDrawsTheFilmsOwnShape() {
        let wide = PixelSize(width: 1920, height: 800)
        XCTAssertEqual(FramePlan.make(video: wide, screen: nil, window: nil, fill: true), FramePlan(size: wide, fills: false))
    }

    func testAnEmptyBoxCountsAsNone() {
        let flat = PixelSize(width: 0, height: 1206)
        XCTAssertEqual(FramePlan.make(video: film, screen: flat, window: PixelSize(width: 640, height: 0), fill: true),
                       FramePlan(size: film, fills: false))
    }

    func testSizesAreEven() {
        let odd = PixelSize(width: 853, height: 481)
        let plan = FramePlan.make(video: odd, screen: phone, window: nil, fill: false)
        XCTAssertEqual(plan.size.width % 2, 0)
        XCTAssertEqual(plan.size.height % 2, 0)
    }

    func testHDRKeepsItsTransferForTheTags() {
        XCTAssertEqual(FrameColor(gamma: "pq"), .pq)
        XCTAssertEqual(FrameColor(gamma: "hlg"), .hlg)
        XCTAssertEqual(FrameColor(gamma: "bt.1886"), .bt709)
        XCTAssertEqual(FrameColor(gamma: nil), .bt709)
    }
}
