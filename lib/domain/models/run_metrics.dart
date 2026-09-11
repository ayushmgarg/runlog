import 'run_status.dart';

/// An immutable snapshot of a run, produced by `RunTracker` for the UI.
///
/// The UI never reaches into the tracker's mutable state; it renders one of
/// these. Nullable fields mean "not knowable yet" and must render as a
/// placeholder (`--:--`), never as zero — a fabricated zero pace is worse than
/// an honest blank.
class RunMetrics {
  const RunMetrics({
    required this.status,
    required this.gpsQuality,
    required this.distanceMeters,
    required this.elapsed,
    required this.currentSpeedMps,
    required this.pointCount,
    this.isEstimatingFromSteps = false,
  });

  final RunStatus status;
  final GpsQuality gpsQuality;
  final double distanceMeters;

  /// Active time only — paused time is never included.
  final Duration elapsed;

  /// Rolling-window speed, or null when there is not enough recent data.
  final double? currentSpeedMps;

  final int pointCount;

  /// Distance is currently coming from the step counter because GPS is not
  /// usable. The UI says so: an estimate must not be presented as a
  /// measurement.
  final bool isEstimatingFromSteps;

  static const empty = RunMetrics(
    status: RunStatus.idle,
    gpsQuality: GpsQuality.acquiring,
    distanceMeters: 0,
    elapsed: Duration.zero,
    currentSpeedMps: null,
    pointCount: 0,
  );

  double get distanceKm => distanceMeters / 1000.0;

  /// Live speed in km/h — the same measurement as [currentPace], in the unit
  /// most people already read movement in.
  double? get currentSpeedKmh =>
      currentSpeedMps == null ? null : currentSpeedMps! * 3.6;

  /// Below this the runner has effectively stopped, and pace stops being a
  /// meaningful number: 0.5 m/s is already 33 min/km, slower than a stroll.
  /// Reporting "119:00 /km" would be arithmetically true and useless.
  static const double _stoppedSpeedMps = 0.5;

  /// Seconds per kilometre over the rolling window, or null when unknown.
  /// A stopped runner has no pace, so this yields null rather than a number
  /// that grows without bound.
  double? get currentPaceSecondsPerKm {
    final speed = currentSpeedMps;
    if (speed == null || speed < _stoppedSpeedMps) return null;
    return 1000.0 / speed;
  }

  /// Whole-run pace. Suppressed until there is enough distance for it to mean
  /// anything (see `TrackerConfig.minDistanceForAveragePaceMeters`).
  double? averagePaceSecondsPerKm({double minDistanceMeters = 50}) {
    if (distanceMeters < minDistanceMeters) return null;
    if (elapsed == Duration.zero) return null;
    return elapsed.inMilliseconds / 1000.0 / (distanceMeters / 1000.0);
  }

  double? averageSpeedKmh({double minDistanceMeters = 50}) {
    final pace = averagePaceSecondsPerKm(minDistanceMeters: minDistanceMeters);
    if (pace == null || pace <= 0) return null;
    return 3600.0 / pace;
  }
}
