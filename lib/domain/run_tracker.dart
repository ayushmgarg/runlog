import 'dart:math' as math;

import 'geo.dart';
import 'models/location_sample.dart';
import 'models/run_metrics.dart';
import 'models/run_status.dart';
import 'models/track_point.dart';
import 'tracker_config.dart';

/// Reads the wall clock. Injected so tests control time exactly instead of
/// sleeping.
typedef Clock = DateTime Function();

/// Why a sample did not contribute distance. Returned by [RunTracker.addSample]
/// so tests can assert on the filter chain, and so GPS quality can be explained
/// instead of fixes being silently swallowed.
enum SampleOutcome {
  /// Accepted and moved the runner forward.
  accepted,

  /// Valid fix, but the runner has not actually moved (F3 jitter floor).
  stationary,

  /// Valid fix after a signal gap: starts a new segment, adds no distance (F5).
  gapReanchor,

  /// First usable fix of a run or of a segment: becomes the anchor.
  anchored,

  /// Fix was too imprecise to use (F1).
  rejectedAccuracy,

  /// Duplicate or out-of-order fix (F2).
  rejectedOutOfOrder,

  /// Implied speed is not physically plausible, i.e. a GPS teleport (F4).
  rejectedImplausibleSpeed,

  /// The run is not active, so samples are not recorded at all.
  ignoredNotActive,
}

/// The whole tracking engine: state machine, GPS filter chain, and metrics.
///
/// Contains no Flutter and no plugin imports on purpose. Every rule in
/// `docs/02-tracking-algorithm.md` is verified against synthetic traces in
/// `test/run_tracker_test.dart` rather than by going for a jog.
class RunTracker {
  RunTracker({TrackerConfig? config, Clock? clock})
    : config = config ?? const TrackerConfig(),
      _clock = clock ?? DateTime.now;

  final TrackerConfig config;
  final Clock _clock;

  RunStatus _status = RunStatus.idle;
  DateTime? _startedAt;

  /// Active time already banked from completed (paused-off) segments.
  Duration _completed = Duration.zero;

  /// Start of the currently running segment, or null when not active.
  DateTime? _segmentStartedAt;

  /// Guards against a device clock that jumps backwards (NTP correction):
  /// elapsed time may stall, but it must never rewind.
  Duration _elapsedFloor = Duration.zero;

  final List<TrackPoint> _route = <TrackPoint>[];
  double _distanceMeters = 0;
  int _segment = 0;

  /// Last point that distance was measured *from*. Stays put while the runner
  /// is standing still, which is what stops GPS jitter inflating the distance.
  TrackPoint? _anchor;

  /// Last sample that passed the accuracy and ordering gates, movement or not.
  /// Used for the speed sanity check and for detecting signal gaps, both of
  /// which must be measured against the last *fix*, not the last movement.
  LocationSample? _lastFix;

  /// Smoothed position (F6). Distance, the anchor and the drawn route all use
  /// this rather than the raw fix.
  double? _smoothLat;
  double? _smoothLon;

  /// Implausible fixes seen back-to-back. See
  /// [TrackerConfig.maxConsecutiveRejections].
  int _consecutiveRejections = 0;

  // ----------------------------------------------------------------- getters

  RunStatus get status => _status;
  DateTime? get startedAt => _startedAt;
  double get distanceMeters => _distanceMeters;
  List<TrackPoint> get route => List.unmodifiable(_route);
  int get segmentCount => _route.isEmpty ? 0 : _route.last.segment + 1;

  /// Active running time. Derived from the wall clock rather than counted
  /// ticks, so a throttled timer or a backgrounded app cannot lose seconds.
  Duration get elapsed {
    var value = _completed;
    final segmentStart = _segmentStartedAt;
    if (segmentStart != null) {
      final delta = _clock().difference(segmentStart);
      if (delta > Duration.zero) value += delta;
    }
    if (value < _elapsedFloor) return _elapsedFloor;
    _elapsedFloor = value;
    return value;
  }

