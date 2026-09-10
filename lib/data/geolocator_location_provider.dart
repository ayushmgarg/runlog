import 'dart:async';

import 'package:geolocator/geolocator.dart';

import '../domain/location_provider.dart';
import '../domain/models/location_sample.dart';

/// The real GPS, behind the [LocationProvider] seam.
///
/// This class does no filtering. Every fix the platform produces is passed
/// straight through, because deciding what to believe is the tracking engine's
/// job and needs to stay testable. The only tuning here is what we ask the OS
/// for.
class GeolocatorLocationProvider implements LocationProvider {
  StreamSubscription<Position>? _subscription;
  StreamController<LocationSample>? _controller;

  /// What we ask Android for.
  ///
  /// `distanceFilter: 0` and a 1 s interval deliberately: a platform-side
  /// distance filter would suppress the very fixes the engine needs to tell
  /// "standing still" from "no signal", and it cannot be un-done downstream.
  /// The foreground notification is what keeps the stream alive once the screen
  /// locks mid-run.
  static AndroidSettings get _androidSettings => AndroidSettings(
    accuracy: LocationAccuracy.bestForNavigation,
    distanceFilter: 0,
    intervalDuration: const Duration(seconds: 1),
    foregroundNotificationConfig: const ForegroundNotificationConfig(
      notificationTitle: 'RUN is tracking your run',
      notificationText: 'Distance, time and route are being recorded.',
      notificationChannelName: 'Run tracking',
      enableWakeLock: true,
      setOngoing: true,
    ),
  );

  /// `activityType: fitness` tells iOS what kind of movement to expect, and
  /// `pauseLocationUpdatesAutomatically: false` stops the OS from helpfully
  /// pausing a run we were asked to record.
  static AppleSettings get _appleSettings => AppleSettings(
    accuracy: LocationAccuracy.bestForNavigation,
    distanceFilter: 0,
    activityType: ActivityType.fitness,
    pauseLocationUpdatesAutomatically: false,
    allowBackgroundLocationUpdates: true,
    showBackgroundLocationIndicator: true,
  );

  static LocationSettings get _settings {
    // Platform detection via the plugin rather than dart:io, so this file stays
    // usable in tests on the VM.
    if (GeolocatorPlatform.instance.runtimeType.toString().contains('Apple')) {
      return _appleSettings;
    }
    return _androidSettings;
  }

  @override
  Future<LocationAvailability> checkAvailability() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return LocationAvailability.serviceDisabled;
    }
    return _mapPermission(await Geolocator.checkPermission());
  }

  @override
  Future<LocationAvailability> requestPermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return LocationAvailability.serviceDisabled;
    }
    final current = await Geolocator.checkPermission();
    // Asking again after a permanent denial is a silent no-op on Android, which
    // looks like a broken button. Report it so the UI can offer settings.
    if (current == LocationPermission.deniedForever) {
      return LocationAvailability.deniedForever;
    }
    return _mapPermission(await Geolocator.requestPermission());
  }

  static LocationAvailability _mapPermission(LocationPermission permission) {
    switch (permission) {
      case LocationPermission.always:
      case LocationPermission.whileInUse:
        return LocationAvailability.ready;
      case LocationPermission.denied:
        return LocationAvailability.denied;
      case LocationPermission.deniedForever:
        return LocationAvailability.deniedForever;
      case LocationPermission.unableToDetermine:
        return LocationAvailability.notRequested;
    }
  }

  @override
  Future<void> openAppSettings() => Geolocator.openAppSettings();

  @override
  Future<void> openLocationSettings() => Geolocator.openLocationSettings();

  @override
  Future<LocationSample?> lastKnownOrCurrent() async {
    try {
      final cached = await Geolocator.getLastKnownPosition();
      if (cached != null) return _toSample(cached);
    } catch (_) {
      // A missing cached fix is normal, not an error worth surfacing.
    }
    try {
      final current = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 10),
        ),
      );
      return _toSample(current);
    } on TimeoutException {
      return null;
    } catch (_) {
      return null;
    }
  }

  @override
  Stream<LocationSample> positionStream() {
    // One broadcast controller wrapping the platform stream, so a dropped
    // subscription (pause) can be re-established without leaking the old one.
    _controller?.close();
    final controller = StreamController<LocationSample>.broadcast();
    _controller = controller;

    _subscription?.cancel();
    _subscription =
        Geolocator.getPositionStream(locationSettings: _settings).listen(
          (position) => controller.add(_toSample(position)),
          onError: controller.addError,
          cancelOnError: false,
        );

    return controller.stream;
  }

  static LocationSample _toSample(Position position) => LocationSample(
    latitude: position.latitude,
    longitude: position.longitude,
    accuracy: position.accuracy,
    // Some devices report a null-ish or clearly bogus fix timestamp; falling
    // back to now keeps the engine's ordering rules working either way.
    timestamp: position.timestamp.isBefore(DateTime(2000))
        ? DateTime.now()
        : position.timestamp.toLocal(),
  );

  @override
  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
    await _controller?.close();
    _controller = null;
  }
}
