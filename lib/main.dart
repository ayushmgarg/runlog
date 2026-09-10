import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app.dart';
import 'ui/run_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Portrait only: the run screen is read while moving, and a rotation
  // mid-stride is never intentional.
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

  final controller = RunController();
  // Permissions, saved history and any unfinished run are resolved before the
  // first frame, so the idle screen never flashes the wrong state.
  await controller.init();

  runApp(RunApp(controller: controller));
}