  GpsQuality get gpsQuality {
    if (!_status.isInProgress) {
      return _route.isEmpty ? GpsQuality.acquiring : GpsQuality.good;
    }
    final last = _lastFix;
    if (last == null) return GpsQuality.acquiring;
    if (_clock().difference(last.timestamp) > config.gpsStaleThreshold) {
      return GpsQuality.weak;
    }
    return GpsQuality.good;
  }

  RunMetrics get metrics => RunMetrics(
    status: _status,
    gpsQuality: gpsQuality,
    distanceMeters: _distanceMeters,
    elapsed: elapsed,
    currentSpeedMps: _currentSpeedMps(),
    pointCount: _route.length,
  );

  /// Rolling-window speed in m/s, or null when it cannot be known.
  ///
  /// The window *ends at now*, not at the last recorded point, so standing
  /// still decays the reading toward zero instead of freezing it at the last
  /// running speed. The GPS chip's own speed field is ignored: it is
  /// inconsistent across devices and absent from simulated traces.
  double? _currentSpeedMps() {
    if (_status != RunStatus.active) return null;
    if (_route.isEmpty) return null;
    if (gpsQuality == GpsQuality.weak) return null;

    final now = _clock();
    final windowStart = now.subtract(config.paceWindow);

    // Walk back from the end: the window is bounded, so this is O(window) and
    // not O(route), no matter how long the run gets.
    var index = _route.length - 1;
    while (index > 0 && _route[index - 1].timestamp.isAfter(windowStart)) {
      index--;
    }
    // Include the point just before the window so the first metres inside it
    // are attributed, unless that point belongs to a previous segment.
    if (index > 0 && _route[index - 1].segment == _route[index].segment) {
      index--;
    }

    final start = _route[index];
    final windowSeconds =
        now.difference(start.timestamp).inMilliseconds / 1000.0;
    if (windowSeconds < config.minPaceWindow.inMilliseconds / 1000.0) {
      return null;
    }

    final metres = _route.last.cumulativeMeters - start.cumulativeMeters;
    return math.max(0.0, metres / windowSeconds);
  }

  // ----------------------------------------------------------- state machine

  /// idle to active. Duration starts immediately, before the first fix: the
  /// runner is already running while the antenna warms up, and losing those
  /// seconds is worse than starting distance at zero.
  void start() {
    if (_status != RunStatus.idle) return;
    final now = _clock();
    _status = RunStatus.active;
    _startedAt = now;
    _segmentStartedAt = now;
    _completed = Duration.zero;
    _elapsedFloor = Duration.zero;
    _distanceMeters = 0;
    _segment = 0;
    _route.clear();
    _clearFilterState();
  }

  /// active to paused. Banks the segment and drops the anchor, so movement
  /// during the pause can never be counted when the run resumes.
  void pause() {
    if (_status != RunStatus.active) return;
    _bankSegment();
    _status = RunStatus.paused;
    _clearFilterState();
  }

  /// paused to active. Starts a new route segment so the pause renders as a
  /// break in the line instead of a straight shortcut.
  void resume() {
    if (_status != RunStatus.paused) return;
    _status = RunStatus.active;
    _segmentStartedAt = _clock();
    _segment++;
  }

  /// active or paused to finished. Terminal: further samples are ignored.
  void finish() {
    if (!_status.isInProgress) return;
    if (_status == RunStatus.active) _bankSegment();
    _status = RunStatus.finished;
    _clearFilterState();
  }

  /// Clears everything back to [RunStatus.idle], ready for another run.
  void reset() {
    _status = RunStatus.idle;
    _startedAt = null;
    _completed = Duration.zero;
    _segmentStartedAt = null;
    _elapsedFloor = Duration.zero;
    _route.clear();
    _distanceMeters = 0;
    _segment = 0;
    _clearFilterState();
  }

