import 'package:flutter/material.dart';

import '../../domain/models/run_record.dart';
import '../format.dart';
import '../run_controller.dart';
import '../theme.dart';
import '../widgets/metric_tile.dart';
import '../widgets/route_map.dart';

/// What the assignment asks for after Finish: distance, duration, average pace,
/// and the route.
class SummaryScreen extends StatelessWidget {
  const SummaryScreen({super.key, required this.controller, required this.run});

  final RunController controller;
  final RunRecord run;

  @override
  Widget build(BuildContext context) {
    final pace = run.averagePaceSecondsPerKm;
    final speed = run.averageSpeedKmh;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Run summary'),
        actions: [
          IconButton(
            tooltip: 'Delete run',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _confirmDelete(context),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                Fmt.dateTime(run.startedAt),
                style: const TextStyle(
                  color: RunTheme.textSecondary,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 20),
              Center(
                child: HeroMetric(
                  value: Fmt.distanceValue(run.distanceMeters),
                  unit: Fmt.distanceUnit(run.distanceMeters),
                  semanticsLabel: Fmt.distanceSemantics(run.distanceMeters),
                  compact: true,
                ),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  SummaryStat(
                    value: Fmt.distance(run.distanceMeters),
                    label: 'DISTANCE',
                    semanticsLabel: Fmt.distanceSemantics(run.distanceMeters),
                  ),
                  const SizedBox(width: 10),
                  SummaryStat(
                    value: Fmt.duration(run.duration),
                    label: 'DURATION',
                    semanticsLabel: Fmt.durationSemantics(run.duration),
                  ),
                  const SizedBox(width: 10),
                  SummaryStat(
                    value: Fmt.pace(pace),
                    label: 'AVG PACE',
                    caption: speed == null
                        ? null
                        : '${Fmt.speed(speed)} km/h',
                    semanticsLabel: Fmt.paceSemantics(pace),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: RouteMap(route: run.route, showEndpoints: true),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('DONE'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final navigator = Navigator.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this run?'),
        content: const Text('This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: RunTheme.danger,
              foregroundColor: Colors.white,
              minimumSize: const Size(100, 44),
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await controller.deleteRun(run.id);
    navigator.pop();
  }
}
