import '../geo.dart';
import 'run_metrics.dart';
import 'run_status.dart';
import 'track_point.dart';

/// A finished run, as stored on disk and shown on the summary screen.
///
/// Holds the *simplified* route: full fidelity matters while measuring, but a
/// saved run only has to be drawn, and drawing 3600 points is a waste of memory
/// for a line that looks identical with 400. Distance is carried as a value, so
/// it is never re-derived from the simplified geometry.
class RunRecord {
  const RunRecord({
    required this.id,
    required this.startedAt,
    required this.endedAt,
    required this.distanceMeters,
    required this.duration,
    required this.route,
  });

  final String id;
  final DateTime startedAt;
  final DateTime endedAt;
  final double distanceMeters;

  /// Active time only, excluding pauses.
  final Duration duration;

  final List<TrackPoint> route;

  double get distanceKm => distanceMeters / 1000.0;

  bool get hasRoute => route.length >= 2;

  /// Seconds per kilometre, or null for a run too short to characterise.
  double? get averagePaceSecondsPerKm {
    if (distanceMeters < 1 || duration == Duration.zero) return null;
    return duration.inMilliseconds / 1000.0 / (distanceMeters / 1000.0);
  }

  double? get averageSpeedKmh {
    final pace = averagePaceSecondsPerKm;
    if (pace == null || pace <= 0) return null;
    return 3600.0 / pace;
  }

  /// Builds a record from a finished tracker's numbers.
  factory RunRecord.fromRun({
    required DateTime startedAt,
    required DateTime endedAt,
    required RunMetrics metrics,
    required List<TrackPoint> route,
  }) {
    assert(metrics.status == RunStatus.finished || metrics.status.isInProgress);
    return RunRecord(
      id: startedAt.millisecondsSinceEpoch.toString(),
      startedAt: startedAt,
      endedAt: endedAt,
      distanceMeters: metrics.distanceMeters,
      duration: metrics.elapsed,
      route: Geo.simplify(route),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'startedAt': startedAt.millisecondsSinceEpoch,
    'endedAt': endedAt.millisecondsSinceEpoch,
    'distance': distanceMeters,
    'durationMs': duration.inMilliseconds,
    'route': route.map((p) => p.toJson()).toList(),
  };

  factory RunRecord.fromJson(Map<String, dynamic> json) => RunRecord(
    id: json['id'] as String,
    startedAt: DateTime.fromMillisecondsSinceEpoch(json['startedAt'] as int),
    endedAt: DateTime.fromMillisecondsSinceEpoch(json['endedAt'] as int),
    distanceMeters: (json['distance'] as num).toDouble(),
    duration: Duration(milliseconds: json['durationMs'] as int),
    route: ((json['route'] as List?) ?? const [])
        .map((e) => TrackPoint.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList(),
  );
}
