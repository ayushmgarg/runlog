import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../data/geolocator_location_provider.dart';
import '../data/pedometer_step_provider.dart';
import '../data/run_repository.dart';
import '../domain/location_provider.dart';
import '../domain/models/location_sample.dart';
import '../domain/models/run_metrics.dart';
import '../domain/models/run_record.dart';
import '../domain/models/run_status.dart';
import '../domain/models/track_point.dart';
import '../domain/run_tracker.dart';
import '../domain/step_provider.dart';

class RunController extends ChangeNotifier with WidgetsBindingObserver {
  RunController({
    RunRepository? repository,
    LocationProvider? provider,
    StepProvider? stepProvider,
  }) : _repository = repository ?? RunRepository(),
       _provider = provider ?? GeolocatorLocationProvider(),
       _stepProvider = stepProvider ?? PedometerStepProvider();

  final RunRepository _repository;
  final LocationProvider _provider;
  final StepProvider _stepProvider;
  RunTracker _tracker = RunTracker();
  StreamSubscription<LocationSample>? _positionSubscription;
  StreamSubscription<StepSample>? _stepSubscription;
  StreamSubscription<bool>? _serviceSubscription;
  Timer? _ticker;
  Timer? _snapshotTimer;
  Timer? _resubscribeTimer;
  bool _locationInterrupted = false;
  LocationAvailability _availability = LocationAvailability.notRequested;
  List<RunRecord> _history = const [];
  RunRecord? _lastFinishedRun;
  RunTracker? _recoveredRun;
  bool _stepFallbackAvailable = false;
  bool _mapExpanded = false;
  bool _busy = false;
  String? _error;

  // ------------------------------------------------------------------ state

  RunMetrics get metrics => _tracker.metrics;
  RunStatus get status => _tracker.status;
  List<TrackPoint> get route => _tracker.route;
  LocationAvailability get availability => _availability;
  List<RunRecord> get history => _history;
  RunRecord? get lastFinishedRun => _lastFinishedRun;
  RunTracker? get recoveredRun => _recoveredRun;
  bool get hasRecoveredRun => _recoveredRun != null;
  bool get stepFallbackAvailable => _stepFallbackAvailable;
  bool get mapExpanded => _mapExpanded;
  bool get busy => _busy;
  String? get error => _error;

  bool get locationInterrupted =>
      _locationInterrupted && _tracker.status.isInProgress;

  bool get canStart =>
      _tracker.status == RunStatus.idle && !_busy && !hasRecoveredRun;

  // ------------------------------------------------------------------ setup

  Future<void> init() async {
    WidgetsBinding.instance.addObserver(this);
    _availability = await _provider.checkAvailability();
    _watchServiceStatus();
    _stepFallbackAvailable = await _stepProvider.isAvailable();
    _history = await _repository.loadRuns();
    await _restoreUnfinishedRun();
    notifyListeners();
  }

  void _watchServiceStatus() {
    _serviceSubscription?.cancel();
    _serviceSubscription = _provider.serviceEnabledStream().listen(
      (enabled) async {
        if (!enabled) {
          _availability = LocationAvailability.serviceDisabled;
          if (_tracker.status.isActive) _onLocationLost();
          notifyListeners();
          return;
        }

        _availability = await _provider.checkAvailability();
        // Location is back on: re-open now rather than waiting out the retry.
        if (_tracker.status.isActive) {
          _resubscribeTimer?.cancel();
          _locationInterrupted = false;
          _tracker.setLocationUnavailable(false);
          await _startLocationStream();
        }
        notifyListeners();
      },
      onError: (Object _) {},
      cancelOnError: false,
    );
  }

  Future<void> warmUpGps() async {
    if (_availability != LocationAvailability.ready) return;
    await _provider.lastKnownOrCurrent();
  }

  Future<void> refreshAvailability() async {
    _availability = await _provider.checkAvailability();
    notifyListeners();
  }

