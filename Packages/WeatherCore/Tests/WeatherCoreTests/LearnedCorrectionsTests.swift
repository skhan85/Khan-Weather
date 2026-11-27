import XCTest
@testable import WeatherCore

/// The relay's per-place learning (GET /v1/learned): proven corrections only, applied the same way
/// on every screen, the widget and notifications.
final class LearnedCorrectionsTests: XCTestCase {
    static let json = #"""
    {"cell":"435,-799","updated":1795000000,"days":21,"status":"correcting",
     "temperature":{"enabled":true,"bias_3h":[0.2,1.0,1.2,0.8,0.1,0,-0.1,0],"measured_bias_3h":[0.2,1.0,1.2,0.8,0.1,0,-0.1,0],
                    "mae_raw":1.42,"mae_learned":1.12,"checked_pairs":2000,"checked_days":14,"truth":"5 Netatmo stations"},
     "rain":{"enabled":true,"pop_factor":0.8,"measured_pop_factor":0.8,"brier_raw":0.11,"brier_learned":0.1,
             "checked_pairs":900,"checked_days":14,"wet_hours":60,"hours_with_truth":480,"missed_light_share":0.2,
             "timing":null,"truth":"radar"}}
    """#

    func testProvenTemperatureCorrectionReplacesRelayDiurnalBias() throws {
        let spot = Coordinate(latitude: 12.34, longitude: 56.78)
        ModelBlend.setDiurnalBias([3, 3, 3, 3, 3, 3, 3, 3], for: spot)
        let learned = try JSONDecoder().decode(LearnedCorrections.self, from: Data(Self.json.utf8))
        ModelBlend.setLearned(learned, for: spot)
        let h0430 = 4.5 * 3600 + 86400 * 100
        XCTAssertEqual(ModelBlend.diurnalBias(at: h0430, leadHours: 24, coordinate: spot), 1.0, accuracy: 0.001)
        XCTAssertTrue(learned.summary.contains("21 days"))
        XCTAssertTrue(learned.summary.contains("1.4° → 1.1°"))

        // Not proven: the relay's own curve stays.
        var unproven = learned
        unproven.temperature?.enabled = false
        ModelBlend.setLearned(unproven, for: spot)
        XCTAssertEqual(ModelBlend.diurnalBias(at: h0430, leadHours: 24, coordinate: spot), 3, accuracy: 0.001)
    }

    func testProvenRainFactorScalesChancesEverywhere() throws {
        let spot = Coordinate(latitude: -23.45, longitude: 67.89)
        let now = Date()
        let current = CurrentConditions(time: now, temperature: 10, feelsLike: 10, feelsLikeKind: .apparent,
                                        humidity: 70, condition: .overcast, isDay: true)
        var f = Forecast(location: spot, timeZoneIdentifier: "UTC", current: current, hourly: [], daily: [],
                         source: "t", fetchedAt: now)
        f.hourly = [HourlyForecast(time: now, temperature: 10, precipitationProbability: 50, condition: .overcast)]
        XCTAssertEqual(f.calibratingEnsemblePop().hourly[0].precipitationProbability, 50)

        let learned = try JSONDecoder().decode(LearnedCorrections.self, from: Data(Self.json.utf8))
        ModelBlend.setLearned(learned, for: spot)
        XCTAssertEqual(f.calibratingEnsemblePop().hourly[0].precipitationProbability, 40)

        var off = learned
        off.rain?.enabled = false
        ModelBlend.setLearned(off, for: spot)
        XCTAssertEqual(f.calibratingEnsemblePop().hourly[0].precipitationProbability, 50)
    }

    func testStillLearningSaysSo() throws {
        let fresh = try JSONDecoder().decode(LearnedCorrections.self, from: Data(#"""
        {"cell":"1,1","status":"learning","temperature":{"enabled":false},"rain":{"enabled":false},"days":3}
        """#.utf8))
        XCTAssertEqual(fresh.summary, "Learning this place: 3 of 10 days so far. Nothing is corrected until it proves itself.")
        XCTAssertNil(fresh.temperature?.provenBins)
    }
}
