import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../domain/geo.dart';
import '../../domain/models/track_point.dart';
import '../theme.dart';

/// Draws a route on OpenStreetMap tiles.
///
/// One widget serves both uses: the summary map (fit to the whole route) and
/// the live map (following the runner). OSM rather than Google Maps so there is
/// no API key for a reviewer to provision and no Play-Services dependency.
///
/// The route is drawn one polyline **per segment**. That is the whole point of
/// segments: a pause or a signal blackout must appear as a break in the line,
/// never as a straight shortcut across ground nobody covered.
class RouteMap extends StatefulWidget {
  const RouteMap({
    super.key,
    required this.route,
    this.follow = false,
    this.showEndpoints = true,
    this.interactive = true,
  });

  final List<TrackPoint> route;

  /// Live mode: keep the latest position in view as it moves.
  final bool follow;

  final bool showEndpoints;
  final bool interactive;

  @override
  State<RouteMap> createState() => _RouteMapState();
}

class _RouteMapState extends State<RouteMap> {
  final MapController _controller = MapController();
  bool _ready = false;

  /// Set once the user pans or zooms: following stops fighting them for
  /// control until they ask for it back.
  bool _userMoved = false;

  @override
  void didUpdateWidget(RouteMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.follow || !_ready || _userMoved) return;
    final last = widget.route.isEmpty ? null : widget.route.last;
    if (last == null) return;
    // Jump rather than animate: an animation loop running for an hour is a
    // battery cost with nothing to show for it.
    _controller.move(
      LatLng(last.latitude, last.longitude),
      _controller.camera.zoom,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.route.isEmpty) return const _NoRoute();

    final segments = Geo.splitBySegment(widget.route);
    final bounds = Geo.bounds(widget.route)!;
    final (south, west, north, east) = bounds;
    final last = widget.route.last;

    return Stack(
      children: [
        FlutterMap(
          mapController: _controller,
          options: MapOptions(
            initialCenter: widget.follow
                ? LatLng(last.latitude, last.longitude)
                : LatLng((south + north) / 2, (west + east) / 2),
            initialZoom: widget.follow ? 17 : 15,
            initialCameraFit: widget.follow
                ? null
                : CameraFit.bounds(
                    bounds: LatLngBounds(
                      LatLng(south, west),
                      LatLng(north, east),
                    ),
                    padding: const EdgeInsets.all(36),
                    maxZoom: 17,
                  ),
            backgroundColor: RunTheme.surface,
            interactionOptions: InteractionOptions(
              flags: widget.interactive
                  ? InteractiveFlag.drag |
                        InteractiveFlag.pinchZoom |
                        InteractiveFlag.doubleTapZoom |
                        InteractiveFlag.flingAnimation
                  : InteractiveFlag.none,
            ),
            onMapReady: () => setState(() => _ready = true),
            onPositionChanged: (_, hasGesture) {
              if (hasGesture && !_userMoved) setState(() => _userMoved = true);
            },
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              // OSM's tile policy requires an identifying user agent.
              userAgentPackageName: 'com.plexqo.plexqo_run',
              maxNativeZoom: 19,
              // A missing tile is a network problem, not a data problem: the
              // route still draws on the empty canvas underneath.
              errorTileCallback: (_, _, _) {},
            ),
            // Gap connectors, drawn under the route itself.
            //
            // A segment break means GPS was lost, so the ground between the two
            // ends was never recorded. Leaving a hole reads as a broken app, but
            // drawing a solid line there would claim a path that was never
            // measured. A dashed, dimmed line says "we got from here to there,
            // but this part is not data" — and no distance is credited for it.
            PolylineLayer(
              polylines: [
                for (var i = 1; i < segments.length; i++)
                  Polyline(
                    points: [
                      LatLng(
                        segments[i - 1].last.latitude,
                        segments[i - 1].last.longitude,
                      ),
                      LatLng(
                        segments[i].first.latitude,
                        segments[i].first.longitude,
                      ),
                    ],
                    strokeWidth: 3,
                    color: RunTheme.route.withValues(alpha: 0.45),
                    pattern: StrokePattern.dashed(segments: const [12, 10]),
                  ),
              ],
            ),
            PolylineLayer(
              polylines: [
                for (final segment in segments)
                  if (segment.length >= 2)
                    Polyline(
                      points: [
                        for (final p in segment) LatLng(p.latitude, p.longitude),
                      ],
                      strokeWidth: 5,
                      color: RunTheme.route,
                      borderStrokeWidth: 1.5,
                      borderColor: const Color(0xB3000000),
                    ),
              ],
            ),
            if (widget.showEndpoints)
              MarkerLayer(
                markers: [
                  _dot(widget.route.first, RunTheme.running),
                  if (widget.route.length > 1) _dot(last, RunTheme.danger),
                ],
              ),
            const RichAttributionWidget(
              alignment: AttributionAlignment.bottomLeft,
              attributions: [
                TextSourceAttribution('OpenStreetMap contributors'),
              ],
            ),
          ],
        ),
        if (widget.follow && _userMoved)
          Positioned(
            right: 8,
            top: 8,
            child: FloatingActionButton.small(
              heroTag: 'recenter',
              backgroundColor: RunTheme.surfaceHigh,
              foregroundColor: RunTheme.textPrimary,
              onPressed: () {
                setState(() => _userMoved = false);
                _controller.move(LatLng(last.latitude, last.longitude), 17);
              },
              child: const Icon(Icons.my_location, size: 18),
            ),
          ),
      ],
    );
  }

  Marker _dot(TrackPoint point, Color color) => Marker(
    point: LatLng(point.latitude, point.longitude),
    width: 18,
    height: 18,
    child: Container(
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.black.withValues(alpha: 0.6), width: 2),
      ),
    ),
  );
}

/// Shown when a run has no usable route. An empty state that says why beats a
/// blank grey rectangle that looks broken.
class _NoRoute extends StatelessWidget {
  const _NoRoute();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: RunTheme.surface,
        borderRadius: BorderRadius.circular(16),
      ),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(24),
      child: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.map_outlined, color: RunTheme.textSecondary, size: 28),
          SizedBox(height: 10),
          Text(
            'No route recorded',
            style: TextStyle(
              color: RunTheme.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          SizedBox(height: 4),
          Text(
            'GPS was unavailable for this run.',
            textAlign: TextAlign.center,
            style: TextStyle(color: RunTheme.textSecondary, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
