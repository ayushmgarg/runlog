class LocationSample {
  const LocationSample({
    required this.latitude,
    required this.longitude,
    required this.accuracy,
    required this.timestamp,
  });

  final double latitude;
  final double longitude;
  final double accuracy;
  final DateTime timestamp;

  @override
  String toString() =>
      'LocationSample($latitude, $longitude, ±${accuracy.toStringAsFixed(0)}m, $timestamp)';
}
