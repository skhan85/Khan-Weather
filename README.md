# Khan Weather

A personal weather app for iPhone and iPad, built only on free data sources.

There is no Apple Watch app: free-Apple-ID sideloading tools (Impactor, Sideloadly) can't install watchOS apps, so it was removed in favour of a simpler install. It is in the git history if a paid developer account is ever used.

- **Forecasts:** [Open-Meteo](https://open-meteo.com) (global, hyperlocal where local models exist, no API key).
- **Alerts (coming in Phase 3):** Environment Canada, US National Weather Service, MeteoAlarm (Europe).

## What's here (Phase 1)

| Folder | What it is |
| --- | --- |
| `Packages/WeatherCore` | Swift package with the shared models and the Open-Meteo provider, plus unit tests |
| `App` | iPhone and iPad app (SwiftUI): current conditions, feels-like, next 24 hours, 10-day forecast |
| `Widget` | Home screen and lock screen widget |
| `Shared` | Location and view-model code used by the app and widget |
| `project.yml` | [XcodeGen](https://github.com/yonaskolb/XcodeGen) spec; the `.xcodeproj` is generated, not committed |

## Getting the .ipa (no Mac needed)

Every push to `main` and every pull request is built by GitHub Actions on a macOS runner.

1. Open the repo's [**Releases**](https://github.com/skhan85/Khan-Weather/releases/latest) page; every build of `main` publishes one, with the `.ipa` attached as a direct download.
2. Install it with a sideloading tool that signs with your Apple ID, such as Sideloadly or Impactor.

Pull request builds attach the `.ipa` as a zipped artifact on the Actions run instead.

With a free Apple ID the install expires after 7 days and must be refreshed.

## Dependable weather notifications (ntfy)

A sideloaded app on a free Apple ID can't receive real push notifications, and iOS rarely wakes it
in the background, so the app's own notifications are best effort. For dependable ones, a GitHub
Actions job (`.github/workflows/alert-push.yml`) runs the app's alert, rain and frost checks about
every 10 minutes and sends anything new to the free **ntfy** app:

1. Install **ntfy** from the App Store (it's a normal App Store app, so it doesn't count against
   the three-app sideloading limit).
2. In ntfy, tap **+** and subscribe to a long random topic name, e.g. `khanwx-` plus 16 random
   letters. Anyone who knows the name can read it, so don't share it outside the family.
3. In this repo, **Settings > Secrets and variables > Actions**, add a secret `NTFY_TOPIC` with that
   name. Optionally add a secret `PUSH_PLACES` like `Home=43.51,-79.88;Cottage=44.60,-79.42`
   (defaults to Milton); add `@other-topic` after a place to send it to a different family member.
4. Optional repository variables `PUSH_ADVISORIES`, `PUSH_RAIN`, `PUSH_FROST` set to `false` turn
   those off. If you use ntfy, turn the matching switches off in the app to avoid doubles.

GitHub pauses scheduled jobs after 60 days with no commits to the repo; re-enable it under Actions.

## Building on a Mac

```sh
brew install xcodegen
xcodegen generate
open KhanWeather.xcodeproj
```

Run the core tests with `swift test --package-path Packages/WeatherCore`.

## Data attribution

Weather data by [Open-Meteo.com](https://open-meteo.com), licensed under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). Free for non-commercial use.
