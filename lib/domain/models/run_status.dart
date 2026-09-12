enum RunStatus { idle, active, paused, finished }

extension RunStatusX on RunStatus {
  bool get isActive => this == RunStatus.active;
  bool get isPaused => this == RunStatus.paused;
  bool get isFinished => this == RunStatus.finished;
  bool get isInProgress => this == RunStatus.active || this == RunStatus.paused;
}

enum GpsQuality { acquiring, good, weak }
