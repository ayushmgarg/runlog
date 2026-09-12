import 'run_status.dart';

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
  final Duration elapsed;
  final double? currentSpeedMps;
  final int pointCount;
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

  double? get currentSpeedKmh =>
      currentSpeedMps == null ? null : currentSpeedMps! * 3.6;

  static const double _stoppedSpeedMps = 0.5;

  double? get currentPaceSecondsPerKm {
    final speed = currentSpeedMps;
    if (speed == null || speed < _stoppedSpeedMps) return null;
    return 1000.0 / speed;
  }

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
