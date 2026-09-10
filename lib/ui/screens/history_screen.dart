import 'package:flutter/material.dart';

import '../format.dart';
import '../run_controller.dart';
import '../theme.dart';
import 'summary_screen.dart';

/// Saved runs, newest first.
///
/// Not a feature so much as a consequence: a finished run has to be reachable
/// again after the summary screen is dismissed, and a list is the smallest way
/// to do that.
class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key, required this.controller});

  final RunController controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Run history')),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
            final runs = controller.history;
            if (runs.isEmpty) {
              return const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.directions_run,
                      size: 34,
                      color: RunTheme.textSecondary,
                    ),
                    SizedBox(height: 12),
                    Text(
                      'No runs yet',
                      style: TextStyle(
                        color: RunTheme.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Finished runs are saved on this device.',
                      style: TextStyle(
                        color: RunTheme.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              );
            }

            return ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: runs.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final run = runs[index];
                return Material(
                  color: RunTheme.surface,
                  borderRadius: BorderRadius.circular(14),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            SummaryScreen(controller: controller, run: run),
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  Fmt.distance(run.distanceMeters),
                                  style: const TextStyle(
                                    color: RunTheme.textPrimary,
                                    fontSize: 20,
                                    fontWeight: FontWeight.w600,
                                    fontFeatures: RunTheme.tabular,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  Fmt.dateTime(run.startedAt),
                                  style: const TextStyle(
                                    color: RunTheme.textSecondary,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                Fmt.duration(run.duration),
                                style: const TextStyle(
                                  color: RunTheme.textPrimary,
                                  fontSize: 15,
                                  fontFeatures: RunTheme.tabular,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '${Fmt.pace(run.averagePaceSecondsPerKm)} /km',
                                style: const TextStyle(
                                  color: RunTheme.textSecondary,
                                  fontSize: 12,
                                  fontFeatures: RunTheme.tabular,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}
