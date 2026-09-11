import 'dart:math' as math;

import 'geo.dart';
import 'models/location_sample.dart';
import 'models/run_metrics.dart';
import 'models/run_status.dart';
import 'models/track_point.dart';
import 'step_provider.dart';
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

/// A point on the distance timeline: how far the run had gone, and when.
///
/// Kept separate from the route because distance can advance without a
/// position — when GPS is unavailable, the step counter still moves it. Live
/// pace and speed are derived from this timeline rather than from the route,
/// so they keep working through a signal blackout.
class _DistanceMark {
  const _DistanceMark(this.at, this.cumulativeMeters, this.segment);

  final DateTime at;
  final double cumulativeMeters;
  final int segment;
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

  /// Distance over time, from whichever source produced it. Pruned to a little
  /// more than the pace window, so it stays O(window) however long the run is.
  final List<_DistanceMark> _marks = <_DistanceMark>[];

  /// Last raw pedometer reading, so deltas can be taken.
  StepSample? _lastStep;

  /// When a step was last counted, used to tell "no pedometer data" from
  /// "standing still".
  DateTime? _lastStepAt;

  /// Metres of this run credited to the step counter rather than to GPS.
  double _stepMeters = 0;

  /// Steps, and the GPS metres measured over the *same* intervals, while the
  /// signal was good. Their ratio is this runner's stride.
  int _calibrationSteps = 0;
  double _calibrationMeters = 0;

  /// GPS metres at the previous calibration sample. Only the distance between
  /// consecutive step readings may be paired with the steps between them —
  /// crediting the whole run's GPS distance against a handful of steps would
  /// produce an absurd stride.
  double _calibrationCursor = 0;

  // ----------------------------------------------------------------- getters

  RunStatus get status => _status;
  DateTime? get startedAt => _startedAt;
  double get distanceMeters => _distanceMeters;
  List<TrackPoint> get route => List.unmodifiable(_route);
  int get segmentCount => _route.isEmpty ? 0 : _route.last.segment + 1;

  /// Metres of this run that came from the step counter, not from GPS.
  double get stepMeters => _stepMeters;

  /// The stride used to convert steps into distance.
  ///
  /// Measured against GPS whenever the signal is good, so the fallback gets
  /// more accurate the longer the run goes before the signal drops. Falls back
  /// to a population average until there is enough evidence, and is clamped so
  /// a polluted sample cannot produce a nonsense stride.
  double get strideMeters {
    if (_calibrationSteps < config.minCalibrationSteps) {
      return config.defaultStrideMeters;
    }
    final measured = _calibrationMeters / _calibrationSteps;
    return measured.clamp(config.minStrideMeters, config.maxStrideMeters);
  }

  /// True when distance is currently being estimated from steps because GPS is
  /// not usable. Surfaced in the UI: an estimate should not look like a
  /// measurement.
  bool get isEstimatingFromSteps {
    if (!_status.isActive) return false;
    if (gpsQuality == GpsQuality.good) return false;
    return _stepsAreLive(_clock());
  }

