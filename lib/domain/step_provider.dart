/// A reading from the device's hardware step counter.
///
/// [cumulativeSteps] counts from device boot, not from the start of the run,
/// which is what the underlying Android and iOS sensors report. The engine
/// takes differences, so it never has to care where the count started — and a
/// counter that resets (a reboot mid-run) shows up as a negative delta and is
/// re-baselined rather than trusted.
class StepSample {
  const StepSample({required this.cumulativeSteps, required this.timestamp});

  final int cumulativeSteps;
  final DateTime timestamp;

  @override
  String toString() => 'StepSample($cumulativeSteps steps at $timestamp)';
}

/// The seam between the engine and the pedometer, mirroring
/// `LocationProvider` so the fallback can be tested with synthetic step data.
abstract class StepProvider {
  /// Whether this device exposes a usable step counter, and whether we are
  /// allowed to read it. False is a normal answer, not an error: plenty of
  /// devices have no step sensor, and the app simply goes without.
  Future<bool> isAvailable();

  /// Asks for activity-recognition permission if the platform needs it.
  /// Returns whether stepping data can now be read.
  Future<bool> requestPermission();

  /// Cumulative step counts as the user moves.
  Stream<StepSample> stepStream();

  Future<void> dispose();
}
