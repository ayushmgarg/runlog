class TrackerConfig {
  const TrackerConfig({
    this.maxAccuracyMeters = 25,
    this.maxFirstFixAccuracyMeters = 50,
    this.minMovementMeters = 4,
    this.accuracyJitterFactor = 0.5,
    this.maxSpeedMetersPerSecond = 12,
    this.maxConsecutiveRejections = 3,
    this.smoothingAlpha = 0.3,
    this.signalGapThreshold = const Duration(seconds: 30),
    this.gpsStaleThreshold = const Duration(seconds: 10),
    this.paceWindow = const Duration(seconds: 10),
    this.minPaceWindow = const Duration(seconds: 5),
    this.minDistanceForAveragePaceMeters = 50,
    this.defaultStrideMeters = 0.75,
    this.minStrideMeters = 0.4,
    this.maxStrideMeters = 1.7,
    this.minCalibrationSteps = 100,
  });

  final double maxAccuracyMeters;
  final double maxFirstFixAccuracyMeters;
  final double minMovementMeters;
  final double accuracyJitterFactor;
  final double maxSpeedMetersPerSecond;
  final int maxConsecutiveRejections;
  final double smoothingAlpha;
  final Duration signalGapThreshold;
  final Duration gpsStaleThreshold;
  final Duration paceWindow;
  final Duration minPaceWindow;
  final double minDistanceForAveragePaceMeters;
  final double defaultStrideMeters;
  final double minStrideMeters;
  final double maxStrideMeters;
  final int minCalibrationSteps;
}
