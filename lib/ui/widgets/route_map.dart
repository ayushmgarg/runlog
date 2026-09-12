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

  /// At least one tile failed to load, which in practice means there was no
  /// network when the map was first shown.
  bool _tilesFailed = false;

  /// Bumped to force a fresh tile layer.
  ///
  /// flutter_map does not retry a tile it has already failed, so turning the
  /// network on after the map has given up leaves it permanently blank. A new
  /// key rebuilds the layer, which re-requests every tile.
  int _tileEpoch = 0;

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
              key: ValueKey<int>(_tileEpoch),
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              // OSM's tile policy requires an identifying user agent.
              userAgentPackageName: 'com.plexqo.plexqo_run',
              maxNativeZoom: 19,
              // A missing tile is a network problem, not a data problem: the
              // route still draws on the empty canvas underneath. Noting the
              // failure lets the user ask for a retry once they have signal.
              errorTileCallback: (_, _, _) => _noteTileFailure(),
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
        if (_tilesFailed)
          Positioned(
            left: 0,
            right: 0,
            top: 8,
            child: Center(child: _RetryTiles(onRetry: _retryTiles)),
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

  /// Called from tile loading, so the rebuild is deferred to after this frame.
  void _noteTileFailure() {
    if (_tilesFailed) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_tilesFailed) setState(() => _tilesFailed = true);
    });
  }

  void _retryTiles() {
    setState(() {
      _tilesFailed = false;
      _tileEpoch++;
    });
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

/// Offered when tiles could not be fetched.
///
/// The map is the only part of the app that needs a network, and nothing about
/// the recorded run depends on it — so this is a quiet, optional affordance
/// rather than an error. The route is already drawn underneath on the plain
/// canvas; this just fetches the streets once there is signal.
class _RetryTiles extends StatelessWidget {
  const _RetryTiles({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: RunTheme.surfaceHigh.withValues(alpha: 0.92),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onRetry,
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off, size: 15, color: RunTheme.textSecondary),
              SizedBox(width: 8),
              Text(
                'Map offline',
                style: TextStyle(color: RunTheme.textSecondary, fontSize: 12),
              ),
              SizedBox(width: 10),
              Text(
                'RETRY',
                style: TextStyle(
                  color: RunTheme.route,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
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
