import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../data/geolocator_location_provider.dart';
import '../data/run_repository.dart';
import '../data/simulated_location_provider.dart';
import '../domain/location_provider.dart';
import '../domain/models/location_sample.dart';
import '../domain/models/run_metrics.dart';
import '../domain/models/run_record.dart';
import '../domain/models/run_status.dart';
import '../domain/models/track_point.dart';
import '../domain/run_tracker.dart';

/// Everything the app knows, in one listenable object.
///
/// The app has exactly one piece of mutable state — the current run — with
/// exactly one owner, so a [ChangeNotifier] is the right size for it. A
/// state-management package here would add a dependency, a build step and a set
/// of rebuild-scope rules without removing a single line of real logic.
///
/// Responsibilities kept deliberately here rather than in [RunTracker]:
/// permissions, the position subscription, the repaint ticker, persistence and
/// app lifecycle. The tracker stays pure so it stays testable.
class RunController extends ChangeNotifier with WidgetsBindingObserver {
  RunController({RunRepository? repository, LocationProvider? provider})
    : _repository = repository ?? RunRepository(),
      _provider = provider ?? GeolocatorLocationProvider();

  final RunRepository _repository;
  LocationProvider _provider;

  RunTracker _tracker = RunTracker();
  StreamSubscription<LocationSample>? _positionSubscription;
  Timer? _ticker;
  Timer? _snapshotTimer;

  LocationAvailability _availability = LocationAvailability.notRequested;
  List<RunRecord> _history = const [];
  RunRecord? _lastFinishedRun;

  /// A run recovered from disk that the user has not yet dealt with.
  RunTracker? _recoveredRun;

  bool _simulationEnabled = false;
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
  bool get simulationEnabled => _simulationEnabled;
  bool get mapExpanded => _mapExpanded;
  bool get busy => _busy;
  String? get error => _error;

  bool get canStart =>
      _tracker.status == RunStatus.idle && !_busy && !hasRecoveredRun;

  // ------------------------------------------------------------------ setup

  Future<void> init() async {
    WidgetsBinding.instance.addObserver(this);
    _availability = await _provider.checkAvailability();
    _history = await _repository.loadRuns();
    await _restoreUnfinishedRun();
    notifyListeners();
  }

  /// Warms up the receiver on the idle screen so the first fix is not still
  /// arriving when the user taps Start.
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

  /// Swaps the real GPS for the scripted demo route (and back).
  ///
  /// Only offered while idle: changing the source of truth underneath a run in
  /// progress would produce a run that is half real and half fiction.
  Future<void> setSimulation(bool enabled) async {
    if (_simulationEnabled == enabled) return;
    if (_tracker.status.isInProgress) return;
    await _stopListening();
    await _provider.dispose();
    _simulationEnabled = enabled;
    _provider = enabled
        ? SimulatedLocationProvider()
        : GeolocatorLocationProvider();
    _availability = await _provider.checkAvailability();
    notifyListeners();
  }

  void setMapExpanded(bool expanded) {
    if (_mapExpanded == expanded) return;
    _mapExpanded = expanded;
    notifyListeners();
  }

  // ------------------------------------------------------------ run control

  /// Returns false if the run could not start, having set [error] to something
  /// the UI can show.
  Future<bool> startRun() async {
    if (!canStart) return false;
    _busy = true;
    _error = null;
    notifyListeners();

    try {
      _availability = await _provider.requestPermission();
      if (_availability != LocationAvailability.ready) {
        _error = _messageFor(_availability);
        return false;
      }

      _tracker = RunTracker();
      _tracker.start();
      await _startListening();
      _startTicker();
      await _enableWakelock(true);
      return true;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> pauseRun() async {
    if (_tracker.status != RunStatus.active) return;
    _tracker.pause();
    // The receiver is the most expensive thing running; a paused run has no use
    // for it, and dropping the subscription also guarantees no stray fix can be
    // recorded.
    await _stopListening();
    // Nothing changes while paused, so the repaint ticker and the snapshot
    // timer have nothing to do either. One final snapshot below covers the
    // paused state.
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

  /// Ends the run and saves it. Returns the stored record, or null when there
  /// was no run to finish.
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

  /// Clears the finished run so the app returns to a fresh idle screen.
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
      // A snapshot with nothing in it is noise from a crash on the start
      // screen, not a run worth asking the user about.
      if (restored.elapsed.inSeconds < 5 && restored.route.isEmpty) {
        await _repository.clearActiveRun();
        return;
      }
      _recoveredRun = restored;
    } catch (_) {
      await _repository.clearActiveRun();
    }
  }

  /// Picks the recovered run back up, paused, so the user decides when to run.
  Future<void> resumeRecoveredRun() async {
    final recovered = _recoveredRun;
    if (recovered == null) return;
    _tracker = recovered;
    _recoveredRun = null;
    notifyListeners();
    await resumeRun();
  }

  /// Keeps the recovered run as a finished activity without pretending the
  /// user kept running.
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
    await _positionSubscription?.cancel();
    _positionSubscription = _provider.positionStream().listen(
      (sample) {
        _tracker.addSample(sample);
        notifyListeners();
      },
      onError: (Object e) {
        // A stream error is a GPS-quality problem, not a reason to lose the
        // run: the badge already reports staleness, and duration keeps running.
        _error = 'Location error: $e';
        notifyListeners();
      },
      cancelOnError: false,
    );
  }

  Future<void> _stopListening() async {
    await _positionSubscription?.cancel();
    _positionSubscription = null;
  }

  /// 1 Hz repaint only. The displayed duration is computed from the wall clock,
  /// so a missed tick costs a frame, never a second.
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
    // Snapshot whenever the app leaves the foreground: that is the moment
    // before the OS is allowed to kill the process.
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
    _positionSubscription?.cancel();
    _provider.dispose();
    if (!kIsWeb) _enableWakelock(false);
    super.dispose();
  }
}
