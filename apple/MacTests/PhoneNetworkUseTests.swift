import XCTest
@testable import OpenIPTV

final class PhoneNetworkUseTests: XCTestCase {
    private let newYork: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()

    private var suites: [String] = []

    override func tearDown() {
        for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
    }

    private func defaults() -> UserDefaults {
        suites.append("phone-network-\(UUID())")
        return UserDefaults(suiteName: suites.last!)!
    }

    private func store(_ defaults: UserDefaults? = nil) -> PhoneNetworkUse {
        PhoneNetworkUse(defaults: defaults ?? self.defaults(), calendar: newYork)
    }

    private func october(_ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        newYork.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute, second: second))!
    }

    func testWhatArrivesOverAPhoneNetworkIsCounted() {
        let use = store()
        use.noteArrived(4_000_000, over: .expensive, at: october(23, 20, 0))
        use.noteArrived(6_500_000, over: .expensive, at: october(23, 21, 0))
        use.noteArrived(9_000_000, over: .unmetered, at: october(23, 21, 30))
        use.noteArrived(9_000_000, over: .constrained, at: october(23, 21, 30))
        use.noteArrived(9_000_000, over: .unknown, at: october(23, 21, 30))
        XCTAssertEqual(use.usedToday(at: october(23, 22, 0)), 10_500_000)
    }

    func testTheCountStartsAgainAtLocalMidnight() {
        let use = store()
        use.noteArrived(10_000_000, over: .expensive, at: october(23, 19, 30))
        XCTAssertEqual(use.usedToday(at: october(23, 20, 30)), 10_000_000, "past midnight in UTC, not here")
        use.noteArrived(5_000_000, over: .expensive, at: october(23, 23, 59))
        XCTAssertEqual(use.usedToday(at: october(23, 23, 59, 59)), 15_000_000)
        XCTAssertEqual(use.usedToday(at: october(24, 0, 0)), 0)
        use.noteArrived(2_000_000, over: .expensive, at: october(24, 0, 1))
        XCTAssertEqual(use.usedToday(at: october(24, 0, 2)), 2_000_000)
    }

    func testTheCountIsKeptOnTheDevice() {
        let device = defaults()
        store(device).noteArrived(7_000_000, over: .expensive, at: october(23, 9, 0))
        XCTAssertEqual(store(device).usedToday(at: october(23, 10, 0)), 7_000_000)
        XCTAssertEqual(store(device).usedToday(at: october(24, 10, 0)), 0)
    }

    func testTheChoiceIsReadFromTheDeviceAndALaunchArgument() {
        let device = defaults()
        XCTAssertEqual(PhoneNetworkFilms.chosen(in: device), .daily, "the default for everyone")
        for (given, choice) in [("none", PhoneNetworkFilms.none), ("daily", .daily), ("wifi", .wifi), ("unheard of", .daily)] {
            device.set(given, forKey: "phoneNetworkFilms")
            XCTAssertEqual(PhoneNetworkFilms.chosen(in: device), choice, given)
        }
    }

    func testTheFooterSaysWhatWasUsedToday() {
        XCTAssertEqual(PhoneNetworkFilms.footer(usedToday: 0),
                       "Gets the start of the film you rest on ready, about 10 MB each, so it plays at once when you tap it. "
                       + "Used today: 0 MB. Low Data Mode turns this off.")
        XCTAssertTrue(PhoneNetworkFilms.footer(usedToday: 41_600_000).contains(" Used today: 42 MB. "))
        XCTAssertTrue(PhoneNetworkFilms.footer(usedToday: 150_000_000).contains(" Used today: 150 MB. "))
    }
}
