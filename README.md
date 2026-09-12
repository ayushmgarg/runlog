<img src="assets/icon/icon.png" width="72" alt="RunLog" align="left" hspace="12" vspace="4">

# RunLog

A running tracker built with Flutter. Start a run, watch distance, duration, pace and speed
update as you move, pause and resume, finish, and review the run with its route on a map.

Everything is measured and stored on the device. No account, no backend, no network except map
tiles.

<br clear="left">

---

## Setup

Requires Flutter 3.35+ (Dart 3.9+). For Android you need **JDK 17 or newer** — Android Gradle
Plugin 8.x will not build on JDK 8.

```bash
flutter pub get
flutter run
```

If Gradle picks up the wrong JDK:

```bash
flutter config --jdk-dir "<path to a JDK 17+>"
```

Build an installable APK:

```bash
flutter build apk --release
```

Run the tests — no device, no GPS, no waiting:

```bash
flutter test
```

A prebuilt APK is attached to the [releases](../../releases).

---

## What it does

| | |
|---|---|
| **Start / Finish** | One primary button; finishing asks for confirmation |
| **Distance** | GPS, filtered (see below) |
| **Duration** | Active time only — pauses are excluded |
| **Pace & speed** | Live over a 10 s window, plus the average |
| **Pause / Resume** | Freezes time and distance, and re-anchors GPS on resume |
| **Route** | Drawn live (optional) and on the summary, on OpenStreetMap tiles |
| **History** | Finished runs are kept on the device |

Two things beyond the basics: **speed in km/h** alongside pace, and a **step-counter fallback**
so a run keeps measuring when GPS is unavailable — including starting a run with no location at
all.

---

## Implementation

```
lib/
  domain/   tracking engine and models — no Flutter, no plugins
  data/     GPS, pedometer, JSON storage
  ui/       one controller, screens, widgets
```

The rule the codebase is built around: **`lib/domain/` imports neither Flutter nor any plugin.**
It takes location samples and a clock function in, and produces metrics out. That is what lets
distance, pace and pause behaviour be tested against synthetic GPS traces instead of by going
for a run, and it is why the filter thresholds could be tuned against evidence.

There is no state-management package. The app has one piece of mutable state with one owner,
which a `ChangeNotifier` covers in a few lines.

### Making GPS trustworthy

Summing the distance between consecutive fixes inflates badly — standing at a traffic light adds
"distance" because fixes scatter inside the accuracy radius. Every sample passes a filter chain
first:

- fixes worse than 25 m accuracy are rejected (50 m for the first fix of a run)
- duplicate and out-of-order fixes are rejected
- accepted positions are smoothed with an EMA before anything is measured
- movement below `max(4 m, accuracy / 2)` does not move the distance anchor — this is what stops
  standing still from accumulating metres
- implied speeds above 12 m/s are rejected as GPS jumps; three in a row is treated as a gap
- a blackout longer than 30 s starts a new route segment and credits no distance

Other decisions worth knowing:

- **Duration accumulates from the wall clock**, not counted ticks, so a throttled timer or a
  backgrounded app cannot lose seconds.
- **Pausing drops the GPS anchor**, so travelling during a pause is never counted on resume.
- **Losing GPS does not auto-pause.** The run continues, on steps if they are available, and the
  screen says which.
- **Unknown values render as `--:--`, never `0`.** A fabricated zero pace reads as fact.
- The run is snapshotted every 5 s and whenever the app is backgrounded. An unfinished run is
  offered back after a crash as Resume / Save / Discard, and returns *paused* — the time the
  process was dead is not running time.

### Without GPS

GPS is the instrument; the hardware step counter is the fallback. While the signal is good,
steps add no distance at all — they only measure your stride against the metres GPS reports over
the same interval. When the signal goes, that stride converts steps into distance and the run
carries on. The badge changes to **STEPS**, so an estimate never looks like a measurement.

On the map, ground covered without GPS is drawn as a dashed connector rather than a solid line.

### Dependencies

`geolocator`, `flutter_map` + `latlong2`, `pedometer`, `permission_handler`, `path_provider`,
`wakelock_plus`. No code generation. OpenStreetMap rather than Google Maps, so there is no API
key to provision.

### Tests

`flutter test` — the filter chain and state machine against synthetic traces on an injected
clock, route geometry, display formatting, storage on a real directory, and the full
start / pause / resume / finish journey through the real widgets.

---

## Assumptions

- Android is the target. iOS is configured but has never been built or run — no macOS machine
  was available.
- Metric units only (km, min/km, km/h).
- Single user, offline, on-device. No accounts, no sync.
- Background location ("Allow all the time") is deliberately not requested. A foreground service
  covers a run in progress.

## Limitations and known issues

- **iOS is unverified.** See above.
- **Distance is quantised to ~4 m steps** by the jitter floor, and smoothing costs a few metres
  at the start of each segment. Both under-report rather than over-report; a measured kilometre
  lands within about 2 % in tests.
- **Under dense tree cover or between tall buildings** most fixes fail the accuracy gate, so
  distance under-reports while the badge shows `GPS WEAK`. This is deliberate — the alternative
  is recording noise as running.
- **Step-derived distance is an estimate**, roughly 5–10 % once the stride has calibrated and
  worse before that. It needs about 100 steps of good GPS to learn your stride, and starts from
  a 0.75 m average.
- **Map tiles need a network and are not cached offline.** Without one the route still draws on
  a blank canvas, and a retry button appears once connectivity returns. No measurement depends
  on the map.
- **A cold first fix can take 30–60 s without mobile data**, since the phone cannot download
  A-GPS data. The run is seeded from the device's cached position when that is under a minute
  old, which covers most starts.
- The saved route is simplified (~5 m tolerance), so a re-opened run has fewer vertices than the
  live one. Distance is stored as a number and never re-derived from it.

## Icon

`tool/generate_icon.py` draws the launcher icon from the app's palette;
`dart run flutter_launcher_icons` expands it into every density.
