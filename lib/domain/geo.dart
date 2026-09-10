import 'dart:math' as math;

import 'models/track_point.dart';

/// Pure geodesy helpers. No plugins, no Flutter — unit-testable on the VM.
class Geo {
  Geo._();

  /// WGS-84 mean radius. Good to ~0.5% anywhere on Earth, which is far below
  /// GPS noise at running distances.
  static const double earthRadiusMeters = 6371008.8;

  /// Great-circle distance in metres.
  ///
  /// Haversine rather than the (more accurate) Vincenty: over the tens of
  /// metres between two consecutive fixes the difference is microscopic
  /// compared with the accuracy radius, and haversine cannot fail to converge.
  static double distanceMeters(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    final phi1 = _rad(lat1);
    final phi2 = _rad(lat2);
    final dPhi = _rad(lat2 - lat1);
    final dLambda = _rad(lon2 - lon1);

    final a =
        math.sin(dPhi / 2) * math.sin(dPhi / 2) +
        math.cos(phi1) *
            math.cos(phi2) *
            math.sin(dLambda / 2) *
            math.sin(dLambda / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return earthRadiusMeters * c;
  }

  static double _rad(double degrees) => degrees * math.pi / 180.0;

  /// Ramer–Douglas–Peucker simplification, applied per segment.
  ///
  /// A one-hour run is ~3600 points. Drawing and storing all of them is
  /// pointless: at [epsilonMeters] ≈ 5 the simplified line is visually
  /// identical at any zoom a phone can show, for roughly a tenth of the points.
  /// Only ever used for rendering and persistence — never for distance, which
  /// is accumulated from the unsimplified stream.
  static List<TrackPoint> simplify(
    List<TrackPoint> points, {
    double epsilonMeters = 5,
  }) {
    if (points.length <= 2) return List.unmodifiable(points);
    final out = <TrackPoint>[];
    for (final segment in splitBySegment(points)) {
      out.addAll(_rdp(segment, epsilonMeters));
    }
    return List.unmodifiable(out);
  }

  static List<TrackPoint> _rdp(List<TrackPoint> pts, double epsilon) {
    if (pts.length <= 2) return pts;

    var maxDistance = 0.0;
    var index = 0;
    for (var i = 1; i < pts.length - 1; i++) {
      final d = _perpendicularDistance(pts[i], pts.first, pts.last);
      if (d > maxDistance) {
        maxDistance = d;
        index = i;
      }
    }

    if (maxDistance <= epsilon) return [pts.first, pts.last];

    final left = _rdp(pts.sublist(0, index + 1), epsilon);
    final right = _rdp(pts.sublist(index), epsilon);
    return [...left.sublist(0, left.length - 1), ...right];
  }

  /// Distance from [p] to the line [a]–[b], in metres.
  ///
  /// Projected to a local flat plane first: over the span of one run the
  /// curvature error is negligible, and it keeps the maths cheap.
  static double _perpendicularDistance(TrackPoint p, TrackPoint a, TrackPoint b) {
    final latScale = earthRadiusMeters * math.pi / 180.0;
    final lonScale = latScale * math.cos(_rad(a.latitude));

    final px = (p.longitude - a.longitude) * lonScale;
    final py = (p.latitude - a.latitude) * latScale;
    final bx = (b.longitude - a.longitude) * lonScale;
    final by = (b.latitude - a.latitude) * latScale;

    final lengthSquared = bx * bx + by * by;
    if (lengthSquared == 0) return math.sqrt(px * px + py * py);

    var t = (px * bx + py * by) / lengthSquared;
    t = t.clamp(0.0, 1.0);
    final dx = px - t * bx;
    final dy = py - t * by;
    return math.sqrt(dx * dx + dy * dy);
  }

  /// Groups consecutive points by [TrackPoint.segment].
  ///
  /// Each group is drawn as its own polyline, so a pause or a tunnel shows as a
  /// break in the route rather than a straight line the runner never took.
  static List<List<TrackPoint>> splitBySegment(List<TrackPoint> points) {
    final segments = <List<TrackPoint>>[];
    for (final p in points) {
      if (segments.isEmpty || segments.last.last.segment != p.segment) {
        segments.add(<TrackPoint>[p]);
      } else {
        segments.last.add(p);
      }
    }
    return segments;
  }

  /// Bounding box of a route as `(south, west, north, east)`, or null if empty.
  /// Used to fit the summary map to the run.
  static (double, double, double, double)? bounds(List<TrackPoint> points) {
    if (points.isEmpty) return null;
    var south = points.first.latitude;
    var north = points.first.latitude;
    var west = points.first.longitude;
    var east = points.first.longitude;
    for (final p in points) {
      if (p.latitude < south) south = p.latitude;
      if (p.latitude > north) north = p.latitude;
      if (p.longitude < west) west = p.longitude;
      if (p.longitude > east) east = p.longitude;
    }
    return (south, west, north, east);
  }
}
