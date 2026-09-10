import 'dart:async';
import 'dart:math' as math;

import '../domain/location_provider.dart';
import '../domain/models/location_sample.dart';

/// A replayable fake GPS: runs a scripted lap around a 1 km block.
///
/// This exists because the deliverable has to be *testable*. A reviewer with an
/// emulator, or anyone indoors, can otherwise only stare at a stationary
/// screen. It is not a product feature and is surfaced as a clearly-labelled
/// demo toggle.
///
/// The script deliberately includes the nasty parts of a real run, so the edge
/// cases are demonstrable rather than merely claimed:
///
/// | from | to   | what happens                                          |
/// |------|------|-------------------------------------------------------|
/// | 0 s  | 40 s | running at ~2.8 m/s with realistic scatter             |
/// | 40 s | 60 s | stopped at a crossing — distance must not creep up     |
/// | 60 s | 95 s | running again                                          |
/// | 95 s | 130 s| GPS blackout: no fixes at all — badge must go weak     |
/// | 130 s| ...  | signal returns further along: a gap, not a shortcut    |
class SimulatedLocationProvider implements LocationProvider {
  SimulatedLocationProvider({
    this.centerLatitude = 12.9716,
    this.centerLongitude = 77.5946,
    this.speedMetersPerSecond = 2.8,
    this.accuracyMeters = 6,
    this.noiseSigmaMeters = 2.5,
    int seed = 7,
  }) : _random = math.Random(seed);

  final double centerLatitude;
  final double centerLongitude;
  final double speedMetersPerSecond;
  final double accuracyMeters;
  final double noiseSigmaMeters;
  final math.Random _random;

  Timer? _timer;
  StreamController<LocationSample>? _controller;

  /// Seconds since this provider's stream started.
  int _tick = 0;

  /// Distance covered along the lap so far, in metres.
  double _travelled = 0;

  /// A 300 m x 200 m block: 1 km per lap, and rectangular so the route on the
  /// map is obviously a route and not a random walk.
  static const double _legNorth = 300;
  static const double _legEast = 200;
  static const double _perimeter = 2 * (_legNorth + _legEast);

  static const double _metersPerDegreeLat = 111320.0;

  @override
  Future<LocationAvailability> checkAvailability() async =>
      LocationAvailability.ready;

  @override
  Future<LocationAvailability> requestPermission() async =>
      LocationAvailability.ready;

  @override
  Future<void> openAppSettings() async {}

  @override
  Future<void> openLocationSettings() async {}

  @override
  Future<LocationSample?> lastKnownOrCurrent() async => _sampleAt(0);

  @override
  Stream<LocationSample> positionStream() {
    _controller?.close();
    _timer?.cancel();
    _tick = 0;
    _travelled = 0;

    final controller = StreamController<LocationSample>.broadcast();
    _controller = controller;

    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      _tick++;
      final phase = _phaseAt(_tick);
      if (phase == _Phase.blackout) return; // emits nothing, like real signal loss
      if (phase == _Phase.running) _travelled += speedMetersPerSecond;
      if (!controller.isClosed) controller.add(_sampleAt(_travelled));
    });

    return controller.stream;
  }

  _Phase _phaseAt(int second) {
    final t = second % 200; // the whole script loops, so a long demo stays lively
    if (t < 40) return _Phase.running;
    if (t < 60) return _Phase.stopped;
    if (t < 95) return _Phase.running;
    if (t < 130) return _Phase.blackout;
    return _Phase.running;
  }

  /// Position at [travelled] metres around the block, plus Gaussian scatter so
  /// the filter chain has something real to do.
  LocationSample _sampleAt(double travelled) {
    final along = travelled % _perimeter;
    double north;
    double east;

    if (along < _legNorth) {
      north = along;
      east = 0;
    } else if (along < _legNorth + _legEast) {
      north = _legNorth;
      east = along - _legNorth;
    } else if (along < 2 * _legNorth + _legEast) {
      north = _legNorth - (along - _legNorth - _legEast);
      east = _legEast;
    } else {
      north = 0;
      east = _legEast - (along - 2 * _legNorth - _legEast);
    }

    final (noiseNorth, noiseEast) = _gaussianOffset();
    return LocationSample(
      latitude:
          centerLatitude + (north + noiseNorth) / _metersPerDegreeLat,
      longitude:
          centerLongitude +
          (east + noiseEast) /
              (_metersPerDegreeLat *
                  math.cos(centerLatitude * math.pi / 180.0)),
      accuracy: accuracyMeters,
      timestamp: DateTime.now(),
    );
  }

  /// Box–Muller: real GPS scatter is roughly Gaussian, not uniform, and the
  /// difference matters to a filter tuned against it.
  (double, double) _gaussianOffset() {
    final u1 = math.max(_random.nextDouble(), 1e-9);
    final u2 = _random.nextDouble();
    final radius = noiseSigmaMeters * math.sqrt(-2 * math.log(u1));
    final angle = 2 * math.pi * u2;
    return (radius * math.cos(angle), radius * math.sin(angle));
  }

  @override
  Future<void> dispose() async {
    _timer?.cancel();
    _timer = null;
    await _controller?.close();
    _controller = null;
  }
}

enum _Phase { running, stopped, blackout }
