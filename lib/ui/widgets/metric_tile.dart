import 'package:flutter/material.dart';

import '../theme.dart';

/// The hero metric: distance, as big as the screen allows.
///
/// Sized to be readable at arm's length while moving, which is the only reading
/// distance this screen ever gets.
class HeroMetric extends StatelessWidget {
  const HeroMetric({
    super.key,
    required this.value,
    required this.unit,
    required this.semanticsLabel,
    this.dimmed = false,
    this.compact = false,
  });

  final String value;
  final String unit;
  final String semanticsLabel;

  /// Paused runs are dimmed so the state is readable from a glance, without
  /// relying on colour alone.
  final bool dimmed;

  /// Shrinks one step when the live map is expanded — the metrics stay on
  /// screen, they just make room.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semanticsLabel,
      excludeSemantics: true,
      child: AnimatedOpacity(
        opacity: dimmed ? 0.45 : 1,
        duration: const Duration(milliseconds: 200),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                value,
                style: TextStyle(
                  // The floor matters: with a large system font scale this must
                  // still fit, and with a small one it must not shrink to
                  // nothing.
                  fontSize: compact ? 64 : 96,
                  height: 1,
                  fontWeight: FontWeight.w300,
                  color: RunTheme.textPrimary,
                  fontFeatures: RunTheme.tabular,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              unit,
              style: const TextStyle(
                fontSize: 14,
                letterSpacing: 3,
                fontWeight: FontWeight.w600,
                color: RunTheme.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One secondary metric: duration, pace or speed.
class MetricTile extends StatelessWidget {
  const MetricTile({
    super.key,
    required this.value,
    required this.label,
    required this.semanticsLabel,
    this.caption,
    this.dimmed = false,
  });

  final String value;
  final String label;
  final String semanticsLabel;

  /// Small line underneath, e.g. the average behind a live value.
  final String? caption;

  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semanticsLabel,
      excludeSemantics: true,
      child: AnimatedOpacity(
        opacity: dimmed ? 0.45 : 1,
        duration: const Duration(milliseconds: 200),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                value,
                style: const TextStyle(
                  fontSize: 30,
                  height: 1.1,
                  fontWeight: FontWeight.w500,
                  color: RunTheme.textPrimary,
                  fontFeatures: RunTheme.tabular,
                ),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: const TextStyle(
                fontSize: 11,
                letterSpacing: 1.6,
                fontWeight: FontWeight.w600,
                color: RunTheme.textSecondary,
              ),
            ),
            if (caption != null) ...[
              const SizedBox(height: 2),
              Text(
                caption!,
                style: const TextStyle(
                  fontSize: 11,
                  color: RunTheme.textSecondary,
                  fontFeatures: RunTheme.tabular,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A stat on the summary screen: same information, no live-value framing.
class SummaryStat extends StatelessWidget {
  const SummaryStat({
    super.key,
    required this.value,
    required this.label,
    required this.semanticsLabel,
    this.caption,
  });

  final String value;
  final String label;
  final String semanticsLabel;
  final String? caption;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Semantics(
        label: semanticsLabel,
        excludeSemantics: true,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 8),
          decoration: BoxDecoration(
            color: RunTheme.surface,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  value,
                  style: const TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w600,
                    color: RunTheme.textPrimary,
                    fontFeatures: RunTheme.tabular,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 10,
                  letterSpacing: 1.4,
                  fontWeight: FontWeight.w600,
                  color: RunTheme.textSecondary,
                ),
              ),
              if (caption != null) ...[
                const SizedBox(height: 4),
                Text(
                  caption!,
                  style: const TextStyle(
                    fontSize: 11,
                    color: RunTheme.textSecondary,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
