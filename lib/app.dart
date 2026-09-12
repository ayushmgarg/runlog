import 'package:flutter/material.dart';
import 'ui/run_controller.dart';
import 'ui/screens/run_screen.dart';
import 'ui/theme.dart';

class RunApp extends StatefulWidget {
  const RunApp({super.key, required this.controller});

  final RunController controller;

  @override
  State<RunApp> createState() => _RunAppState();
}

class _RunAppState extends State<RunApp> {
  @override
  void dispose() {
    widget.controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RunLog',
      debugShowCheckedModeBanner: false,
      theme: RunTheme.build(),
      home: RunScreen(controller: widget.controller),
    );
  }
}
