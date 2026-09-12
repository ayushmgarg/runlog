import 'dart:math' as math;
import 'package:runlog/domain/models/location_sample.dart';

class FakeClock {
  FakeClock(this.now);
  DateTime now;
  DateTime call() => now;
  void advance(Duration d) => now = now.add(d);
  void rewind(Duration d) => now = now.subtract(d);
}

const double metersPerDegreeLat = 111320.0;

double metersPerDegreeLon(double latitude) =>
    metersPerDegreeLat * math.cos(latitude * math.pi / 180.0);

const double baseLat = 12.9716;
const double baseLon = 77.5946;

LocationSample sampleAt({
  required double northMeters,
  required double eastMeters,
  required DateTime at,
  double accuracy = 5,
  double lat = baseLat,
  double lon = baseLon,
}) {
  return LocationSample(
    latitude: lat + northMeters / metersPerDegreeLat,
    longitude: lon + eastMeters / metersPerDegreeLon(lat),
    accuracy: accuracy,
    timestamp: at,
  );
}

List<LocationSample> straightLine({
  required DateTime start,
  required int count,
  double metersPerFix = 3,
  Duration interval = const Duration(seconds: 1),
  double accuracy = 5,
  double startOffsetMeters = 0,
}) {
  return List.generate(count, (i) {
    return sampleAt(
      northMeters: startOffsetMeters + i * metersPerFix,
      eastMeters: 0,
      at: start.add(interval * i),
      accuracy: accuracy,
    );
  });
}

List<LocationSample> stationaryJitter({
  required DateTime start,
  required int count,
  double sigmaMeters = 2,
  Duration interval = const Duration(seconds: 1),
  double accuracy = 5,
  int seed = 42,
  double originNorthMeters = 0,
  double originEastMeters = 0,
}) {
  final random = math.Random(seed);
  return List.generate(count, (i) {
    // Box–Muller: real GPS scatter is roughly Gaussian, not uniform.
    final u1 = math.max(random.nextDouble(), 1e-9);
    final u2 = random.nextDouble();
    final radius = sigmaMeters * math.sqrt(-2 * math.log(u1));
    final angle = 2 * math.pi * u2;
    return sampleAt(
      northMeters: originNorthMeters + radius * math.cos(angle),
      eastMeters: originEastMeters + radius * math.sin(angle),
      at: start.add(interval * i),
      accuracy: accuracy,
    );
  });
}

double naiveDistance(List<LocationSample> samples) {
  var total = 0.0;
  for (var i = 1; i < samples.length; i++) {
    final a = samples[i - 1];
    final b = samples[i];
    final dLat = (b.latitude - a.latitude) * metersPerDegreeLat;
    final dLon = (b.longitude - a.longitude) * metersPerDegreeLon(a.latitude);
    total += math.sqrt(dLat * dLat + dLon * dLon);
  }
  return total;
}
