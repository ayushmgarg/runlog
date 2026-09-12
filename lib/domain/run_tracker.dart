import 'dart:math' as math;
import 'geo.dart';
import 'models/location_sample.dart';
import 'models/run_metrics.dart';
import 'models/run_status.dart';
import 'models/track_point.dart';
import 'step_provider.dart';
import 'tracker_config.dart';

typedef Clock = DateTime Function();

enum SampleOutcome {
  accepted,
  stationary,
  gapReanchor,
  anchored,
  rejectedAccuracy,
  rejectedOutOfOrder,
  rejectedImplausibleSpeed,
  ignoredNotActive,
}

class _DistanceMark {
  const _DistanceMark(this.at, this.cumulativeMeters, this.segment);
  final DateTime at;
  final double cumulativeMeters;
  final int segment;
}

class RunTracker {
  RunTracker({TrackerConfig? config, Clock? clock})
    : config = config ?? const TrackerConfig(),
      _clock = clock ?? DateTime.now;

  final TrackerConfig config;
  final Clock _clock;
  RunStatus _status = RunStatus.idle;
  DateTime? _startedAt;
  Duration _completed = Duration.zero;
  DateTime? _segmentStartedAt;
  Duration _elapsedFloor = Duration.zero;
  final List<TrackPoint> _route = <TrackPoint>[];
  double _distanceMeters = 0;
  int _segment = 0;
  TrackPoint? _anchor;
  LocationSample? _lastFix;
  double? _smoothLat;
  double? _smoothLon;
  int _consecutiveRejections = 0;
  bool _locationUnavailable = false;
  final List<_DistanceMark> _marks = <_DistanceMark>[];
  StepSample? _lastStep;
  DateTime? _lastStepAt;
  double _stepMeters = 0;
  int _calibrationSteps = 0;
  double _calibrationMeters = 0;
  double _calibrationCursor = 0;

  // ----------------------------------------------------------------- getters

  RunStatus get status => _status;
  DateTime? get startedAt => _startedAt;
  double get distanceMeters => _distanceMeters;
  List<TrackPoint> get route => List.unmodifiable(_route);
  int get segmentCount => _route.isEmpty ? 0 : _route.last.segment + 1;
  double get stepMeters => _stepMeters;

  double get strideMeters {
    if (_calibrationSteps < config.minCalibrationSteps) {
      return config.defaultStrideMeters;
    }
    final measured = _calibrationMeters / _calibrationSteps;
    return measured.clamp(config.minStrideMeters, config.maxStrideMeters);
  }

  bool get isEstimatingFromSteps {
    if (!_status.isActive) return false;
    if (gpsQuality == GpsQuality.good) return false;
    return _stepsAreLive(_clock());
  }

  bool _stepsAreLive(DateTime now) {
    final last = _lastStepAt;
    return last != null && now.difference(last) <= config.gpsStaleThreshold;
  }

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
    if (_locationUnavailable) return GpsQuality.weak;
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

  double? _currentSpeedMps() {
    if (_status != RunStatus.active) return null;
    if (_marks.isEmpty) return null;
    final now = _clock();
    if (gpsQuality != GpsQuality.good && !_stepsAreLive(now)) return null;
    final windowStart = now.subtract(config.paceWindow);
    final segment = _marks.last.segment;
    var index = _marks.length - 1;
    while (index > 0 &&
        _marks[index - 1].segment == segment &&
        _marks[index - 1].at.isAfter(windowStart)) {
      index--;
    }
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

  void setLocationUnavailable(bool unavailable) {
    _locationUnavailable = unavailable;
  }

  double addStepSample(StepSample sample) {
    if (_status != RunStatus.active) return 0;
    final previous = _lastStep;
    _lastStep = sample;

    if (previous == null || sample.cumulativeSteps < previous.cumulativeSteps) {
      return 0;
    }

    final steps = sample.cumulativeSteps - previous.cumulativeSteps;
    if (steps <= 0) return 0;
    _lastStepAt = sample.timestamp;
    final gpsMeters = _distanceMeters - _stepMeters;

    if (gpsQuality == GpsQuality.good) {
      _calibrationSteps += steps;
      _calibrationMeters += gpsMeters - _calibrationCursor;
      _calibrationCursor = gpsMeters;
      return 0;
    }

    _calibrationCursor = gpsMeters;
    final metres = steps * strideMeters;
    _distanceMeters += metres;
    _stepMeters += metres;
    _mark(sample.timestamp);
    return metres;
  }

  // ----------------------------------------------------------- state machine

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

  void pause() {
    if (_status != RunStatus.active) return;
    _bankSegment();
    _status = RunStatus.paused;
    _clearFilterState();
  }

  void resume() {
    if (_status != RunStatus.paused) return;
    _status = RunStatus.active;
    final now = _clock();
    _segmentStartedAt = now;
    _segment++;
    _mark(now);
  }

  void finish() {
    if (!_status.isInProgress) return;
    if (_status == RunStatus.active) _bankSegment();
    _status = RunStatus.finished;
    _clearFilterState();
  }

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

  void _clearFilterState() {
    _anchor = null;
    _lastFix = null;
    _smoothLat = null;
    _smoothLon = null;
    _consecutiveRejections = 0;
    _locationUnavailable = false;
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

  SampleOutcome addSample(LocationSample sample) {
    if (_status != RunStatus.active) return SampleOutcome.ignoredNotActive;

    // A fix arriving is proof the source is back, whatever we were told.
    _locationUnavailable = false;
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

      if (gap > config.signalGapThreshold) {
        _reanchor(sample);
        return SampleOutcome.gapReanchor;
      }

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

    final floor = math.max(
      config.minMovementMeters,
      sample.accuracy * config.accuracyJitterFactor,
    );
    if (metres < floor) return SampleOutcome.stationary;
    _distanceMeters += metres;
    _anchor = _appendPoint(position, _distanceMeters);
    return SampleOutcome.accepted;
  }

  void _reanchor(LocationSample sample) {
    _segment++;
    _consecutiveRejections = 0;
    _lastFix = sample;
    _smoothLat = null;
    _smoothLon = null;
    _anchor = _appendPoint(_smooth(sample), _distanceMeters);
  }

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

  Map<String, dynamic> toSnapshot() => {
    'version': 1,
    'status': _status.name,
    'startedAt': _startedAt?.millisecondsSinceEpoch,
    'elapsedMs': elapsed.inMilliseconds,
    'distance': _distanceMeters,
    'segment': _segment,
    'route': _route.map((p) => p.toJson()).toList(),
  };

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
    tracker._clearFilterState();
    return tracker;
  }
}
