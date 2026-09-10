/// Lifecycle of a single run. Transitions are enforced by `RunTracker`.
///
/// ```
/// idle --start--> active <--pause/resume--> paused
///                   \                        /
///                    \------ finish --------/
///                              |
///                          finished
/// ```
enum RunStatus { idle, active, paused, finished }

extension RunStatusX on RunStatus {
  bool get isActive => this == RunStatus.active;
  bool get isPaused => this == RunStatus.paused;
  bool get isFinished => this == RunStatus.finished;

  /// True once a run exists and has not been finished — i.e. the run screen
  /// should be showing and the run is worth recovering after a crash.
  bool get isInProgress => this == RunStatus.active || this == RunStatus.paused;
}

/// How much the distance/pace numbers can currently be trusted.
enum GpsQuality {
  /// No usable fix yet since the run started.
  acquiring,

  /// Fixes are arriving and passing the accuracy gate.
  good,

  /// Nothing usable recently — distance may be under-reporting.
  weak,
}
