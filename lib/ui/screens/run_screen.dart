import 'package:flutter/material.dart';

import '../../domain/location_provider.dart';
import '../../domain/models/run_status.dart';
import '../format.dart';
import '../run_controller.dart';
import '../theme.dart';
import '../widgets/metric_tile.dart';
import '../widgets/route_map.dart';
import '../widgets/status_widgets.dart';
import 'history_screen.dart';
import 'summary_screen.dart';

/// The one screen a run happens on: idle, active and paused are states of the
/// same screen rather than separate routes, so nothing is ever pushed or popped
/// underneath a run in progress.
class RunScreen extends StatefulWidget {
  const RunScreen({super.key, required this.controller});

  final RunController controller;

  @override
  State<RunScreen> createState() => _RunScreenState();
}

class _RunScreenState extends State<RunScreen> {
  RunController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _c.addListener(_onControllerChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _c.warmUpGps());
  }

  @override
  void dispose() {
    _c.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    final error = _c.error;
    if (error != null && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(error)));
      _c.clearError();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) {
        final inProgress = _c.status.isInProgress;
        return PopScope(
          // Leaving the app mid-run is almost always a misfire, and the cost of
          // getting it wrong is the whole run.
          canPop: !inProgress,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _confirmDiscard();
          },
          child: Scaffold(
            appBar: AppBar(
              title: const Text(
                'RUN',
                style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 3),
              ),
              actions: [
                if (!inProgress)
                  IconButton(
                    tooltip: 'Run history',
                    icon: const Icon(Icons.history),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => HistoryScreen(controller: _c),
                      ),
                    ),
                  ),
              ],
            ),
            body: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
                child: inProgress ? _buildActive() : _buildIdle(),
              ),
            ),
          ),
        );
      },
    );
  }

  // ------------------------------------------------------------------- idle

  Widget _buildIdle() {
    final ready = _c.availability == LocationAvailability.ready;

    return Column(
      children: [
        if (_c.hasRecoveredRun) _RecoveryBanner(controller: _c),
        const Spacer(),
        Semantics(
          button: true,
          label: 'Start run',
          child: GestureDetector(
            onTap: _c.canStart ? _startRun : null,
            child: Container(
              width: 208,
              height: 208,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: RunTheme.running.withValues(
                  alpha: _c.canStart ? 0.16 : 0.06,
                ),
                border: Border.all(
                  color: RunTheme.running.withValues(
                    alpha: _c.canStart ? 0.9 : 0.3,
                  ),
                  width: 2.5,
                ),
              ),
              alignment: Alignment.center,
              child: _c.busy
                  ? const CircularProgressIndicator(color: RunTheme.running)
                  : const Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.play_arrow_rounded,
                          size: 60,
                          color: RunTheme.running,
                        ),
                        Text(
                          'START RUN',
                          style: TextStyle(
                            color: RunTheme.running,
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.6,
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
        const SizedBox(height: 28),
        _LocationStatus(controller: _c, ready: ready),
        const Spacer(),
      ],
    );
  }

  // ----------------------------------------------------------------- active

  Widget _buildActive() {
    final m = _c.metrics;
    final paused = _c.status.isPaused;
    final mapOpen = _c.mapExpanded;
    final average = m.averagePaceSecondsPerKm();

    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            StatusPill(status: _c.status),
            GpsBadge(
              quality: m.gpsQuality,
              estimatingFromSteps: m.isEstimatingFromSteps,
            ),
          ],
        ),
        SizedBox(height: mapOpen ? 12 : 24),
        HeroMetric(
          value: Fmt.distanceValue(m.distanceMeters),
          unit: Fmt.distanceUnit(m.distanceMeters),
          semanticsLabel: Fmt.distanceSemantics(m.distanceMeters),
          dimmed: paused,
          compact: mapOpen,
        ),
        SizedBox(height: mapOpen ? 12 : 28),
        Row(
          children: [
            Expanded(
              child: MetricTile(
                value: Fmt.duration(m.elapsed),
                label: 'DURATION',
                semanticsLabel: Fmt.durationSemantics(m.elapsed),
                dimmed: paused,
              ),
            ),
            Expanded(
              child: MetricTile(
                value: Fmt.pace(m.currentPaceSecondsPerKm),
                label: 'PACE /KM',
                caption: 'avg ${Fmt.pace(average)}',
                semanticsLabel: Fmt.paceSemantics(m.currentPaceSecondsPerKm),
                dimmed: paused,
              ),
            ),
            Expanded(
              child: MetricTile(
                value: Fmt.speed(m.currentSpeedKmh),
                label: 'KM/H',
                semanticsLabel: m.currentSpeedKmh == null
                    ? 'Speed not available yet'
                    : 'Speed ${Fmt.speed(m.currentSpeedKmh)} kilometres per hour',
                dimmed: paused,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        // The map is additive, never a mode: the metrics above stay on screen
        // whether it is open or shut, and it is unmounted while collapsed so it
        // costs nothing by default.
        _MapSection(controller: _c),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              flex: 3,
              child: FilledButton.icon(
                onPressed: paused ? _c.resumeRun : _c.pauseRun,
                style: FilledButton.styleFrom(
                  backgroundColor: paused
                      ? RunTheme.running
                      : RunTheme.surfaceHigh,
                  foregroundColor: paused
                      ? const Color(0xFF06240F)
                      : RunTheme.textPrimary,
                ),
                icon: Icon(paused ? Icons.play_arrow_rounded : Icons.pause),
                label: Text(paused ? 'RESUME' : 'PAUSE'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: OutlinedButton(
                onPressed: _confirmFinish,
                child: const Text('FINISH'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ---------------------------------------------------------------- actions

  Future<void> _startRun() async {
    final started = await _c.startRun();
    if (!started && mounted) {
      final availability = _c.availability;
      if (availability == LocationAvailability.deniedForever ||
          availability == LocationAvailability.serviceDisabled) {
        await _offerSettings(availability);
      }
    }
  }

  Future<void> _offerSettings(LocationAvailability availability) async {
    final isService = availability == LocationAvailability.serviceDisabled;
    final open = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(isService ? 'Location is off' : 'Location is blocked'),
        content: Text(
          isService
              ? 'Turn on location services so RUN can measure your run.'
              : 'Location access is permanently denied, so RUN cannot ask '
                    'again. You can grant it in system settings.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(minimumSize: const Size(100, 44)),
            child: const Text('Open settings'),
          ),
        ],
      ),
    );
    if (open != true) return;
    if (isService) {
      await _c.openLocationSettings();
    } else {
      await _c.openAppSettings();
    }
  }

  /// Finishing is irreversible, so it asks. Pausing is not, so it does not.
  Future<void> _confirmFinish() async {
    final m = _c.metrics;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Finish run?'),
        content: Text(
          '${Fmt.distance(m.distanceMeters)} · ${Fmt.duration(m.elapsed)}',
          style: const TextStyle(fontSize: 16),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep running'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(minimumSize: const Size(100, 44)),
            child: const Text('Finish'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final record = await _c.finishRun();
    if (record == null || !mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SummaryScreen(controller: _c, run: record),
      ),
    );
    _c.dismissFinishedRun();
  }

  Future<void> _confirmDiscard() async {
    final leave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('A run is in progress'),
        content: const Text(
          'Finish the run to save it. Leaving now keeps it in progress.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Stay'),
          ),
        ],
      ),
    );
    if (leave == true && mounted) Navigator.of(context).pop();
  }
}

// ----------------------------------------------------------------- sections

class _MapSection extends StatelessWidget {
  const _MapSection({required this.controller});

  final RunController controller;

  @override
  Widget build(BuildContext context) {
    final expanded = controller.mapExpanded;
    return Expanded(
      child: Column(
        children: [
          InkWell(
            onTap: () => controller.setMapExpanded(!expanded),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    expanded ? Icons.expand_more : Icons.expand_less,
                    size: 18,
                    color: RunTheme.textSecondary,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    expanded ? 'Hide map' : 'Map',
                    style: const TextStyle(
                      color: RunTheme.textSecondary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.6,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (expanded)
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: RouteMap(route: controller.route, follow: true),
              ),
            ),
        ],
      ),
    );
  }
}

class _LocationStatus extends StatelessWidget {
  const _LocationStatus({required this.controller, required this.ready});

  final RunController controller;
  final bool ready;

  @override
  Widget build(BuildContext context) {
    final (icon, text, color) = switch (controller.availability) {
      LocationAvailability.ready => (
        Icons.gps_fixed,
        'Location ready',
        RunTheme.running,
      ),
      LocationAvailability.serviceDisabled => (
        Icons.location_disabled,
        'Location services are off',
        RunTheme.paused,
      ),
      LocationAvailability.deniedForever => (
        Icons.block,
        'Location access is blocked in settings',
        RunTheme.danger,
      ),
      _ => (
        Icons.location_searching,
        'Location permission needed',
        RunTheme.textSecondary,
      ),
    };

    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 15, color: color),
            const SizedBox(width: 6),
            Text(text, style: TextStyle(color: color, fontSize: 13)),
          ],
        ),
        if (!ready &&
            controller.availability != LocationAvailability.deniedForever) ...[
          const SizedBox(height: 8),
          TextButton(
            onPressed: controller.requestPermission,
            child: const Text('Grant location access'),
          ),
        ],
      ],
    );
  }
}

/// Offered when the app restarts to find a run that was never finished.
///
/// Three options, because all three are legitimate: the runner may still be
/// mid-run, may have finished long ago, or may not want the run at all. Picking
/// one for them would be guessing with their data.
class _RecoveryBanner extends StatelessWidget {
  const _RecoveryBanner({required this.controller});

  final RunController controller;

  @override
  Widget build(BuildContext context) {
    final recovered = controller.recoveredRun;
    if (recovered == null) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: RunTheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: RunTheme.paused.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.restore, size: 18, color: RunTheme.paused),
              SizedBox(width: 8),
              Text(
                'Unfinished run',
                style: TextStyle(
                  color: RunTheme.textPrimary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${Fmt.distance(recovered.distanceMeters)} · '
            '${Fmt.duration(recovered.elapsed)} — recovered after the app '
            'closed.',
            style: const TextStyle(
              color: RunTheme.textSecondary,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: controller.resumeRecoveredRun,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(44),
                  ),
                  child: const Text('Resume'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: controller.saveRecoveredRun,
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(44),
                  ),
                  child: const Text('Save'),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: controller.discardRecoveredRun,
                child: const Text('Discard'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