  bool _stepsAreLive(DateTime now) {
    final last = _lastStepAt;
    return last != null &&
        now.difference(last) <= config.gpsStaleThreshold;
  }

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
    isEstimatingFromSteps: isEstimatingFromSteps,
  );

  /// Rolling-window speed in m/s, or null when it cannot be known.
  ///
  /// Computed from the distance timeline rather than from the route, so it
  /// survives a GPS blackout on step data alone. The window *ends at now*, not
  /// at the last recorded mark, so stopping decays the reading toward zero
  /// instead of freezing it at the last running speed. The GPS chip's own
  /// speed field is ignored: it is inconsistent across devices and absent from
  /// synthetic traces.
  double? _currentSpeedMps() {
    if (_status != RunStatus.active) return null;
    if (_marks.isEmpty) return null;

    final now = _clock();
    // Nothing is reporting movement: say so, rather than showing a stale
    // number or a zero that claims the runner has stopped.
    if (gpsQuality != GpsQuality.good && !_stepsAreLive(now)) return null;

    final windowStart = now.subtract(config.paceWindow);
    final segment = _marks.last.segment;

    // Walk back through the current segment only. Marks from before a pause
    // must never enter the window, or resuming would show the pace the runner
    // had when they stopped rather than the one they just set off at.
    var index = _marks.length - 1;
    while (index > 0 &&
        _marks[index - 1].segment == segment &&
        _marks[index - 1].at.isAfter(windowStart)) {
      index--;
    }
    // Include the mark just before the window so the metres covered at its
    // start are attributed, as long as it belongs to this segment.
    if (index > 0 && _marks[index - 1].segment == segment) index--;

    final first = _marks[index];
    if (first.segment != segment) return null;

    final windowSeconds = now.difference(first.at).inMilliseconds / 1000.0;
    if (windowSeconds < config.minPaceWindow.inMilliseconds / 1000.0) {
      return null;
    }

    final metres = _marks.last.cumulativeMeters - first.cumulativeMeters;
    return math.max(0.0, metres / windowSeconds);
  }

  /// Records where the run had got to at [at], and drops marks that have aged
  /// out of the pace window so this list cannot grow with the run.
  void _mark(DateTime at) {
    _marks.add(_DistanceMark(at, _distanceMeters, _segment));

    final cutoff = at.subtract(config.paceWindow * 3);
    var drop = 0;
    // Keep one mark older than the window: it is the window's start point.
    while (drop + 1 < _marks.length && _marks[drop + 1].at.isBefore(cutoff)) {
      drop++;
    }
    if (drop > 0) _marks.removeRange(0, drop);
  }

  // ------------------------------------------------------------ step counter

  /// Feeds one pedometer reading.
  ///
  /// Steps are the fallback, never the primary source: while GPS is good they
  /// only calibrate the stride length, and the distance they would imply is
  /// discarded. The moment GPS stops being usable they take over, which is what
  /// keeps distance and pace alive in a tunnel, indoors, or with location
  /// switched off entirely.
  ///
  /// Returns the metres credited by this sample, which is zero whenever GPS is
  /// doing the measuring.
  double addStepSample(StepSample sample) {
    if (_status != RunStatus.active) return 0;

    final previous = _lastStep;
    _lastStep = sample;

    // First reading of the run, or a counter that went backwards because the
    // device rebooted: take it as the new baseline and credit nothing.
    if (previous == null || sample.cumulativeSteps < previous.cumulativeSteps) {
      return 0;
    }

    final steps = sample.cumulativeSteps - previous.cumulativeSteps;
    if (steps <= 0) return 0;
    _lastStepAt = sample.timestamp;

    final gpsMeters = _distanceMeters - _stepMeters;

    if (gpsQuality == GpsQuality.good) {
      // GPS is measuring; these steps only teach us this runner's stride.
      // Pair them with the GPS distance covered since the previous reading.
      _calibrationSteps += steps;
      _calibrationMeters += gpsMeters - _calibrationCursor;
      _calibrationCursor = gpsMeters;
      return 0;
    }

    // GPS is not usable. Skip the cursor past this stretch so the distance
    // estimated here is never later paired with steps as if GPS had measured it.
    _calibrationCursor = gpsMeters;

    final metres = steps * strideMeters;
    _distanceMeters += metres;
    _stepMeters += metres;
    _mark(sample.timestamp);
    return metres;
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
    _marks.clear();
    _resetStepState();
    _clearFilterState();
    _mark(now);
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
    final now = _clock();
    _segmentStartedAt = now;
    _segment++;
    // Seed the new segment so live pace starts from this moment. Without it
    // the first seconds after resuming would report the pace the runner had
    // when they stopped.
    _mark(now);
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
    _marks.clear();
    _distanceMeters = 0;
    _segment = 0;
    _resetStepState();
    _clearFilterState();
  }

  void _resetStepState() {
    _lastStep = null;
    _lastStepAt = null;
    _stepMeters = 0;
    _calibrationSteps = 0;
    _calibrationMeters = 0;
    _calibrationCursor = 0;
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
    // Step deltas must not span a discontinuity: the next reading re-baselines.
    _lastStep = null;
    _calibrationCursor = _distanceMeters - _stepMeters;
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
    _mark(sample.timestamp);
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
