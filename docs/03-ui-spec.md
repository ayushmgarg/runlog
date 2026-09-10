# 03 — UI Spec

Three screens. Dark theme (a running screen is read outdoors and at night; dark also costs less
on OLED). Big numerals, one primary action visible at a time.

## S1 — Idle / Start

- App bar: `RUN`, plus a history icon.
- Centre: large circular **START RUN** button.
- Under it: GPS-readiness line — `Acquiring GPS…` / `GPS ready` / `Location permission needed`.
- If an unfinished run was recovered, a banner appears above the button:
  `Unfinished run — 2.31 km, 14:08` with actions **Resume** / **Save** / **Discard**.

## S2 — Active run

Default (map collapsed) — this is what §4 asks for, nothing more:

```
 [ RUNNING ]  (green pill)                        [ ● GPS ]
 ------------------------------------------------------------
                       2.34
                        KM                      <- hero metric
 ------------------------------------------------------------
   00:14:08         5:42 /km          10.5
   DURATION           PACE            KM/H
                    avg 6:01                    <- small, under pace
 ------------------------------------------------------------
                 [  ▾  Map  ]                   <- collapsed strip, one tap
 ------------------------------------------------------------
            [  PAUSE  ]            [ FINISH ]
```

Expanded (map open): the map takes the space between the metric row and the controls; hero
distance and the metric row shrink one step but stay visible. Metrics never leave the screen —
the map is additive, not a mode.

- Distance is the hero: largest type on screen, glanceable at arm's length while moving.
- Speed (km/h) and pace are the same measurement in two units, from one rolling window, so they
  cannot contradict each other.
- Status is carried by three redundant channels — pill text, pill colour, and the button
  swapping to **RESUME** — so it is never ambiguous. Colour alone is not the signal.
- Paused state additionally dims the metric block, so a glance from a distance reads as paused.
- **PAUSE/RESUME** is the primary control (large, left). **FINISH** is secondary and requires
  confirmation ("Finish run? 2.34 km · 14:08" → Finish / Keep running); an accidental finish is
  unrecoverable, an accidental pause is not.
- GPS badge: `● GPS` good / `◐ GPS weak` / `○ Acquiring` — with a tooltip explaining that
  distance may under-report while weak.
- **Live map** (`flutter_map`, OSM): collapsed by default, remembered per app session, never
  mounted while collapsed. Open: route polyline drawn as it happens, camera follows the runner
  (recentre button appears if the user pans away), auto-zoom off — no camera animation loop.
  Tiles need network; offline shows the plain route on a blank canvas rather than an error.
- Screen stays awake (`wakelock_plus`) while active; released on pause and finish.
- Back / system-back during an active run does not exit — it asks.

## S3 — Summary

- Header: date + start time, e.g. `Thu 11 Sep · 07:12`.
- Three stat tiles: **Distance**, **Duration**, **Average pace** (+ average km/h as the tile's
  secondary line).
- Route map (`flutter_map`, OSM tiles) fitted to the route bounds, start marker green, end
  marker red, per-segment polylines so gaps show as breaks. If no route: an empty state card
  reading `No route recorded — GPS was unavailable`.
- Actions: **Done** (back to idle) and **Delete run**.

## S4 — History (small, secondary)

Reverse-chronological list of saved runs (date, distance, duration, pace). Tap → S3. Exists
because a finished run must be re-openable; not advertised as a feature.

## Formatting rules (`ui/format.dart`, unit-tested)

| Value | Rule |
|---|---|
| Distance | `< 1000 m` → `843 m`; else `2.34 km` (2 dp) |
| Duration | `< 1 h` → `MM:SS`; else `H:MM:SS` |
| Pace | `M:SS /km`; `--:--` when undefined or stale; clamp above `99:59` |
| Speed | `10.5 km/h` (1 dp); `--` when undefined or stale |

## Accessibility

- Metric tiles carry semantic labels (`Distance, 2.34 kilometres`) — the numeral alone is
  meaningless to a screen reader.
- Controls are ≥56 dp tall; they are pressed while moving and out of breath.
- Text scales with system font size; the hero numeral has a floor so it never collapses.
- Status never relies on colour alone (see S2).
