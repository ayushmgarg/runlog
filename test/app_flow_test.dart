import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runlog/data/run_repository.dart';
import 'package:runlog/domain/location_provider.dart';
import 'package:runlog/domain/models/location_sample.dart';
import 'package:runlog/domain/models/run_record.dart';
import 'package:runlog/domain/models/run_status.dart';
import 'package:runlog/ui/run_controller.dart';
import 'package:runlog/ui/screens/run_screen.dart';
import 'package:runlog/ui/screens/summary_screen.dart';
import 'package:runlog/ui/theme.dart';
import 'helpers.dart';

class InMemoryRepository implements RunRepository {
  final List<RunRecord> runs = [];
  Map<String, dynamic>? activeRun;

  @override
  Future<List<RunRecord>> loadRuns() async =>
      List<RunRecord>.of(runs)
        ..sort((a, b) => b.startedAt.compareTo(a.startedAt));

  @override
  Future<void> saveRun(RunRecord run) async {
    runs
      ..removeWhere((r) => r.id == run.id)
      ..insert(0, run);
  }

  @override
  Future<void> deleteRun(String id) async =>
      runs.removeWhere((r) => r.id == id);

  @override
  Future<void> saveActiveRun(Map<String, dynamic> snapshot) async =>
      activeRun = snapshot;

  @override
  Future<Map<String, dynamic>?> loadActiveRun() async => activeRun;

  @override
  Future<void> clearActiveRun() async => activeRun = null;
}

class FakeLocationProvider implements LocationProvider {
  FakeLocationProvider({this.availability = LocationAvailability.ready});

  LocationAvailability availability;
  StreamController<LocationSample> _controller =
      StreamController<LocationSample>.broadcast();

  int streamRequests = 0;
  bool disposed = false;
  void emit(LocationSample sample) => _controller.add(sample);

  Future<void> endStream() async {
    await _controller.close();
    _controller = StreamController<LocationSample>.broadcast();
  }

  @override
  Future<LocationAvailability> checkAvailability() async => availability;

  @override
  Future<LocationAvailability> requestPermission() async => availability;

  @override
  Future<void> openAppSettings() async {}

  @override
  Future<void> openLocationSettings() async {}

  @override
  Future<LocationSample?> lastKnownOrCurrent() async => null;

  @override
  Stream<LocationSample> positionStream() {
    streamRequests++;
    return _controller.stream;
  }

  @override
  Stream<bool> serviceEnabledStream() => const Stream<bool>.empty();

  @override
  Future<void> dispose() async {
    disposed = true;
    await _controller.close();
  }
}

