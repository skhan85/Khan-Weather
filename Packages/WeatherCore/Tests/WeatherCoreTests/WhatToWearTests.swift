import XCTest
@testable import WeatherCore

final class WhatToWearTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_794_000_000)

    func current(_ feels: Double) -> CurrentConditions {
        CurrentConditions(time: now, temperature: feels + 3, feelsLike: feels, feelsLikeKind: .windChill,
                          condition: .overcast, isDay: true)
    }

    func hour(_ offset: Int, feels: Double, chance: Double = 0, condition: WeatherCondition = .overcast) -> HourlyForecast {
        HourlyForecast(time: now.addingTimeInterval(Double(offset) * 3600), temperature: feels + 3, feelsLike: feels,
                       precipitationProbability: chance, condition: condition)
    }

    func testColdWithRainLater() {
        let hours = [hour(1, feels: 2), hour(2, feels: 1), hour(3, feels: 1, chance: 60, condition: .rain)]
        let tip = WhatToWear.tip(current: current(2), upcoming: hours, hourText: { _ in "1 PM" })
        XCTAssertEqual(tip, "Warm jacket, and an umbrella from 1 PM.")
    }

    func testMildDryDay() {
        let tip = WhatToWear.tip(current: current(18), upcoming: [hour(1, feels: 20)], hourText: { _ in "" })
        XCTAssertEqual(tip, "T-shirt weather.")
    }

    func testBigWarmUp() {
        let tip = WhatToWear.tip(current: current(4), upcoming: [hour(4, feels: 16)], hourText: { _ in "" })
        XCTAssertEqual(tip, "Jacket you can shed later.")
    }
}
