# 02 — Tracking Algorithm

Everything here lives in `lib/domain/run_tracker.dart` + `geo.dart` and is exercised by
`test/run_tracker_test.dart` with synthetic traces. Thresholds live in `TrackerConfig` so they
are tunable and injectable from tests.

## 1. Input

```dart
class LocationSample {
  final double latitude, longitude;
  final double accuracy;      // metres, 68% confidence radius
  final double? speed;        // m/s from the GPS chip, may be null/garbage
  final DateTime timestamp;   // device time of the fix
}
```

The tracker is fed samples and 1 Hz UI ticks. It never calls `DateTime.now()` implicitly —
a `Clock` function is injected, so tests control time exactly.

## 2. Filter chain (why raw GPS cannot be trusted)

A naive `sum(haversine(p[i-1], p[i]))` inflates distance badly: standing still at a traffic
light adds "distance" because consecutive fixes scatter within the accuracy radius. Each
sample runs this gate, in order:

| # | Gate | Rule | Rationale |
|---|---|---|---|
| F1 | Accuracy | reject if `accuracy > 25 m` (first fix: `> 50 m`) | Urban-canyon and cell-tower fixes are worse than no fix. First fix is looser so a run can start indoors-ish. |
| F2 | Monotonic time | reject if `dt <= 0` | Duplicate/out-of-order fixes from the fused provider. |
| F3 | Jitter floor | if `d < max(4 m, 0.5 * accuracy)` → **do not add distance, do not move the anchor** | This is the standing-still fix. The anchor only advances on real movement, so noise cannot accumulate. |
| F4 | Speed sanity | reject if `d / dt > 12 m/s` (~43 km/h) | GPS teleport / provider switch. A human runner never trips this. |
| F4b | Rejection cascade | after **3** consecutive F4 rejections, re-anchor into a new segment and add no distance | Found by a test, not by design. Each rejection leaves the last good fix further in the past, so the *same* jump is divided by a larger `dt` and eventually squeaks under the 12 m/s limit as hundreds of false metres. A sustained teleport is a discontinuity, so it is treated as one. |
| F5 | Gap bridging | if `dt > 30 s`, accept the point as a **new segment anchor** and add no distance | After a tunnel/signal loss the straight line between endpoints is a lie; better to under-report than to invent a shortcut. Also breaks the drawn polyline. |
| F6 | Smoothing | accepted positions pass through an EMA, `alpha = 0.3`, before distance is measured | See below. |

`dt` for F4/F4b/F5 is measured from the last **fix** (any sample that passed F1/F2),
never from the anchor — the anchor can be minutes old if the runner has been standing still,
which would defeat both checks.

### F6 — why smoothing came back

The first draft of this document rejected EMA smoothing as unnecessary lag. The stationary-noise
test disproved that: with the anchor rule alone, 60 fixes of pure scatter (σ ≈ 2 m) still
produced **88 m** of invented distance out of a 188 m naive total — barely half the noise
removed. The failure mode is a random walk: a noise point far enough from the anchor moves the
anchor, and the walk repeats from there.

An EMA shrinks the scatter by `sqrt(alpha / (2 - alpha))` ≈ 0.42 *before* the anchor rule sees
it, which drops the same trace to a few metres. Cost is a constant lag of `(1 - alpha) / alpha`
≈ 2.3 fixes at the start of each segment — about 7 m at running pace, once per segment, always
in the under-reporting direction. That trade is worth it; the ~1 % it costs on a measured
kilometre is visible in the test's tolerance.

Accepted points append to the route with a `segmentIndex`; the polyline is drawn per segment so
gaps and pauses render as breaks rather than as false straight lines. Points store the smoothed
position, so the drawn route is the same line the distance was measured along.

Deliberately **not** done: a full Kalman filter. It would model velocity and adapt its gain to
the reported accuracy, which is strictly better — and it is a tuning project of its own. EMA plus
the anchor rule reaches ~0 invented metres on the stationary test, which is the bar that matters
here.

## 3. Distance

`geo.dart` implements haversine on the WGS-84 mean radius (6 371 008.8 m). Accumulated as a
running `double` over accepted anchor hops — never recomputed from the whole list, so cost is
O(1) per fix.