  /// Drops everything the filter chain carries between fixes, so the next fix
  /// starts a clean segment. Called on every discontinuity: start, pause,
  /// finish, reset.
  void _clearFilterState() {
    _anchor = null;
    _lastFix = null;
    _smoothLat = null;
    _smoothLon = null;
    _consecutiveRejections = 0;
  }

  void _bankSegment() {
    final segmentStart = _segmentStartedAt;
    if (segmentStart != null) {
      final delta = _clock().difference(segmentStart);
      if (delta > Duration.zero) _completed += delta;
    }
    _segmentStartedAt = null;
  }

  // ------------------------------------------------------------ filter chain

  /// Feeds one raw fix through the filter chain. See
  /// `docs/02-tracking-algorithm.md` section 2 for the rationale behind each
  /// gate.
  SampleOutcome addSample(LocationSample sample) {
    if (_status != RunStatus.active) return SampleOutcome.ignoredNotActive;

    // F1: accuracy gate. The first fix of a run gets a looser bar so tracking
    // can begin before the antenna has fully settled.
    final isFirstFix = _lastFix == null && _route.isEmpty;
    final accuracyLimit = isFirstFix
        ? config.maxFirstFixAccuracyMeters
        : config.maxAccuracyMeters;
    if (sample.accuracy > accuracyLimit) return SampleOutcome.rejectedAccuracy;

    final previous = _lastFix;
    if (previous != null) {
      // F2: duplicates and out-of-order fixes from the fused provider.
      if (!sample.timestamp.isAfter(previous.timestamp)) {
        return SampleOutcome.rejectedOutOfOrder;
      }

      final gap = sample.timestamp.difference(previous.timestamp);

      // F5: after a long blackout the straight line between the endpoints is
      // not a route the runner ran. Re-anchor into a new segment and add
      // nothing. Under-reporting beats inventing a shortcut.
      if (gap > config.signalGapThreshold) {
        _reanchor(sample);
        return SampleOutcome.gapReanchor;
      }

      // F4: implied speed since the last *fix*, not the last movement, which
      // may be minutes old if the runner has been standing still.
      final metresSinceFix = Geo.distanceMeters(
        previous.latitude,
        previous.longitude,
        sample.latitude,
        sample.longitude,
      );
      final seconds = gap.inMilliseconds / 1000.0;
      if (seconds > 0 &&
          metresSinceFix / seconds > config.maxSpeedMetersPerSecond) {
        _consecutiveRejections++;
        // F4b: a run of rejections means the receiver has genuinely moved us
        // somewhere else (provider switch, tunnel exit, mock location), not
        // that one fix was noisy. Keep rejecting and the growing `dt` would
        // eventually let the same jump through as real distance, so treat the
        // stretch as a gap instead.
        if (_consecutiveRejections >= config.maxConsecutiveRejections) {
          _reanchor(sample);
          return SampleOutcome.gapReanchor;
        }
        return SampleOutcome.rejectedImplausibleSpeed;
      }
    }

    _consecutiveRejections = 0;
    _lastFix = sample;

    // F6: smooth before measuring. See TrackerConfig.smoothingAlpha.
    final position = _smooth(sample);

    final anchor = _anchor;
    if (anchor == null) {
      _anchor = _appendPoint(position, _distanceMeters);
      return SampleOutcome.anchored;
    }

    final metres = Geo.distanceMeters(
      anchor.latitude,
      anchor.longitude,
      position.latitude,
      position.longitude,
    );

    // F3: the jitter floor, and the single most important rule here. While the
    // runner stands still, consecutive fixes scatter inside the accuracy
    // radius, and adding up those hops is how naive trackers invent hundreds of
    // metres. The anchor does not move until real movement is proven.
    final floor = math.max(
      config.minMovementMeters,
      sample.accuracy * config.accuracyJitterFactor,
    );
    if (metres < floor) return SampleOutcome.stationary;

    _distanceMeters += metres;
    _anchor = _appendPoint(position, _distanceMeters);
    return SampleOutcome.accepted;
  }

