# 01 — Architecture

Goal: the smallest structure that keeps GPS maths testable and platform code replaceable.
No DI container, no BLoC/Riverpod, no code generation.

## Layering

```
        UI  (RunScreen, SummaryScreen, HistoryScreen)
             | listens to
   RunController  (ChangeNotifier)  <- app glue: permissions, lifecycle, persistence
             | feeds samples into
      RunTracker  (PURE DART - no plugins, no Flutter)   <- all metrics live here
             ^ samples
      LocationProvider (interface)
        |                    |
 GeolocatorProvider    SimulatedProvider   <- swappable, same contract
```

Rule that keeps the codebase honest: **`lib/domain/` may not import `package:flutter` or any
plugin.** It takes `LocationSample`s and `DateTime`s in, and emits `RunMetrics` out. That is
what makes distance/pace/pause testable with synthetic traces instead of a treadmill.

## Directory layout

```
lib/
  main.dart                     app entry, provider selection
  app.dart                      MaterialApp, theme, routes
  domain/
    models/
      location_sample.dart      lat, lon, accuracy, speed?, timestamp
      track_point.dart          accepted point + segment index
      run_metrics.dart          immutable live snapshot (distance/duration/paces/status)
      run_status.dart           enum: idle, active, paused, finished
      run_record.dart           finished run: id, startedAt, metrics, route
    geo.dart                    haversine, polyline simplification
    run_tracker.dart            THE engine: filter chain + accumulators + state machine
    tracker_config.dart         all thresholds in one place, injectable
    location_provider.dart      abstract: Stream<LocationSample> + permission contract
  data/
    geolocator_location_provider.dart
    simulated_location_provider.dart   replays a synthetic route for demo/tests
    run_repository.dart         JSON file in app documents dir (list of RunRecord)
    active_run_store.dart       crash-recovery snapshot of an in-progress run
  ui/
    run_controller.dart         ChangeNotifier: owns tracker + subscriptions + lifecycle
    screens/ run_screen.dart, summary_screen.dart, history_screen.dart
    widgets/ metric_tile.dart, primary_action_button.dart, gps_badge.dart,
             route_map.dart          shared: static (summary) + follow (live) modes
    format.dart                 distance/duration/pace formatting (pure, tested)
test/
    run_tracker_test.dart, geo_test.dart, format_test.dart, recovery_test.dart
```

## Why no state-management package

The app has exactly one piece of mutable state (the current run) with one owner. A
`ChangeNotifier` + `ListenableBuilder` covers it in ~10 lines and adds no build-time
dependency, no generated code and no rebuild-scope surprises. Adding Riverpod/BLoC here would
be architecture theatre on a five-screen app.

## Dependencies (deliberately small)

| Package | Why | Alternative rejected |
|---|---|---|
| `geolocator` | Position stream + permissions + Android foreground-service config in one plugin. | `location` — weaker permission API; `flutter_background_geolocation` — commercial, heavy. |
| `flutter_map` + `latlong2` | Raster OSM tiles, no API key, no Google Play Services, small runtime. Summary map + the opt-in live map. | `google_maps_flutter` — needs an API key a reviewer would have to provision, embeds a native map view, much heavier per screen. |
| `path_provider` | Documents dir for `runs.json` + recovery snapshot. | `shared_preferences` — wrong tool for a growing list of route points; `sqflite` — a table for ~10 rows is overkill. |
| `wakelock_plus` | Screen stays on during an active run. Tiny, and without it a "tracker" stops being usable. | none |

No `provider`, no `freezed`, no `json_serializable`. Models hand-write `toJson`/`fromJson`
(four small classes) rather than pulling in `build_runner`.

## Memory / battery posture

Explicit, because it was a stated constraint:

- Route points are ~40 bytes each; a 60-minute run at 1 Hz is ≈3600 points ≈150 KB. Kept in a
  plain `List`, no per-point widgets, no per-point objects beyond the point itself.
- The live map is **collapsed by default and unmounted while collapsed**. Tile decoding is the
  single biggest memory and battery cost in a running app, so it is opt-in per run, not the
  default state. Expanding it does not change any tracking behaviour — the map is a pure view
  over `RunTracker`'s route; collapsing it disposes the tile layer and frees the cache.
- The live map redraws at 1 Hz on new accepted points only, and follows the runner without
  animating the camera (no continuous interpolation loop).
- The polyline is simplified (Ramer–Douglas–Peucker, ~5 m epsilon) before rendering and before
  saving history, so the summary map draws ≲800 points regardless of run length.
- UI repaints on a 1 Hz ticker, and only the metric text rebuilds — not the whole screen.
- The crash-recovery snapshot is throttled (every ~5 s and on lifecycle change), not per fix.

## Platform configuration

- Android: `ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION`, `FOREGROUND_SERVICE`,
  `FOREGROUND_SERVICE_LOCATION`, `POST_NOTIFICATIONS`; geolocator `ForegroundNotificationConfig`
  so tracking survives a screen lock. Background-location ("Allow all the time") is **not**
  requested — a foreground service covers a run in progress and avoids the Play-policy path.
- iOS: `NSLocationWhenInUseUsageDescription`, `UIBackgroundModes: location`,
  `allowBackgroundLocationUpdates: true`, `pausesLocationUpdatesAutomatically: false`.
  Written from the geolocator docs; unverified without a Mac (stated in README).
