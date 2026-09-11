import 'package:flutter/material.dart';

import '../../domain/models/run_status.dart';
import '../theme.dart';

/// Running / paused, said three ways at once.
///
/// Text, colour, and (elsewhere) the primary button's label all change
/// together. Colour alone would fail for a colour-blind runner and for anyone
/// glancing at a screen in direct sunlight.
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.status});

  final RunStatus status;

  @override
  Widget build(BuildContext context) {
    final isPaused = status.isPaused;
    final color = isPaused ? RunTheme.paused : RunTheme.running;
    final label = isPaused ? 'PAUSED' : 'RUNNING';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.55)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isPaused ? Icons.pause_circle_filled : Icons.directions_run,
            size: 15,
            color: color,
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
        ],
      ),
    );
  }
}

/// How much to trust the numbers right now.
///
/// A tracker that silently under-reports during a signal loss is worse than one
/// that says so. Tapping explains what "weak" means for the distance.
class GpsBadge extends StatelessWidget {
  const GpsBadge({
    super.key,
    required this.quality,
    this.estimatingFromSteps = false,
  });

  final GpsQuality quality;

  /// Distance is coming from the step counter because GPS is unusable. Said
  /// plainly, because an estimate must not look like a measurement.
  final bool estimatingFromSteps;

  @override
  Widget build(BuildContext context) {
    if (estimatingFromSteps) {
      return const _Badge(
        color: RunTheme.paused,
        icon: Icons.directions_walk,
        label: 'STEPS',
        tooltip:
            'No GPS signal, so distance and pace are being estimated from '
            'your step count. Less precise than GPS, but the run keeps going.',
      );
    }

    switch (quality) {
      case GpsQuality.good:
        return const _Badge(
          color: RunTheme.running,
          icon: Icons.gps_fixed,
          label: 'GPS',
          tooltip: 'Good signal.',
        );
      case GpsQuality.weak:
        return const _Badge(
          color: RunTheme.paused,
          icon: Icons.gps_not_fixed,
          label: 'GPS WEAK',
          tooltip:
              'No usable fix recently. Time keeps counting, but distance may '
              'under-report until the signal returns.',
        );
      case GpsQuality.acquiring:
        return const _Badge(
          color: RunTheme.textSecondary,
          icon: Icons.gps_off,
          label: 'ACQUIRING',
          tooltip: 'Waiting for the first usable fix.',
        );
    }
  }
}

class _Badge extends StatelessWidget {
  const _Badge({
    required this.color,
    required this.icon,
    required this.label,
    required this.tooltip,
  });

  final Color color;
  final IconData icon;
  final String label;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      triggerMode: TooltipTriggerMode.tap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1,
            ),
          ),
        ],
      ),
    );
  }
}
