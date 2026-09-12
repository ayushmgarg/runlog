import 'models/location_sample.dart';

/// What is stopping us from tracking, if anything.
///
/// Modelled explicitly rather than as a bool so the UI can say something
/// actionable instead of a generic "location error".
enum LocationAvailability {
  /// Permission granted and location services on: ready to track.
  ready,

  /// The user has not been asked yet.
  notRequested,

  /// Denied this time; asking again is allowed.
  denied,

  /// Denied permanently. Only the system settings screen can undo this, so the
  /// UI has to offer that rather than re-prompting into a no-op.
  deniedForever,

  /// Permission is fine, but location services are switched off device-wide.
  serviceDisabled,
}

/// The single seam between the tracking engine and the platform.
///
/// Everything above this interface is pure Dart, which is what lets the whole
/// filter chain be tested against synthetic traces. Two implementations exist:
/// the real GPS one, and a replayable simulated one used by tests and by the
/// in-app demo mode.
abstract class LocationProvider {
  /// Current permission and service state, without prompting.
  Future<LocationAvailability> checkAvailability();

  /// Prompts if that can help. Returns the resulting state.
  Future<LocationAvailability> requestPermission();

  /// Opens the OS app-settings page, for the [LocationAvailability.deniedForever]
  /// dead end.
  Future<void> openAppSettings();

  /// Opens the OS location-services page, for
  /// [LocationAvailability.serviceDisabled].
  Future<void> openLocationSettings();

  /// A single fix, used to warm up the GPS on the idle screen so the run does
  /// not start blind. Null if none can be obtained.
  Future<LocationSample?> lastKnownOrCurrent();

  /// Continuous fixes while a run is active.
  ///
  /// Implementations are expected to keep this alive in the background (Android
  /// foreground service / iOS background location) and to emit raw, unfiltered
  /// samples: filtering is the engine's job, not the platform's.
  Stream<LocationSample> positionStream();

  /// Emits whenever the device's location services are switched on or off.
  ///
  /// Separate from [positionStream] because it answers a different question and
  /// stays valid when there is no run: the idle screen has to show whether
  /// location is usable *now*, not whether it was usable when the app started.
  Stream<bool> serviceEnabledStream();

  /// Releases platform resources. Called when a run ends or is paused.
  Future<void> dispose();
}
