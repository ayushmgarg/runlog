import 'dart:async';
import 'package:geolocator/geolocator.dart';
import '../domain/location_provider.dart';
import '../domain/models/location_sample.dart';

class GeolocatorLocationProvider implements LocationProvider {
  StreamSubscription<Position>? _subscription;
  StreamController<LocationSample>? _controller;

  static AndroidSettings get _androidSettings => AndroidSettings(
    accuracy: LocationAccuracy.bestForNavigation,
    distanceFilter: 0,
    intervalDuration: const Duration(seconds: 1),
    foregroundNotificationConfig: const ForegroundNotificationConfig(
      notificationTitle: 'RunLog is tracking your run',
      notificationText: 'Distance, time and route are being recorded.',
      notificationChannelName: 'Run tracking',
      enableWakeLock: true,
      setOngoing: true,
    ),
  );

  static AppleSettings get _appleSettings => AppleSettings(
    accuracy: LocationAccuracy.bestForNavigation,
    distanceFilter: 0,
    activityType: ActivityType.fitness,
    pauseLocationUpdatesAutomatically: false,
    allowBackgroundLocationUpdates: true,
    showBackgroundLocationIndicator: true,
  );

  static LocationSettings get _settings {
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
    _controller?.close();
    final controller = StreamController<LocationSample>.broadcast();
    _controller = controller;
    _subscription?.cancel();
    _subscription = Geolocator.getPositionStream(locationSettings: _settings)
        .listen(
          (position) => controller.add(_toSample(position)),
          onError: controller.addError,
          cancelOnError: false,
        );

    return controller.stream;
  }

  @override
  Stream<bool> serviceEnabledStream() => Geolocator.getServiceStatusStream()
      .map((status) => status == ServiceStatus.enabled)
      .handleError((Object _) {});

  static LocationSample _toSample(Position position) => LocationSample(
    latitude: position.latitude,
    longitude: position.longitude,
    accuracy: position.accuracy,
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