## 4. Duration

Wall-clock accumulation, not tick counting:

```
activeElapsed = completedSegments + (status == active ? now - segmentStartedAt : 0)
```

- Tick counting drifts and dies when the app is backgrounded or the timer is throttled.
- Pause writes the current segment into `completedSegments` and clears `segmentStartedAt`;
  resume sets a fresh `segmentStartedAt`. Paused wall time is therefore never counted.
- The 1 Hz ticker exists only to trigger a repaint. If it misses beats, the displayed number is
  still correct.
- A backwards device-clock jump (NTP correction) is clamped to a non-negative delta rather than
  rewinding the run.

## 5. Pace

- **Average pace** = `activeElapsed / distance`, shown as `mm:ss /km`. Suppressed to `--:--`
  until distance ≥ 50 m, because pace over 3 m of GPS noise is a random number.
- **Current pace** = rolling window over the last **10 s**, requiring at least **5 s** of data.
  Originally 30 s, changed after field testing: a 10 s sprint averaged against the jogging before
  it read as 8 km/h, and slowing to a walk took most of a minute to show on screen. 10 s reacts
  within a few seconds and is still long enough that a single noisy fix cannot swing it.
  The window *ends at now*, not at the last recorded point, so when the runner stops the reading
  decays toward zero on its own instead of freezing at the last running speed. It is also
  **restricted to the current segment**, so resuming after a pause reports the pace just set,
  not the one the runner had when they stopped — a field-reported bug, now covered by a test. A distance
  threshold on the window is unnecessary: F3/F6 mean noise never enters the accumulated distance
  in the first place. The chip's own `speed` field is ignored — it is inconsistent across devices
  and unavailable in mocks.
- Below **0.5 m/s** (33 min/km) pace reports as unknown rather than as a number: the runner has
  stopped, and `119:00 /km` is arithmetically true and useless.
- If no *fix* arrived in the last 10 s, live pace and speed show a placeholder rather than a
  stale number, and the GPS badge goes to `weak`. Showing a frozen pace is worse than showing
  none.
- Live screen shows current pace with average underneath; the summary shows average only
  (that is what spec §5 asks for).

## 5b. Speed (km/h)

Same rolling window as current pace, expressed the other way round: `speed_kmh = 3.6 * m/s`.
Pace and speed are two views of one number, so they can never disagree on screen. Blanked
(`--`) under the same staleness rule as pace. The GPS chip's own `speed` field stays unused for
the same reason given above.

## 5c. The step-counter fallback

GPS is the instrument; the hardware pedometer is the fallback. The rule is strict: **while GPS
is good, steps contribute no distance whatsoever.** They only calibrate.

| state | what steps do |
|---|---|
| GPS good | nothing to distance; the steps counted are paired with the metres GPS measured over the same interval, and the ratio is this runner's stride |
| GPS weak / absent, steps arriving | `distance += steps x stride`, and pace/speed come from the distance timeline as usual |
| GPS weak, no steps arriving | nothing — distance holds, live pace blanks |
| paused | ignored entirely, like position fixes |

Design notes:

- **Distance and speed read off a shared timeline**, not off the route, precisely so that a
  source with no coordinates can still move them. Each entry is (time, cumulative metres,
  segment); the list is pruned to a few pace-windows, so it is O(window) however long the run.
- **Calibration pairs matched intervals.** Only the GPS distance covered *between two step
  readings* may be divided by the steps between them. Dividing the whole run's distance by a
  handful of steps would produce a metres-per-step stride.
- **The result is clamped to 0.4–1.7 m.** GPS drift while standing at a light would otherwise
  teach the tracker a stride that wrecks the fallback later.
- **100 steps of good GPS** are required before the measured stride is trusted over the 0.75 m
  default.
- **A counter that goes backwards is re-baselined**, not treated as a delta: that is a device
  reboot, and the alternative is either a negative distance or a 50,000-step jump.
- The step counter reports totals since boot, so the engine only ever takes differences and
  never has to care where counting began.

Accuracy expectation: roughly 5–10 % once calibrated, worse before. That is materially worse
than GPS, which is why the run screen switches the badge to **STEPS** while the fallback is
driving the numbers. An estimate presented as a measurement is the thing to avoid.

