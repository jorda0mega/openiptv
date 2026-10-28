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

    func testFramesGoUndrawnOnlyBehindTheAppWithNoWindow() {
        var inputs = FrameInputs()
        XCTAssertFalse(inputs.undrawn)
        inputs.inBackground = true
        XCTAssertTrue(inputs.undrawn, "behind the app with no window")
        inputs.window = PixelSize(width: 640, height: 360)
        XCTAssertFalse(inputs.undrawn, "a window that opens late draws at once")
        inputs.window = nil
        inputs.inBackground = false
        XCTAssertFalse(inputs.undrawn, "back in the app")
    }

    func testHDRKeepsItsTransferForTheTags() {
        XCTAssertEqual(FrameColor(gamma: "pq"), .pq)
        XCTAssertEqual(FrameColor(gamma: "hlg"), .hlg)
        XCTAssertEqual(FrameColor(gamma: "bt.1886"), .bt709)
        XCTAssertEqual(FrameColor(gamma: nil), .bt709)
    }

    /// BT.2408: SDR white in an HDR picture is 203 nits.
    func testSubtitleWhiteIsSDRWhiteInEachTransfer() {
        XCTAssertEqual(pqNits(FrameColor.pq.subtitleWhite), 203, accuracy: 6, "HDR10")
        XCTAssertEqual(hlgNits(FrameColor.hlg.subtitleWhite), 203, accuracy: 6, "HLG on a 1000-nit screen")
        XCTAssertEqual(FrameColor.bt709.subtitleWhite, 255, "SDR")
    }

    /// The orders the reviews walked: `drained(c)` is the drawing queue reaching change c's hop, `hop(c)` that hop
    /// on the player's queue. Notes can come in between.
    func testSubtitleWhiteNeverRisesOverAFrameStillDrawing() {
        play([.note(.pq), .note(.bt709), .note(.hlg), .drained(2), .hop(2), .drained(3), .hop(3)])
        play([.note(.pq), .note(.bt709), .drained(2), .hop(2)])
        play([.note(.hlg), .note(.bt709), .note(.hlg), .drained(2), .hop(2)])
        play([.note(.pq), .note(.bt709), .note(.bt709), .drained(2), .hop(2), .drained(3), .hop(3)])
        play([.note(.pq), .note(.bt709), .drained(2), .note(.hlg), .hop(2), .drained(3), .hop(3)])
        play([.note(.bt709), .note(.hlg), .note(.pq)])
    }

    private enum Step { case note(FrameColor), drained(Int), hop(Int) }

    /// After each step, no tag a frame may still be drawing under has a white below mpv's; at the end, mpv holds
    /// the last tag's white.
    private func play(_ order: [Step], line: UInt = #line) {
        var held = HeldSubtitleWhite()
        var drawing: [(change: Int, color: FrameColor)] = [(0, .bt709)]
        var raises: [Int: FrameColor] = [:]
        var notes = 0
        for step in order {
            switch step {
            case .note(let color):
                notes += 1
                let next = held.noted(color)
                drawing.append((notes, color))
                if let change = next.raise { raises[change] = color }
            case .drained(let change):
                drawing.removeAll { $0.change < change }
            case .hop(let change):
                if let color = raises[change] { _ = held.drawn(change, color) }
            }
            XCTAssertTrue(drawing.allSatisfy { held.white <= $0.color.subtitleWhite },
                          "white \(held.white) over a frame still drawing at \(step)", line: line)
        }
        XCTAssertEqual(held.white, drawing.last?.color.subtitleWhite, "the last tag's white", line: line)
    }

    /// SMPTE ST 2084.
    private func pqNits(_ code: UInt8) -> Double {
        let m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875
        let p = pow(Double(code) / 255, 1 / m2)
        return 10000 * pow(max(p - c1, 0) / (c2 - c3 * p), 1 / m1)
    }

    /// BT.2100 HLG with a system gamma of 1.2.
    private func hlgNits(_ code: UInt8) -> Double {
        let a = 0.17883277, b = 0.28466892, c = 0.55991073, e = Double(code) / 255
        let scene = e <= 0.5 ? e * e / 3 : (exp((e - c) / a) + b) / 12
        return 1000 * pow(scene, 1.2)
    }
}
