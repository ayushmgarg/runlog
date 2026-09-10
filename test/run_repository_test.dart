import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plexqo_run/data/run_repository.dart';
import 'package:plexqo_run/domain/models/run_record.dart';
import 'package:plexqo_run/domain/models/track_point.dart';

/// Storage tests run on the real event loop against a real directory.
///
/// The widget tests use an in-memory store instead, because file I/O never
/// completes inside `testWidgets`' fake clock — so these exist to cover the
/// paths that actually touch a disk.
void main() {
  late Directory tempDir;
  late RunRepository repository;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('run_repo_test');
    repository = RunRepository(directory: tempDir);
  });

  tearDown(() {
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows may still hold the handle briefly; the temp dir is disposable.
    }
  });

  RunRecord record(String id, {DateTime? startedAt, int points = 3}) {
    final start = startedAt ?? DateTime(2026, 9, 11, 7, 0);
    return RunRecord(
      id: id,
      startedAt: start,
      endedAt: start.add(const Duration(minutes: 20)),
      distanceMeters: 3200,
      duration: const Duration(minutes: 18),
      route: List.generate(
        points,
        (i) => TrackPoint(
          latitude: 12.9716 + i * 0.0001,
          longitude: 77.5946,
          accuracy: 5,
          timestamp: start.add(Duration(seconds: i)),
          segment: 0,
          cumulativeMeters: i * 11.0,
        ),
      ),
    );
  }

  group('history', () {
    test('starts empty on a fresh install', () async {
      expect(await repository.loadRuns(), isEmpty);
    });

    test('round-trips a run, route and all', () async {
      await repository.saveRun(record('a'));
      final loaded = await repository.loadRuns();

      expect(loaded, hasLength(1));
      final run = loaded.first;
      expect(run.id, 'a');
      expect(run.distanceMeters, 3200);
      expect(run.duration, const Duration(minutes: 18));
      expect(run.route, hasLength(3));
      expect(run.route.first.latitude, closeTo(12.9716, 1e-9));
      expect(run.startedAt.isAtSameMomentAs(record('a').startedAt), isTrue);
    });

    test('returns runs newest first', () async {
      await repository.saveRun(
        record('old', startedAt: DateTime(2026, 9, 1, 6)),
      );
      await repository.saveRun(
        record('new', startedAt: DateTime(2026, 9, 10, 6)),
      );

      expect(
        (await repository.loadRuns()).map((r) => r.id),
        ['new', 'old'],
      );
    });

    test('saving the same id twice updates rather than duplicates', () async {
      await repository.saveRun(record('a'));
      await repository.saveRun(record('a'));
      expect(await repository.loadRuns(), hasLength(1));
    });

    test('deletes a single run and leaves the rest', () async {
      await repository.saveRun(record('a', startedAt: DateTime(2026, 9, 1)));
      await repository.saveRun(record('b', startedAt: DateTime(2026, 9, 2)));

      await repository.deleteRun('a');

      expect((await repository.loadRuns()).map((r) => r.id), ['b']);
    });

    test('a corrupt history file degrades to empty instead of crashing', () async {
      // Losing history is bad; a permanently unusable app is worse.
      await File('${tempDir.path}/runs.json').writeAsString('{not json at all');
      expect(await repository.loadRuns(), isEmpty);

      // ...and it recovers: the next save rewrites the file cleanly.
      await repository.saveRun(record('a'));
      expect(await repository.loadRuns(), hasLength(1));
    });

    test('writes are atomic, leaving no partial file behind', () async {
      await repository.saveRun(record('a'));
      final files = tempDir.listSync().map((e) => e.path.split(RegExp(r'[\\/]')).last);
      expect(files, contains('runs.json'));
      expect(files.where((f) => f.endsWith('.tmp')), isEmpty);
    });
  });

  group('active run snapshot', () {
    test('is absent until something is saved', () async {
      expect(await repository.loadActiveRun(), isNull);
    });

    test('round-trips and then clears', () async {
      await repository.saveActiveRun({'version': 1, 'distance': 812.5});

      final loaded = await repository.loadActiveRun();
      expect(loaded, isNotNull);
      expect(loaded!['distance'], 812.5);

      await repository.clearActiveRun();
      expect(await repository.loadActiveRun(), isNull);
    });

    test('clearing an absent snapshot is a no-op, not an error', () async {
      await expectLater(repository.clearActiveRun(), completes);
    });

    test('a corrupt snapshot is ignored', () async {
      await File('${tempDir.path}/active_run.json').writeAsString('garbage');
      expect(await repository.loadActiveRun(), isNull);
    });

    test('survives being written and read as raw JSON', () async {
      // Guards the contract the recovery flow depends on: whatever
      // RunTracker.toSnapshot produces must survive a JSON round-trip.
      final snapshot = {
        'version': 1,
        'status': 'active',
        'startedAt': 1757563200000,
        'elapsedMs': 125000,
        'distance': 812.5,
        'segment': 1,
        'route': [
          {
            'lat': 12.9716,
            'lon': 77.5946,
            'acc': 5.0,
            't': 1757563200000,
            'seg': 0,
            'cum': 0.0,
          },
        ],
      };
      await repository.saveActiveRun(snapshot);

      final raw = await File('${tempDir.path}/active_run.json').readAsString();
      expect(jsonDecode(raw), snapshot);
    });
  });
}
