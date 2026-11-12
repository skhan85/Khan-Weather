# Khan Weather

A personal weather app for iPhone, iPad and Apple Watch, built only on free data sources.

- **Forecasts:** [Open-Meteo](https://open-meteo.com) (global, hyperlocal where local models exist, no API key).
- **Alerts (coming in Phase 3):** Environment Canada, US National Weather Service, MeteoAlarm (Europe).

## What's here (Phase 1)

| Folder | What it is |
| --- | --- |
| `Packages/WeatherCore` | Swift package with the shared models and the Open-Meteo provider, plus unit tests |
| `App` | iPhone and iPad app (SwiftUI): current conditions, feels-like, next 24 hours, 10-day forecast |
| `Widget` | Home screen and lock screen widget |
| `Watch` | Apple Watch app |
| `Shared` | Location and view-model code used by the app and Watch app |
| `project.yml` | [XcodeGen](https://github.com/yonaskolb/XcodeGen) spec; the `.xcodeproj` is generated, not committed |

## Getting the .ipa (no Mac needed)

Every push to `main` and every pull request is built by GitHub Actions on a macOS runner.

1. Open the repo's **Actions** tab and pick the latest green **Build unsigned IPA** run.
2. Download the **KhanWeather-unsigned-ipa** artifact and unzip it to get `KhanWeather-unsigned.ipa`.
3. Install it with a sideloading tool that signs with your Apple ID, such as Sideloadly or Impactor.

With a free Apple ID the install expires after 7 days and must be refreshed.

## Building on a Mac

```sh
brew install xcodegen
xcodegen generate
open KhanWeather.xcodeproj
```

Run the core tests with `swift test --package-path Packages/WeatherCore`.

## Data attribution

Weather data by [Open-Meteo.com](https://open-meteo.com), licensed under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). Free for non-commercial use.