  /// Starts a fresh segment at [sample] without crediting any distance for
  /// getting there. Used for both kinds of discontinuity: a signal blackout
  /// (F5) and a burst of implausible fixes (F4b).
  void _reanchor(LocationSample sample) {
    _segment++;
    _consecutiveRejections = 0;
    _lastFix = sample;
    _smoothLat = null;
    _smoothLon = null;
    _anchor = _appendPoint(_smooth(sample), _distanceMeters);
  }

  /// Exponential moving average over accepted positions (F6).
  ///
  /// Runs on latitude/longitude directly rather than on a projected plane: over
  /// the metres between two fixes the two are indistinguishable, and staying in
  /// degrees keeps this allocation-free on every fix.
  LocationSample _smooth(LocationSample sample) {
    final previousLat = _smoothLat;
    final previousLon = _smoothLon;
    if (previousLat == null || previousLon == null) {
      _smoothLat = sample.latitude;
      _smoothLon = sample.longitude;
      return sample;
    }
    final alpha = config.smoothingAlpha;
    _smoothLat = previousLat + alpha * (sample.latitude - previousLat);
    _smoothLon = previousLon + alpha * (sample.longitude - previousLon);
    return LocationSample(
      latitude: _smoothLat!,
      longitude: _smoothLon!,
      accuracy: sample.accuracy,
      timestamp: sample.timestamp,
    );
  }

  TrackPoint _appendPoint(LocationSample sample, double cumulative) {
    final point = TrackPoint(
      latitude: sample.latitude,
      longitude: sample.longitude,
      accuracy: sample.accuracy,
      timestamp: sample.timestamp,
      segment: _segment,
      cumulativeMeters: cumulative,
    );
    _route.add(point);
    return point;
  }

  // ---------------------------------------------------- crash recovery I/O

  /// Snapshot of an in-progress run, written periodically so a crash or a
  /// process kill does not lose the run.
  Map<String, dynamic> toSnapshot() => {
    'version': 1,
    'status': _status.name,
    'startedAt': _startedAt?.millisecondsSinceEpoch,
    // Elapsed is banked at snapshot time: the process may be dead for an hour
    // before this is read back, and that hour is not running time.
    'elapsedMs': elapsed.inMilliseconds,
    'distance': _distanceMeters,
    'segment': _segment,
    'route': _route.map((p) => p.toJson()).toList(),
  };

  /// Restores a snapshot as a **paused** run, whatever it was when saved.
  ///
  /// The time between the crash and the restart was not running time, and we
  /// cannot know whether the runner kept going. Handing control back paused,
  /// with the banked distance and route intact, is the honest option: the user
  /// then resumes, saves, or discards.
  static RunTracker fromSnapshot(
    Map<String, dynamic> json, {
    TrackerConfig? config,
    Clock? clock,
  }) {
    final tracker = RunTracker(config: config, clock: clock);
    final startedAtMs = json['startedAt'] as int?;
    tracker._startedAt = startedAtMs == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(startedAtMs);
    tracker._completed = Duration(
      milliseconds: (json['elapsedMs'] as int?) ?? 0,
    );
    tracker._elapsedFloor = tracker._completed;
    tracker._distanceMeters = (json['distance'] as num?)?.toDouble() ?? 0;
    tracker._segment = (json['segment'] as int?) ?? 0;
    tracker._route
      ..clear()
      ..addAll(
        ((json['route'] as List?) ?? const []).map(
          (e) => TrackPoint.fromJson(Map<String, dynamic>.from(e as Map)),
        ),
      );
    tracker._status = RunStatus.paused;
    tracker._segmentStartedAt = null;
    // Filter state intentionally left clear: the first fix after resuming
    // re-anchors, so distance travelled while the app was dead is not invented.
    tracker._clearFilterState();
    return tracker;
  }
}
