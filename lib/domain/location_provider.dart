import 'models/location_sample.dart';

enum LocationAvailability {
  ready,
  notRequested,
  denied,
  deniedForever,
  serviceDisabled,
}

abstract class LocationProvider {
  Future<LocationAvailability> checkAvailability();
  Future<LocationAvailability> requestPermission();
  Future<void> openAppSettings();
  Future<void> openLocationSettings();
  Future<LocationSample?> lastKnownOrCurrent();
  Stream<LocationSample> positionStream();
  Stream<bool> serviceEnabledStream();
  Future<void> dispose();
}
