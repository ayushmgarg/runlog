# RUN — a basic running tracker

Start a run, watch distance / duration / pace / speed update while you move, pause and resume,
finish, and review the run with its route on a map.

Built with Flutter. No account, no backend, no network except map tiles — everything is
measured and stored on the device.

---

## Quick start

```bash
flutter pub get
flutter run           # phone connected over USB, or an emulator
```

Requires Flutter 3.35+ (Dart 3.9+) and, for Android, **JDK 17 or newer** — Android Gradle Plugin
8.x refuses to build on JDK 8. If Gradle picks the wrong one:

```bash
flutter config --jdk-dir "C:\Program Files\Android\Android Studio\jbr"
```

Build an installable APK:

```bash
flutter build apk --release
```

Run the tests (no device or GPS needed — see [Testing](#testing)):

```bash
flutter test
```

### Testing it without going outside

`lib/data/simulated_location_provider.dart` replays a scripted lap — running, a 20 s stop, a
35 s blackout — that exercises every awkward case indoors. It is deliberately **not wired into
the UI**, so field testing only ever exercises the real receiver; enabling it means constructing
it instead of `GeolocatorLocationProvider` in `RunController`.

On an emulator you can also push real fixes: `adb emu geo fix <lon> <lat>`.

---

## What it does

Everything the assignment asks for:

| Requirement | Where |
|---|---|
| Start Run | Idle screen, one primary button |
| GPS tracking | `geolocator` stream, Android foreground service so it survives a screen lock |
| Distance | Filtered and accumulated in `RunTracker` |
| Duration | Active time only, wall-clock based |
| Pace | Live (10 s rolling window) + average |
| Run status | Status pill, dimmed metrics when paused, button label |
| Pause / Resume | Freezes time and distance; re-anchors GPS on resume |
| Finish Run | Confirmation dialog, then the run is saved |
| Run summary | Distance, duration, average pace |
| Basic route | Polyline on OpenStreetMap tiles |

Three additions beyond that list:

- **Speed in km/h** next to pace. Same underlying measurement, in the unit most people read
  movement in.
- **An expandable live map** on the run screen — collapsed by default so the default screen is
  exactly the five elements the brief asks for, and unmounted while collapsed so it costs
  nothing until you ask for it.
- **A step-counter fallback**, so distance and pace survive losing GPS entirely — including
  starting a run without location at all.

Run history is kept on the device, because a finished run has to be openable again after the
summary is dismissed.

### Deliberately not built

Gamification, leaderboards, challenges, social, AI/voice coaching, advanced analytics, training
plans, heart rate, wearables, calories, elaborate animations, and any backend. The brief rules
these out and none of them ship in a reduced form either.

---

## How it works

```
        UI  (RunScreen, SummaryScreen, HistoryScreen)
             | listens to
   RunController  (ChangeNotifier)  <- permissions, lifecycle, persistence, timers
             | feeds samples into
      RunTracker  (PURE DART - no Flutter, no plugins)   <- all metrics live here
             ^ samples
      LocationProvider (interface)
        |                    |
 GeolocatorProvider    SimulatedProvider
```

The rule that holds the codebase together: **`lib/domain/` imports no Flutter and no plugins.**
It takes location samples and a clock function in, and produces metrics out. That is what makes
distance, pace and pause logic testable against synthetic GPS traces instead of a treadmill,
and it is why the filter chain could be tuned against evidence rather than guesswork.

There is no state-management package. The app has exactly one piece of mutable state with one
owner, which a `ChangeNotifier` covers in a few lines.

### Making GPS trustworthy

A naive tracker sums the distance between consecutive fixes and inflates badly — standing at a
traffic light adds "distance" because fixes scatter inside the accuracy radius. Every sample
runs a filter chain first:

| | rule | why |
|---|---|---|
| F1 | reject fixes worse than 25 m accuracy (50 m for the first fix) | worse than no data |
| F2 | reject duplicate / out-of-order fixes | the fused provider emits both |
| F3 | movement under `max(4 m, accuracy/2)` does not move the anchor | the standing-still fix |
| F4 | reject implied speeds over 12 m/s | GPS teleports |
| F4b | after 3 rejections in a row, treat it as a gap | otherwise the growing time delta eventually lets the same jump through as real distance |
| F5 | a gap over 30 s starts a new segment and adds no distance | never invent a shortcut across ground nobody covered |
| F6 | smooth accepted positions with an EMA before measuring | shrinks scatter ~2.4× before the anchor rule sees it |

F4b and F6 were both added because tests failed, not because they were designed in — the
reasoning is written up in [`docs/02-tracking-algorithm.md`](docs/02-tracking-algorithm.md).

### Surviving the loss of GPS

GPS is the measuring instrument; the hardware step counter is the fallback. While the signal is
good the pedometer contributes no distance at all — it only watches, pairing the steps it counts
with the metres GPS measured over the same interval to learn **this runner's stride**. The
moment the signal becomes unusable — indoors, a tunnel, location switched off — steps take over
and keep distance, pace and speed moving.

That matters because the alternative is a tracker that simply stops counting when you walk into
a building, which is not what a running watch does.

Being honest about it:

- A step-derived distance is an **estimate**, good to maybe 5–10 % once the stride has
  calibrated and worse before that (it starts from a 0.75 m population average and needs ~100
  steps of good GPS to learn better).
- The run screen says so: the badge changes to **STEPS** while the fallback is driving the
  numbers, because an estimate must not look like a measurement.
- The calibrated stride is clamped to 0.4–1.7 m, so GPS drift while standing still cannot teach
  it an absurd value.
- A step counter that resets mid-run (a reboot) is re-baselined rather than believed.
- Refusing the activity-recognition permission, or having no step sensor, costs the fallback and
  nothing else.

On the map, a stretch covered without GPS is drawn as a **dashed, dimmed connector** between the
two ends of the gap. A solid line would claim a path that was never recorded; no line at all
reads as a broken app. The dashes say "we got from here to there, but this part is not data" —
and the route polyline itself still only contains ground that was actually measured.

Other decisions worth knowing:

- **Duration is wall-clock accumulation, not tick counting.** A throttled timer or a
  backgrounded app cannot lose seconds, and a device clock that jumps backwards can stall the
  display but never rewind it.
- **Pause drops the GPS anchor**, so a bus ride during a pause adds nothing when you resume.
- **GPS loss does not auto-pause.** It shows `GPS WEAK` and blanks the live pace. Silently
  pausing a run is the behaviour runners hate most.
- **Unknown values render as `--:--`, never as `0`.** A fabricated zero pace reads as fact.
- The run is snapshotted to disk every 5 s and whenever the app leaves the foreground. On the
  next launch an unfinished run is offered back — **Resume**, **Save**, or **Discard** — and it
  comes back *paused*, because the time the process was dead was not running time.

### Dependencies (four, plus the framework)

| package | why | what was rejected |
|---|---|---|
| `geolocator` | position stream, permissions and the Android foreground service in one plugin | `location` (weaker permission API), commercial background-location plugins |
| `flutter_map` + `latlong2` | OSM raster tiles: no API key for a reviewer to provision, no Play Services | `google_maps_flutter` — needs a key, embeds a native map view |
| `path_provider` | documents directory for `runs.json` | `shared_preferences` (wrong shape for route points), `sqflite` (a schema for ~10 rows) |
| `wakelock_plus` | the screen must stay on during a run | — |

No `provider`, no `freezed`, no `build_runner`. The four model classes hand-write their JSON.

---

## Testing

`flutter test` — no device, no GPS, no waiting. A `FakeClock` and synthetic traces drive the
engine, and a fake `LocationProvider` plus an in-memory store drive the UI.

- `run_tracker_test.dart` — the filter chain and state machine: a measured kilometre, standing
  still, a teleport, a rejection cascade, a signal blackout, pausing, resuming, a backwards
  clock jump, crash recovery, and a run with no fixes at all.
- `geo_test.dart` — haversine against known distances, and route simplification that keeps real
  corners while never merging across a segment break.
- `format_test.dart` — the m/km switch, `MM:SS` vs `H:MM:SS`, the `--:--` placeholder, and NaN
  input.
- `run_repository_test.dart` — storage on a real directory: round-trips, newest-first ordering,
  deletion, atomic writes, and a corrupt file degrading to empty instead of crashing.
- `app_flow_test.dart` — the whole journey through the real widgets: start, metrics appear,
  pause, resume, the finish confirmation (including cancelling it), the summary, the map
  toggle, a denied permission, and the post-crash recovery banner.

Static analysis (`flutter analyze`, `flutter_lints`) is clean with no suppressions.

---

## Assumptions

- **Android is the primary target.** iOS configuration (`Info.plist` keys, background location
  mode, `AppleSettings`) is written from the plugin docs but has not been built or run — no
  macOS machine was available.
- **Metric units only** (km, min/km, km/h). No unit toggle; none was asked for.
- **Single user, offline, on-device.** No accounts, no sync, no backend.
- Android background location (`ACCESS_BACKGROUND_LOCATION`, "Allow all the time") is **not**
  requested. A foreground service covers a run in progress and is a much smaller ask of the
  user.

## Limitations and known issues

- **iOS is unverified.** See above.
- **Distance is quantised to ~4 m steps** by the jitter floor, and the EMA costs a few metres of
  lag at the start of each segment. Both under-report slightly rather than over-report, which is
  the safe direction; a measured kilometre lands within ~2 % in tests.
- **Under a dense tree canopy or between tall buildings** the accuracy gate rejects most fixes,
  so distance will under-report while the badge shows `GPS WEAK`. This is deliberate: the
  alternative is recording noise as running.
- **Map tiles need a network connection**, and there is no offline tile cache: with no data
  from the start, the map is an empty dark canvas with your route drawn on it — correct shape,
  correct scale, no streets. Nothing else about the run is affected. Tiles already fetched stay
  in memory for the session but are not written to disk, so they do not survive a restart.
- **A cold start with no data is slow to get its first fix.** Phones use the network to download
  satellite ephemeris (A-GPS); without it the first usable fix can take 30–60 s. The run is
  seeded from the device's cached position when that position is under a minute old, which
  covers the common case, but with nothing cached the opening stretch of distance can be missed.
  Duration starts immediately either way.
- **A pause longer than the OS is willing to keep the process alive** ends as a recovery prompt
  on the next launch rather than a still-running app. That is a platform constraint, and the
  snapshot exists precisely so nothing is lost.
- Route simplification (~5 m tolerance) is applied to the *saved* route, so a re-opened run's
  polyline has fewer vertices than the live one. Distance is stored as a number and is never
  re-derived from it.
- `android/gradle.properties` was lowered from the Flutter template's 8 GB heap to 1.5 GB: an
  8 GB machine cannot reserve 8 GB, and the JVM failure surfaces as a confusing Gradle error.
- The engine, geometry and formatting suites run green. The widget-flow suite
  (`app_flow_test.dart`) was written last and has not been run to completion on the development
  machine, where the Dart compiler runs out of memory part-way through; it is included because
  the coverage is worth having, but treat it as unverified until it runs on yours.

## Project layout

```
lib/
  domain/     the tracking engine and its models — pure Dart, no plugins
  data/       geolocator, the simulated provider, JSON storage
  ui/         controller, screens, widgets, formatting
test/         57 tests
docs/         design notes written before the code, updated where the code disagreed
```

`docs/` is worth a look if you want the reasoning rather than the result:
[requirements and scope](docs/00-requirements.md) ·
[architecture](docs/01-architecture.md) ·
[tracking algorithm](docs/02-tracking-algorithm.md) ·
[UI spec](docs/03-ui-spec.md) ·
[build plan](docs/04-plan.md)
