/// Every tunable threshold in the tracking engine, in one place.
///
/// Injectable so tests can drive edge cases without waiting real seconds, and
/// so a future device-specific profile is a constructor argument rather than a
/// hunt through the code. Rationale for each value lives in
/// `docs/02-tracking-algorithm.md`.
class TrackerConfig {
  const TrackerConfig({
    this.maxAccuracyMeters = 25,
    this.maxFirstFixAccuracyMeters = 50,
    this.minMovementMeters = 4,
    this.accuracyJitterFactor = 0.5,
    this.maxSpeedMetersPerSecond = 12,
    this.maxConsecutiveRejections = 3,
    this.smoothingAlpha = 0.3,
    this.signalGapThreshold = const Duration(seconds: 30),
    this.gpsStaleThreshold = const Duration(seconds: 10),
    this.paceWindow = const Duration(seconds: 30),
    this.minPaceWindow = const Duration(seconds: 10),
    this.minDistanceForAveragePaceMeters = 50,
  });

  /// F1 — fixes worse than this are noise, not data.
  final double maxAccuracyMeters;

  /// F1 — looser gate for the very first fix so a run can start before the
  /// antenna has fully settled.
  final double maxFirstFixAccuracyMeters;

  /// F3 — movement below this is treated as the runner standing still.
  final double minMovementMeters;

  /// F3 — the floor also scales with the fix's own accuracy: a ±20 m fix has to
  /// move further than a ±5 m one before we believe it.
  final double accuracyJitterFactor;

  /// F4 — anything faster than this is a GPS teleport, not a human.
  final double maxSpeedMetersPerSecond;

  /// F4b — how many implausible fixes in a row before we stop arguing with the
  /// receiver and re-anchor.
  ///
  /// Without this the speed gate quietly weakens: every rejection leaves the
  /// last good fix further in the past, so the *next* jump is divided by a
  /// bigger `dt` and eventually squeaks under the limit as a huge false
  /// distance. Re-anchoring turns a broken stretch into a gap, which is what it
  /// actually was.
  final int maxConsecutiveRejections;

  /// F6 — exponential-moving-average weight applied to accepted positions.
  ///
  /// The anchor rule alone does not survive real scatter: a noise point far
  /// enough from the anchor moves the anchor, and the walk repeats. Averaging
  /// shrinks the scatter by ~sqrt(alpha / (2 - alpha)) before the anchor rule
  /// ever sees it, which is what actually pins distance at zero while standing
  /// still. Cost is a constant lag of about `(1 - alpha) / alpha` fixes at the
  /// start of each segment (a few metres at running speed) — a one-off
  /// under-report, which is the safe direction to be wrong in.
  final double smoothingAlpha;

  /// F5 — a gap this long means the straight line across it is not a route.
  final Duration signalGapThreshold;

  /// No usable fix for this long ⇒ report [GpsQuality.weak] and stop showing
  /// live pace/speed rather than showing a frozen number.
  final Duration gpsStaleThreshold;

  /// Rolling window used for live pace and speed.
  final Duration paceWindow;

  /// Below this much data, live pace/speed is not meaningful yet.
  final Duration minPaceWindow;

  /// Average pace over a few noisy metres is a random number; suppress it.
  final double minDistanceForAveragePaceMeters;
}
