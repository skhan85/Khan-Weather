import XCTest
@testable import WeatherCore

final class AlertTextTests: XCTestCase {
    /// Fog advisory text as Environment Canada issued it for Halton Hills - Milton on 2026-11-21.
    static let fog = """
    Locally dense fog will dissipate later this morning.

    Travel will likely be hazardous in some locations.

    Be prepared for areas of near-zero visibility and allow extra time to reach your destination.

    Please continue to monitor alerts and forecasts issued by Environment Canada. To report severe weather, send an email to ONstorm@ec.gc.ca or post reports on social media using #ONStorm.
    """

    func testDropsStockLines() {
        let p = AlertText.paragraphs(Self.fog)
        XCTAssertEqual(p, [
            "Locally dense fog will dissipate later this morning.",
            "Travel will likely be hazardous in some locations.",
            "Be prepared for areas of near-zero visibility and allow extra time to reach your destination.",
        ])
        XCTAssertFalse(AlertText.summary(Self.fog).contains("ONstorm"))
        let alert = WeatherAlert(id: "1", title: "Fog advisory", kind: .advisory, risk: .yellow, text: Self.fog)
        XCTAssertTrue(alert.notificationBody.hasPrefix("Locally dense fog"))
        XCTAssertLessThanOrEqual(alert.notificationBody.count, 241)
    }

    func testJoinsHardWrappedLinesAndDropsDefinitions() {
        let raw = "Strong winds, with gusts up to\n90 km/h, are expected.\n\nWind warnings are issued when there is a significant risk of damaging winds.\n\n###"
        XCTAssertEqual(AlertText.paragraphs(raw), ["Strong winds, with gusts up to 90 km/h, are expected."])
    }

    func testKeepsTextWhenAllLooksLikeBoilerplate() {
        let raw = "Please continue to monitor alerts and forecasts issued by Environment Canada."
        XCTAssertEqual(AlertText.paragraphs(raw), [raw])
    }

    func testHeadline() {
        func alert(_ title: String, _ kind: WeatherAlert.Kind, _ risk: WeatherAlert.Risk) -> WeatherAlert {
            WeatherAlert(id: "1", title: title, kind: kind, risk: risk, text: "")
        }
        XCTAssertEqual(alert("Fog advisory", .advisory, .yellow).headline, "Yellow advisory - fog")
        XCTAssertEqual(alert("Severe thunderstorm warning", .warning, .orange).headline,
                       "Orange warning - severe thunderstorm")
        XCTAssertEqual(alert("Special weather statement", .statement, .yellow).headline, "Special weather statement")
        XCTAssertEqual(alert("Wind warning", .warning, .unknown).headline, "Wind warning")
    }
}