  Future<void> requestPermission() async {
    _availability = await _provider.requestPermission();
    notifyListeners();
  }

  Future<void> openAppSettings() => _provider.openAppSettings();
  Future<void> openLocationSettings() => _provider.openLocationSettings();

  void setMapExpanded(bool expanded) {
    if (_mapExpanded == expanded) return;
    _mapExpanded = expanded;
    notifyListeners();
  }

  // ------------------------------------------------------------ run control

  Future<bool> startRun({bool requireLocation = true}) async {
    if (!canStart) return false;
    _busy = true;
    _error = null;
    notifyListeners();

    try {
      if (requireLocation) {
        _availability = await _provider.requestPermission();
        if (_availability != LocationAvailability.ready) {
          _error = _messageFor(_availability);
          return false;
        }
      }

      _stepFallbackAvailable = await _stepProvider.requestPermission();
      _locationInterrupted = !requireLocation;
      _tracker = RunTracker();
      _tracker.start();
      if (!requireLocation) _tracker.setLocationUnavailable(true);
      await _startListening();
      if (requireLocation) await _seedFromLastKnown();
      _startTicker();
      await _enableWakelock(true);
      return true;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<bool> startWithoutLocation() => startRun(requireLocation: false);

  Future<void> _seedFromLastKnown() async {
    try {
      final cached = await _provider.lastKnownOrCurrent();
      if (cached == null) return;
      if (DateTime.now().difference(cached.timestamp).inSeconds > 60) return;
      _tracker.addSample(cached);
      notifyListeners();
    } catch (_) {
      // Best effort only: the live stream is the real source.
    }
  }

  Future<void> pauseRun() async {
    if (_tracker.status != RunStatus.active) return;
    _tracker.pause();
    await _stopListening();
    _stopTicker();
    await _enableWakelock(false);
    await _saveSnapshot();
    notifyListeners();
  }

  Future<void> resumeRun() async {
    if (_tracker.status != RunStatus.paused) return;
    _tracker.resume();
    await _startListening();
    _startTicker();
    await _enableWakelock(true);
    notifyListeners();
  }

  Future<RunRecord?> finishRun() async {
    if (!_tracker.status.isInProgress) return null;
    _tracker.finish();
    await _stopListening();
    _stopTicker();
    await _enableWakelock(false);
    final startedAt = _tracker.startedAt ?? DateTime.now();
    final record = RunRecord.fromRun(
      startedAt: startedAt,
      endedAt: DateTime.now(),
      metrics: _tracker.metrics,
      route: _tracker.route,
    );

    await _repository.saveRun(record);
    await _repository.clearActiveRun();
    _history = await _repository.loadRuns();
    _lastFinishedRun = record;
    _recoveredRun = null;
    notifyListeners();
    return record;
  }

  void dismissFinishedRun() {
    _tracker.reset();
    _lastFinishedRun = null;
    notifyListeners();
  }

  Future<void> deleteRun(String id) async {
    await _repository.deleteRun(id);
    _history = await _repository.loadRuns();
    if (_lastFinishedRun?.id == id) _lastFinishedRun = null;
    notifyListeners();
  }

  // ----------------------------------------------------------- recovery flow

  Future<void> _restoreUnfinishedRun() async {
    final snapshot = await _repository.loadActiveRun();
    if (snapshot == null) return;
    try {
      final restored = RunTracker.fromSnapshot(snapshot);
      if (restored.elapsed.inSeconds < 5 && restored.route.isEmpty) {
        await _repository.clearActiveRun();
        return;
      }
      _recoveredRun = restored;
    } catch (_) {
      await _repository.clearActiveRun();
    }
  }

  Future<void> resumeRecoveredRun() async {
    final recovered = _recoveredRun;
    if (recovered == null) return;
    _tracker = recovered;
    _recoveredRun = null;
    notifyListeners();
    await resumeRun();
  }

  Future<RunRecord?> saveRecoveredRun() async {
    final recovered = _recoveredRun;
    if (recovered == null) return null;
    _tracker = recovered;
    _recoveredRun = null;
    return finishRun();
  }

  Future<void> discardRecoveredRun() async {
    _recoveredRun = null;
    await _repository.clearActiveRun();
    notifyListeners();
  }

  // ------------------------------------------------------------- plumbing

  Future<void> _startListening() async {
    await _startLocationStream();
    await _startStepStream();
  }

  Future<void> _startLocationStream() async {
    _resubscribeTimer?.cancel();
    await _positionSubscription?.cancel();
    _positionSubscription = _provider.positionStream().listen(
      (sample) {
        // Fixes are flowing again, so whatever was wrong no longer is.
        if (_locationInterrupted) {
          _locationInterrupted = false;
          _tracker.setLocationUnavailable(false);
        }
        _tracker.addSample(sample);
        notifyListeners();
      },
      onError: (Object _) {
        _onLocationLost();
      },
      onDone: _onLocationLost,
      cancelOnError: false,
    );
  }

  Future<void> _startStepStream() async {
    if (!_stepFallbackAvailable) return;
    if (_stepSubscription != null) return;
    _stepSubscription = _stepProvider.stepStream().listen(
      (sample) {
        _tracker.addStepSample(sample);
        notifyListeners();
      },
      onError: (Object _) {},
      cancelOnError: false,
    );
  }

  void _onLocationLost() {
    _locationInterrupted = true;
    _tracker.setLocationUnavailable(true);
    notifyListeners();
    _scheduleResubscribe();
  }

  void _scheduleResubscribe() {
    if (!_tracker.status.isActive) return;
    if (_resubscribeTimer?.isActive ?? false) return;
    _resubscribeTimer = Timer(const Duration(seconds: 5), () {
      if (!_tracker.status.isActive) return;
      _startLocationStream();
    });
  }

  Future<void> _stopListening() async {
    _resubscribeTimer?.cancel();
    _resubscribeTimer = null;
    await _positionSubscription?.cancel();
    _positionSubscription = null;
    await _stepSubscription?.cancel();
    _stepSubscription = null;
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      notifyListeners();
    });
    _snapshotTimer?.cancel();
    _snapshotTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _saveSnapshot(),
    );
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
    _snapshotTimer?.cancel();
    _snapshotTimer = null;
  }

  Future<void> _saveSnapshot() async {
    if (!_tracker.status.isInProgress) return;
    try {
      await _repository.saveActiveRun(_tracker.toSnapshot());
    } catch (_) {
      // Losing one snapshot is survivable; the next one is five seconds away.
    }
  }

  Future<void> _enableWakelock(bool enable) async {
    try {
      await WakelockPlus.toggle(enable: enable);
    } catch (_) {
      // Unsupported on some platforms (and in tests). Never worth failing a run.
    }
  }

  static String _messageFor(LocationAvailability availability) {
    switch (availability) {
      case LocationAvailability.ready:
        return '';
      case LocationAvailability.notRequested:
      case LocationAvailability.denied:
        return 'RUN needs location access to measure your run.';
      case LocationAvailability.deniedForever:
        return 'Location access is blocked. Enable it in system settings to track a run.';
      case LocationAvailability.serviceDisabled:
        return 'Location services are switched off on this device.';
    }
  }

  void clearError() {
    if (_error == null) return;
    _error = null;
    notifyListeners();
  }

  // ------------------------------------------------------------- lifecycle

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      _saveSnapshot();
    }
    if (state == AppLifecycleState.resumed) {
      refreshAvailability();
      notifyListeners();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopTicker();
    _resubscribeTimer?.cancel();
    _serviceSubscription?.cancel();
    _positionSubscription?.cancel();
    _stepSubscription?.cancel();
    _provider.dispose();
    _stepProvider.dispose();
    if (!kIsWeb) _enableWakelock(false);
    super.dispose();
  }
}