## 6. Edge cases and defined behaviour

| Situation | Behaviour |
|---|---|
| Permission denied | Start button explains what is blocked and offers "Open settings"; no fake run. `deniedForever` gets a distinct message. |
| Location services off | Prompt to enable; polls service status and recovers when re-enabled. |
| No first fix yet | Run starts in `active` with an "Acquiring GPS…" badge; duration runs, distance stays 0 until the first accepted fix. Time should not be lost while the antenna warms up. |
| GPS lost mid-run | After 10 s with no accepted fix: `weak` badge. If the step counter is available the run keeps measuring from steps and the badge reads `STEPS`; otherwise live pace blanks and distance holds. Duration continues either way. **No auto-pause** — silently pausing a run is the behaviour runners hate most. |
| Location switched off entirely | Same path as a blackout: steps carry the run. With no step sensor or no permission, duration still runs and distance stays put. |
| Signal returns after >30 s | New segment (F5): the route polyline breaks, and the two ends are joined on the map by a dashed, dimmed connector. No GPS distance is credited across it; if steps were available, that stretch was already counted from them. |
| Pause | Anchor dropped. Distance and duration frozen. Position stream is unsubscribed while paused (battery), re-subscribed on resume. |
| Resume | First accepted fix becomes the new anchor and starts a new segment, so movement during the pause is never counted. |
| App backgrounded | Android foreground service keeps the stream alive with a persistent notification. Duration is wall-clock, so even a killed stream cannot corrupt it. |
| App killed / crash | `active_run_store.dart` snapshots the run every ~5 s and on lifecycle change. On next launch: "You have an unfinished run — Resume / Finish and save / Discard". |
| Finish with zero distance | Allowed, summary shows 0.00 km and `--:--` pace, map area shows "No route recorded". No crash path. |
| Very long run | Points are simplified before persisting; the accumulator is O(1), so a 3-hour run costs the same per fix as a 5-minute one. |

## 7. Test matrix (`test/`)

Synthetic traces, no device needed:

`flutter test` — 47 cases, no device, no waiting.

**`run_tracker_test.dart` (24)**

1. Straight 1 km at 3 m/s → distance within ~2 %.
2. 3 m hops under the 4 m floor still accumulate — quantisation must not lose distance.
3. Stationary scatter, 60 fixes → under 10 % of the naive sum. *(the F3/F6 regression test)*
4. F1: a 40 m fix anchors but cannot extend; an 80 m fix cannot even anchor.
5. F2: an out-of-order replay is rejected.
6. F4: one 300 m/s outlier is rejected, the run continues in the same segment.
7. F4b: a sustained teleport is rejected twice, then becomes a gap — no false distance.
8. F5: a 45 s blackout adds no distance and increments the segment count.
9. Pause 60 s → duration excludes exactly those 60 s.
10. Drive 500 m while paused → resume adds none of it; segment count is 2.
11. Samples arriving while paused are ignored outright.
12. Live speed matches the rolling window, and pace/speed/km-h never disagree.
13. Stopping decays live speed toward zero and blanks pace, rather than freezing it.
14. Average pace stays unknown until the distance justifies it.
15. GPS loss → `weak` after 10 s, live speed blanks, duration and distance keep their values.
16. Signal return → back to `good`.
17. Clock jumps backwards 10 s → duration does not decrease.
18. Snapshot round-trip preserves distance, route and elapsed time.
19. A recovered run comes back paused; 30 minutes of dead process is not running time, and
    resuming does not claim the ground covered while dead.
20. Finishing with no fixes at all yields a valid, empty run (no crash path).
21. `reset` returns a clean idle tracker.

**`geo_test.dart` (13)** — haversine against known distances, longitude convergence, symmetry;
RDP collapsing straight lines, keeping real corners, never merging across a segment break, and
cutting a 3600-point route by >5×.

**`format_test.dart` (10)** — the m/km switch, `MM:SS` vs `H:MM:SS`, the `--:--` placeholder for
every undefined pace, the `99:59` clamp, NaN/negative input, and screen-reader labels.
