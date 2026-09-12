import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app.dart';
import 'ui/run_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  final controller = RunController();
  await controller.init();
  runApp(RunApp(controller: controller));
}
