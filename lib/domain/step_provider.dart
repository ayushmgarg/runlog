class StepSample {
  const StepSample({required this.cumulativeSteps, required this.timestamp});

  final int cumulativeSteps;
  final DateTime timestamp;

  @override
  String toString() => 'StepSample($cumulativeSteps steps at $timestamp)';
}

abstract class StepProvider {
  Future<bool> isAvailable();
  Future<bool> requestPermission();
  Stream<StepSample> stepStream();
  Future<void> dispose();
}
