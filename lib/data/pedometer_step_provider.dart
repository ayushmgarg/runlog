import 'dart:async';
import 'dart:io';

import 'package:pedometer/pedometer.dart';
import 'package:permission_handler/permission_handler.dart';

import '../domain/step_provider.dart';

/// The device's hardware step counter, behind the [StepProvider] seam.
///
/// This is a *fallback* source, so every failure path here is a soft one: a
/// phone with no step sensor, or a user who declines activity recognition,
/// simply gets a run measured by GPS alone. Nothing about it is worth
/// interrupting a run for.
class PedometerStepProvider implements StepProvider {
  StreamSubscription<StepCount>? _subscription;
  StreamController<StepSample>? _controller;

  @override
  Future<bool> isAvailable() async {
    // The sensor exists on essentially every modern phone; what varies is
    // whether we are allowed to read it.
    if (!Platform.isAndroid && !Platform.isIOS) return false;
    final status = await Permission.activityRecognition.status;
    return status.isGranted;
  }

  @override
  Future<bool> requestPermission() async {
    if (!Platform.isAndroid && !Platform.isIOS) return false;
    try {
      final status = await Permission.activityRecognition.request();
      return status.isGranted;
    } catch (_) {
      return false;
    }
  }

  @override
  Stream<StepSample> stepStream() {
    _controller?.close();
    final controller = StreamController<StepSample>.broadcast();
    _controller = controller;

    _subscription?.cancel();
    _subscription = Pedometer.stepCountStream.listen(
      (count) => controller.add(
        StepSample(
          cumulativeSteps: count.steps,
          timestamp: count.timeStamp,
        ),
      ),
      // A device without the sensor errors the stream immediately. That is a
      // missing capability, not a broken run, so it is swallowed here rather
      // than surfaced.
      onError: (Object _) {},
      cancelOnError: false,
    );

    return controller.stream;
  }

  @override
  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
    await _controller?.close();
    _controller = null;
  }
}
