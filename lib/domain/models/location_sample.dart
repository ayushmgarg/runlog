/// A single raw position reading, as handed to us by a [LocationProvider].
///
/// Deliberately plugin-free so the whole tracking engine can be exercised with
/// synthetic data in unit tests.
class LocationSample {
  const LocationSample({
    required this.latitude,
    required this.longitude,
    required this.accuracy,
    required this.timestamp,
  });

  final double latitude;
  final double longitude;

  /// Horizontal accuracy in metres (68% confidence radius). Larger is worse.
  final double accuracy;

  /// Device time of the fix. The engine never reads the clock for this.
  final DateTime timestamp;

  @override
  String toString() =>
      'LocationSample($latitude, $longitude, ±${accuracy.toStringAsFixed(0)}m, $timestamp)';
}
