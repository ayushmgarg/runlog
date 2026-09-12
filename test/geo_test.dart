import 'package:flutter_test/flutter_test.dart';
import 'package:runlog/domain/geo.dart';
import 'package:runlog/domain/models/track_point.dart';
import 'helpers.dart';

void main() {
  final t0 = DateTime.utc(2026, 9, 11, 7, 0, 0);

  TrackPoint point(
    double north,
    double east, {
    int segment = 0,
    int second = 0,
  }) {
    final s = sampleAt(
      northMeters: north,
      eastMeters: east,
      at: t0.add(Duration(seconds: second)),
    );
    return TrackPoint(
      latitude: s.latitude,
      longitude: s.longitude,
      accuracy: s.accuracy,
      timestamp: s.timestamp,
      segment: segment,
      cumulativeMeters: 0,
    );
  }

  group('distance', () {
    test('is zero for identical points', () {
      expect(Geo.distanceMeters(baseLat, baseLon, baseLat, baseLon), 0);
    });

    test('matches a known short north-south hop', () {
      // 0.001 degrees of latitude is ~111.32 m anywhere on Earth.
      final d = Geo.distanceMeters(baseLat, baseLon, baseLat + 0.001, baseLon);
      expect(d, closeTo(111.32, 0.5));
    });

    test('accounts for longitude converging away from the equator', () {
      // The same longitude delta is a shorter distance at 60°N than at 0°N.
      final atEquator = Geo.distanceMeters(0, 0, 0, 0.01);
      final atSixty = Geo.distanceMeters(60, 0, 60, 0.01);
      expect(atSixty, closeTo(atEquator * 0.5, 2));
    });

    test('matches a known long-haul distance', () {
      // London to Paris, ~343 km great-circle.
      final d = Geo.distanceMeters(51.5074, -0.1278, 48.8566, 2.3522);
      expect(d / 1000, closeTo(343, 3));
    });

    test('is symmetric', () {
      final ab = Geo.distanceMeters(12.9716, 77.5946, 12.9800, 77.6100);
      final ba = Geo.distanceMeters(12.9800, 77.6100, 12.9716, 77.5946);
      expect(ab, closeTo(ba, 1e-9));
    });
  });

  group('simplify', () {
    test('collapses a straight line to its endpoints', () {
      final line = List.generate(50, (i) => point(i * 3.0, 0, second: i));
      final simplified = Geo.simplify(line);
      expect(simplified.length, 2);
      expect(simplified.first.latitude, line.first.latitude);
      expect(simplified.last.latitude, line.last.latitude);
    });

    test('keeps a corner that a runner actually turned', () {
      final route = <TrackPoint>[
        point(0, 0, second: 0),
        point(50, 0, second: 10),
        point(100, 0, second: 20),
        point(100, 50, second: 30),
        point(100, 100, second: 40),
      ];
      final simplified = Geo.simplify(route);
      expect(simplified.length, 3, reason: 'start, corner, end');
    });

    test('never merges across a segment break', () {
      final route = <TrackPoint>[
        point(0, 0, second: 0),
        point(30, 0, second: 10),
        point(60, 0, second: 20),
        point(500, 0, segment: 1, second: 300),
        point(530, 0, segment: 1, second: 310),
        point(560, 0, segment: 1, second: 320),
      ];
      final simplified = Geo.simplify(route);
      expect(Geo.splitBySegment(simplified).length, 2);
    });

    test('is a no-op for degenerate routes', () {
      expect(Geo.simplify(const <TrackPoint>[]), isEmpty);
      expect(Geo.simplify([point(0, 0)]).length, 1);
    });

    test('cuts a realistic route down by an order of magnitude', () {
      final route = List.generate(3600, (i) {
        final north = i * 1.5;
        final east = 20.0 * (i % 600) / 600.0;
        return point(north, east, second: i);
      });
      final simplified = Geo.simplify(route);
      expect(simplified.length, lessThan(route.length ~/ 5));
      expect(simplified.length, greaterThan(2));
    });
  });

  group('bounds', () {
    test('returns null for an empty route', () {
      expect(Geo.bounds(const <TrackPoint>[]), isNull);
    });

    test('encloses every point', () {
      final route = [point(0, 0), point(100, 50), point(-40, 200)];
      final b = Geo.bounds(route)!;
      final (south, west, north, east) = b;
      for (final p in route) {
        expect(p.latitude, greaterThanOrEqualTo(south));
        expect(p.latitude, lessThanOrEqualTo(north));
        expect(p.longitude, greaterThanOrEqualTo(west));
        expect(p.longitude, lessThanOrEqualTo(east));
      }
    });
  });
}
