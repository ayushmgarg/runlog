class TrackPoint {
  const TrackPoint({
    required this.latitude,
    required this.longitude,
    required this.accuracy,
    required this.timestamp,
    required this.segment,
    required this.cumulativeMeters,
  });

  final double latitude;
  final double longitude;
  final double accuracy;
  final DateTime timestamp;
  final int segment;
  final double cumulativeMeters;

  Map<String, dynamic> toJson() => {
    'lat': latitude,
    'lon': longitude,
    'acc': accuracy,
    't': timestamp.millisecondsSinceEpoch,
    'seg': segment,
    'cum': cumulativeMeters,
  };

  factory TrackPoint.fromJson(Map<String, dynamic> json) => TrackPoint(
    latitude: (json['lat'] as num).toDouble(),
    longitude: (json['lon'] as num).toDouble(),
    accuracy: (json['acc'] as num).toDouble(),
    timestamp: DateTime.fromMillisecondsSinceEpoch(json['t'] as int),
    segment: json['seg'] as int,
    cumulativeMeters: (json['cum'] as num).toDouble(),
  );

  @override
  String toString() => 'TrackPoint($latitude, $longitude, seg $segment)';
}
