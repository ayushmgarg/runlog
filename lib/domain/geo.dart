import 'dart:math' as math;
import 'models/track_point.dart';

class Geo {
  Geo._();
  static const double earthRadiusMeters = 6371008.8;

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

  static double _perpendicularDistance(
    TrackPoint p,
    TrackPoint a,
    TrackPoint b,
  ) {
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
