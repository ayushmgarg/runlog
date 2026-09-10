# 04 — Build Plan

Ordered so the risky part (metrics correctness) is provable before any UI exists, and so every
milestone leaves the app runnable.

| M | Deliverable | Done when |
|---|---|---|
| **M0** | Scaffold: `flutter create`, deps pinned, Android manifest permissions + foreground service, iOS plist, theme, empty routes. | `flutter run` shows an idle screen on the Pixel_9a emulator. |
| **M1** | `domain/`: models, `geo.dart`, `TrackerConfig`, `RunTracker` state machine + filter chain. **No UI.** | `flutter test` green on the 9-case matrix in [02](02-tracking-algorithm.md) §7. |
| **M2** | `LocationProvider` interface + `GeolocatorLocationProvider` + `SimulatedLocationProvider`; `RunController` wiring, permission flow. | Simulated route drives the tracker; real GPS drives it on the emulator via `adb emu geo fix`. |
| **M3** | S1 idle + S2 active screen (distance/duration/pace/speed), formatting, wakelock, status/GPS badges, finish confirmation. | Full start → pause → resume → finish loop works by hand. |
| **M4** | `RunRepository` (JSON), shared `RouteMap` widget, S3 summary route, S4 history, then the collapsed live-map strip on S2. | Finish a run, kill the app, reopen it from history with its route intact; live map draws the trail while running. |
| **M5** | Edge cases: crash recovery snapshot + restore banner, GPS-loss badge, permission-denied and services-off paths, backgrounding with the foreground notification. | Each row of [02](02-tracking-algorithm.md) §6 reproduced by hand or by test. |
| **M6** | Submission: README (setup, decisions, assumptions, limitations), release APK, demo GIF/notes on the simulated-GPS mode. | A reviewer with no Flutter setup can install the APK and test the whole flow. |

## Verification per milestone

- `flutter analyze` clean (`flutter_lints`, no ignores added to silence real warnings).
- `flutter test` green.
- Emulator smoke test: `adb emu geo fix <lon> <lat>` scripted into a short route.
- Simulated-GPS mode inside the app for reviewers who cannot script the emulator.

## Risk register

| Risk | Mitigation |
|---|---|
| Emulator GPS is coarse and jumpy; tuning filters against it misleads. | Tune against synthetic traces in unit tests; the emulator only proves plumbing. |
| Android 14+ foreground-service-type rules reject the service. | Declare `foregroundServiceType="location"` + `FOREGROUND_SERVICE_LOCATION` at M0, verified before M5. |
| OSM tiles need network; the live map could tempt scope creep toward navigation. | Tile failure degrades to a blank canvas with the route still drawn; the map is read-only, has no search/routing/nav, and is unmounted while collapsed. The run's numbers never depend on it. |
| Scope creep into spec §6. | The out-of-scope list is a checklist at review time; extras go in the README instead of the app. |

## Open decisions (defaults chosen, cheap to change)

1. Android-first; iOS config written but not build-verified (no macOS host).
2. Metric units only.
3. `flutter_map`/OSM over Google Maps — no API key for the reviewer to provision.
