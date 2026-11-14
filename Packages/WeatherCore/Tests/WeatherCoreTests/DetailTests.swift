import XCTest
@testable import WeatherCore

final class DetailTests: XCTestCase {
    func testPrecipitationKind() {
        XCTAssertEqual(PrecipitationKind.guess(rain: 0, snow: 0.4, condition: .overcast, low: -2, high: 1), .snow)
        XCTAssertEqual(PrecipitationKind.guess(rain: 1, snow: 0.4, condition: .overcast, low: -2, high: 3), .mixed)
        XCTAssertEqual(PrecipitationKind.guess(rain: nil, snow: nil, condition: .rain, low: 5, high: 9), .rain)
        // No amounts, cloudy: go by temperature.
        XCTAssertEqual(PrecipitationKind.guess(rain: 0, snow: 0, condition: .overcast, low: -5, high: 0), .snow)
        XCTAssertEqual(PrecipitationKind.guess(rain: 0, snow: 0, condition: .overcast, low: 4, high: 12), .rain)
        XCTAssertEqual(PrecipitationKind.guess(rain: 0, snow: 0, condition: .overcast, low: -1, high: 7), .mixed)
    }

    func testFirstHourShowsCurrentConditions() {
        let now = Date(timeIntervalSince1970: 1_762_956_000)
        var hour = HourlyForecast(time: now.addingTimeInterval(-1800), temperature: 4, feelsLike: 0,
                                  condition: .partlyCloudy, isDay: true)
        hour.windSpeed = 15
        hour.windGusts = 32
        let current = CurrentConditions(time: now, temperature: 5, feelsLike: 2, feelsLikeKind: .windChill,
                                        windSpeed: 8, condition: .overcast, isDay: true)
        let forecast = Forecast(location: .fallback, timeZoneIdentifier: "America/Toronto", current: current,
                                hourly: [hour, HourlyForecast(time: now.addingTimeInterval(1800), temperature: 4,
                                                              condition: .overcast, isDay: true)],
                                daily: [], source: "test", fetchedAt: now)
        let hours = forecast.hoursStartingNow(from: now, count: 2)
        XCTAssertEqual(hours[0].temperature, 5)
        XCTAssertEqual(hours[0].feelsLike, 2)
        XCTAssertEqual(hours[0].windSpeed, 8)
        XCTAssertEqual(hours[0].windGusts, 32, "keeps the forecast gusts when there's no current value")
        XCTAssertEqual(hours[0].condition, .overcast)
        XCTAssertEqual(hours[1].temperature, 4)
    }

    func testCompassAndUV() {
        XCTAssertEqual(WeatherFormat.compass(0), "N")
        XCTAssertEqual(WeatherFormat.compass(24), "NE")
        XCTAssertEqual(WeatherFormat.compass(350), "N")
        XCTAssertEqual(WeatherFormat.compass(-90), "W")
        XCTAssertEqual(WeatherFormat.uvLevel(6.4), "6 High")
    }

    func testParsesDetailFieldsAndHoursOfDay() throws {
        let json = """
        {"latitude": 43.5, "longitude": -79.9, "timezone": "America/Toronto",
         "current": {"time": 1762956000, "temperature_2m": 1.0, "weather_code": 3},
         "hourly": {"time": [1762952400, 1762995600], "temperature_2m": [1.0, 3.0],
                    "relative_humidity_2m": [80, 70], "wind_speed_10m": [12, 20], "wind_gusts_10m": [25, 40],
                    "wind_direction_10m": [270, 300], "uv_index": [0, 1.5], "rain": [0, 0.2], "showers": [0, 0.1],
                    "snowfall": [0.3, 0], "visibility": [24000, 10000], "weather_code": [71, 61]},
         "daily": {"time": [1762923600], "weather_code": [3], "temperature_2m_max": [4], "temperature_2m_min": [-1],
                   "sunrise": [1762949000], "sunset": [1762984500], "uv_index_max": [1.6],
                   "wind_speed_10m_max": [22], "wind_gusts_10m_max": [45], "wind_direction_10m_dominant": [285],
                   "precipitation_hours": [3]}}
        """.data(using: .utf8)!
        let f = try OpenMeteoProvider.parse(json, fetchedAt: Date())
        let h = try XCTUnwrap(f.hourly.last)
        XCTAssertEqual(h.windGusts, 40)
        XCTAssertEqual(try XCTUnwrap(h.rain), 0.3, accuracy: 0.001)
        XCTAssertEqual(f.hourly.first?.precipitationKind, .snow)
        let d = try XCTUnwrap(f.daily.first)
        XCTAssertEqual(d.sunrise, Date(timeIntervalSince1970: 1762949000))
        XCTAssertEqual(d.windGustsMax, 45)
        // 1762923600 is local midnight on 2025-11-12 in Toronto; both hours fall on that date.
        XCTAssertEqual(f.hours(on: d).count, 2)
    }
}
