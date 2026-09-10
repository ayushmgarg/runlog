# 00 — Requirements & Scope

Source: `PlexQo_RUN_Hiring_Assignment.docx`. This file is the single traceable list of what
must exist. Every row maps to a module in [01-architecture.md](01-architecture.md) and a
milestone in [04-plan.md](04-plan.md).

## In scope (required)

| # | Requirement | Acceptance criteria | Owner module |
|---|---|---|---|
| R1 | Start Run | One primary button on idle screen; tap requests permission if needed, acquires first fix, moves state `idle -> active`. | `RunController`, `RunScreen` |
| R2 | GPS / location tracking | Continuous position stream while active; route stored as ordered `TrackPoint`s. | `LocationProvider`, `RunTracker` |
| R3 | Distance | Total metres covered during active time, filtered for GPS noise (see [02](02-tracking-algorithm.md)). | `RunTracker` |
| R4 | Duration | Elapsed **active** time; excludes paused time; survives backgrounding. | `RunTracker` (wall-clock accumulation) |
| R5 | Pace | Current pace (rolling window) + average pace, `mm:ss /km`. | `RunTracker` |
| R6 | Run status | `active` / `paused` visible without reading anything else; plus GPS-signal state. | `RunScreen` |
| R7 | Pause / Resume | Pause freezes duration + distance; resume re-anchors GPS so paused movement is never counted. | `RunTracker` |
| R8 | Finish Run | Explicit finish action with confirmation; state `-> finished`, run persisted. | `RunController`, `RunRepository` |
| R9 | Run summary | Distance, duration, average pace after finish. | `SummaryScreen` |
| R10 | Basic route map | Polyline of the completed run on a map. | `RouteMap` (`flutter_map`) |

## Additions beyond the required list (justified)

Two, both small, both requested by the product owner. Neither touches the §6 out-of-scope list.

| # | Addition | Why it earns its place |
|---|---|---|
| A1 | Current **speed in km/h** next to pace | Pace (`min/km`) is the runner's unit but is unintuitive at a glance; km/h is how most people already read movement (the GPS-speedometer mental model). Same underlying calculation as pace, so it costs one derived getter and no extra state. |
| A2 | **Expandable live map** on the run screen | Collapsed by default so the screen still matches §4. A `Map` toggle expands an OSM map drawing the route as it happens. The map widget is only mounted while expanded, so the battery/memory cost is opt-in and the default path stays cheap. |

## Suggested RUN screen (spec §4)

Distance, Duration, Pace, Pause/Resume control, Finish control — all present, and they are what
the default (collapsed) screen shows, plus speed. The map stays collapsed until asked for, so
the §4 layout is what a user sees on start. See [03-ui-spec.md](03-ui-spec.md).

## Explicitly out of scope (spec §6)

Gamification / points / rewards, leaderboards, challenges, social, AI or voice coaching,
advanced analytics, training plans, heart rate, wearables, calories, complex animations,
backend beyond the local demo.

Treated as a hard boundary. No "small version" of any of these ships. Anything tempting gets
listed in the README's *deliberately not built* section instead.

## Evaluation criteria -> how this build answers them (spec §7)

| Criterion | How it is addressed |
|---|---|
| Functionality | Full state machine idle -> active -> paused -> finished -> summary, driven by a real position stream, plus a replayable simulated provider so a reviewer can test without going outside. |
| Accuracy | Explicit GPS filter chain (accuracy gate, jitter floor, speed sanity), wall-clock duration, windowed pace. Documented in [02](02-tracking-algorithm.md), covered by unit tests. |
| UX | Three-metric screen, one primary action at a time, unambiguous paused state, honest "GPS weak" indicator. |
| Code quality | Tracking engine is pure Dart with no plugin imports, so it is unit-testable; platform code sits behind one interface. No state-management framework, no layers that do not earn their place. |
| Edge cases | GPS loss, first-fix delay, permission denial, pause/resume anchoring, app kill mid-run, backgrounding, clock changes. Each has a defined behaviour in [02](02-tracking-algorithm.md) §6. |
| Product thinking | Scope held to the list above; map deferred to summary; simulated-GPS mode added because it makes the deliverable testable, not because it is a feature. |

## Assumptions

- Android is the primary target (emulator + physical device). iOS config is written but not
  build-verified — no macOS host available.
- Metric units only (km, min/km). No unit toggle; not requested.
- Single-user, fully offline, on-device storage. No accounts, no backend.
- Run history is kept locally because a finished run has to be re-openable after summary;
  it is storage, not a "feature".