void main() {
  final t0 = DateTime.now();
  late InMemoryRepository repository;
  late FakeLocationProvider provider;
  late RunController controller;

  setUp(() async {
    repository = InMemoryRepository();
    provider = FakeLocationProvider();
    controller = RunController(repository: repository, provider: provider);
    await controller.init();
  });

  tearDown(() => controller.dispose());

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> stopTimers(WidgetTester tester) async {
    await controller.pauseRun();
    await tester.pump();
  }

  Widget wrap() => MaterialApp(
    theme: RunTheme.build(),
    home: RunScreen(controller: controller),
  );

  Future<void> run(WidgetTester tester, {required int seconds}) async {
    for (var i = 1; i <= seconds; i++) {
      provider.emit(
        sampleAt(
          northMeters: i * 3.0,
          eastMeters: 0,
          at: t0.add(Duration(seconds: i)),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
    }
  }

  testWidgets('idle screen offers the one action that matters', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();
    expect(find.text('START RUN'), findsOneWidget);
    expect(find.text('PAUSE'), findsNothing);
    expect(find.text('FINISH'), findsNothing);
    // Distance, duration and pace belong to a run, not to the start screen.
    expect(find.text('DURATION'), findsNothing);
  });

  testWidgets('start shows every metric the assignment asks for', (
    tester,
  ) async {
    await tester.pumpWidget(wrap());
    await tester.pump();
    await tester.tap(find.text('START RUN'));
    await settle(tester);
    expect(controller.status, RunStatus.active);
    expect(find.text('RUNNING'), findsOneWidget);
    expect(find.text('DURATION'), findsOneWidget);
    expect(find.text('PACE /KM'), findsOneWidget);
    expect(find.text('KM/H'), findsOneWidget);
    expect(find.text('PAUSE'), findsOneWidget);
    expect(find.text('FINISH'), findsOneWidget);
    expect(provider.streamRequests, 1);
    await stopTimers(tester);
  });

  testWidgets('distance updates as fixes arrive', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();
    await tester.tap(find.text('START RUN'));
    await settle(tester);
    await run(tester, seconds: 30);
    expect(controller.metrics.distanceMeters, greaterThan(50));
    // Under a kilometre the hero metric reads in whole metres.
    expect(find.text('M'), findsOneWidget);
    await stopTimers(tester);
  });

  testWidgets('pause and resume swap the control and the status', (
    tester,
  ) async {
    await tester.pumpWidget(wrap());
    await tester.pump();
    await tester.tap(find.text('START RUN'));
    await settle(tester);
    await run(tester, seconds: 10);
    await tester.tap(find.text('PAUSE'));
    await settle(tester);
    expect(controller.status, RunStatus.paused);
    expect(find.text('PAUSED'), findsOneWidget);
    expect(find.text('RESUME'), findsOneWidget);
    expect(find.text('PAUSE'), findsNothing);
    await tester.tap(find.text('RESUME'));
    await settle(tester);
    expect(controller.status, RunStatus.active);
    expect(find.text('RUNNING'), findsOneWidget);
    expect(find.text('PAUSE'), findsOneWidget);
    // Resuming re-subscribes: a paused run holds no location subscription.
    expect(provider.streamRequests, 2);
    await stopTimers(tester);
  });

  testWidgets('finishing asks first, and can be called off', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();
    await tester.tap(find.text('START RUN'));
    await settle(tester);
    await run(tester, seconds: 10);
    await tester.tap(find.text('FINISH'));
    await settle(tester);
    expect(find.text('Finish run?'), findsOneWidget);
    await tester.tap(find.text('Keep running'));
    await settle(tester);

    // An accidental tap must not end the run.
    expect(controller.status, RunStatus.active);
    expect(find.text('RUNNING'), findsOneWidget);
    await stopTimers(tester);
  });

  testWidgets('confirmed finish saves the run and shows the summary', (
    tester,
  ) async {
    await tester.pumpWidget(wrap());
    await tester.pump();
    await tester.tap(find.text('START RUN'));
    await settle(tester);
    await run(tester, seconds: 40);
    await tester.tap(find.text('FINISH'));
    await settle(tester);
    await tester.tap(find.text('Finish'));
    await settle(tester);
    expect(find.byType(SummaryScreen), findsOneWidget);
    expect(find.text('DISTANCE'), findsOneWidget);
    expect(find.text('DURATION'), findsOneWidget);
    expect(find.text('AVG PACE'), findsOneWidget);

    // ...and it was persisted, not just held in memory.
    expect(repository.runs, hasLength(1));
    expect(repository.runs.first.distanceMeters, greaterThan(50));
    expect(repository.runs.first.route, isNotEmpty);
    // The in-progress snapshot is cleared once the run is safely stored.
    expect(repository.activeRun, isNull);
  });

  testWidgets('a run with no fixes still finishes cleanly', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();
    await tester.tap(find.text('START RUN'));
    await settle(tester);
    await tester.pump(const Duration(seconds: 3));
    await tester.tap(find.text('FINISH'));
    await settle(tester);
    await tester.tap(find.text('Finish'));
    await settle(tester);

    // No route, no pace, no crash: the empty state says why.
    expect(find.byType(SummaryScreen), findsOneWidget);
    expect(find.text('No route recorded'), findsOneWidget);
    expect(find.text('--:--'), findsWidgets);
  });

  testWidgets('the live map is opt-in and stays unmounted until asked for', (
    tester,
  ) async {
    await tester.pumpWidget(wrap());
    await tester.pump();
    await tester.tap(find.text('START RUN'));
    await settle(tester);
    expect(find.text('Map'), findsOneWidget);
    expect(controller.mapExpanded, isFalse);
    await tester.tap(find.text('Map'));
    await tester.pump();
    expect(controller.mapExpanded, isTrue);
    expect(find.text('Hide map'), findsOneWidget);
    await stopTimers(tester);
  });

  testWidgets('a closed location stream is re-opened while the run is active', (
    tester,
  ) async {
    await tester.pumpWidget(wrap());
    await tester.pump();
    await tester.tap(find.text('START RUN'));
    await settle(tester);
    await run(tester, seconds: 5);
    expect(provider.streamRequests, 1);
    await provider.endStream();
    await tester.pump();

    // The retry is deliberately not instant; give it its backoff.
    await tester.pump(const Duration(seconds: 4));
    expect(
      provider.streamRequests,
      2,
      reason: 'the run must re-open the stream on its own',
    );

    await stopTimers(tester);
  });

  testWidgets('a closed stream is not re-opened once the run is paused', (
    tester,
  ) async {
    await tester.pumpWidget(wrap());
    await tester.pump();
    await tester.tap(find.text('START RUN'));
    await settle(tester);
    await run(tester, seconds: 3);
    await controller.pauseRun();
    await tester.pump();
    final afterPause = provider.streamRequests;
    await provider.endStream();
    await tester.pump(const Duration(seconds: 6));
    expect(provider.streamRequests, afterPause);
  });

  testWidgets('a denied permission explains itself instead of faking a run', (
    tester,
  ) async {
    provider.availability = LocationAvailability.denied;
    await controller.refreshAvailability();
    await tester.pumpWidget(wrap());
    await tester.pump();
    expect(find.text('Location permission needed'), findsOneWidget);
    await tester.tap(find.text('START RUN'));
    await settle(tester);
    expect(controller.status, RunStatus.idle);
    expect(find.text('START RUN'), findsOneWidget);
  });

  testWidgets('an unfinished run is offered back after a restart', (
    tester,
  ) async {
    // Simulate a previous session that was killed mid-run.
    await tester.pumpWidget(wrap());
    await tester.pump();
    await tester.tap(find.text('START RUN'));
    await settle(tester);
    await run(tester, seconds: 20);
    await controller.pauseRun();
    await settle(tester);
    expect(repository.activeRun, isNotNull, reason: 'the run was snapshotted');

    // A fresh controller over the same storage is exactly what a relaunch is.
    final relaunched = RunController(
      repository: repository,
      provider: FakeLocationProvider(),
    );
    await relaunched.init();
    addTearDown(relaunched.dispose);
    expect(relaunched.hasRecoveredRun, isTrue);

    await tester.pumpWidget(
      MaterialApp(
        theme: RunTheme.build(),
        home: RunScreen(controller: relaunched),
      ),
    );
    await tester.pump();
    expect(find.text('Unfinished run'), findsOneWidget);
    expect(find.text('Resume'), findsOneWidget);
    expect(find.text('Save'), findsOneWidget);
    expect(find.text('Discard'), findsOneWidget);
    // The unresolved run blocks a new one: two runs at once is never intended.
    expect(relaunched.canStart, isFalse);
  });
}
