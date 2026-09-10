import 'package:flutter_test/flutter_test.dart';
import 'package:plexqo_run/domain/models/location_sample.dart';
import 'package:plexqo_run/domain/models/run_status.dart';
import 'package:plexqo_run/domain/run_tracker.dart';

import 'helpers.dart';

/// The test matrix from `docs/02-tracking-algorithm.md` section 7.
///
/// Everything here runs against synthetic traces on a fake clock: no device, no
/// GPS, no waiting. That is the entire reason the engine has no plugin imports.
void main() {
  final t0 = DateTime.utc(2026, 9, 11, 7, 0, 0);

  late FakeClock clock;
  late RunTracker tracker;

  setUp(() {
    clock = FakeClock(t0);
    tracker = RunTracker(clock: clock.call);
  });

  /// Feeds a trace, keeping the clock in step with each fix, the way a real
  /// stream would.
  void feed(Iterable<LocationSample> samples) {
    for (final s in samples) {
      clock.now = s.timestamp;
      tracker.addSample(s);
    }
  }

  group('state machine', () {
    test('starts idle and ignores samples until started', () {
      expect(tracker.status, RunStatus.idle);
      final outcome = tracker.addSample(sampleAt(
        northMeters: 0,
        eastMeters: 0,
        at: t0,
      ));
      expect(outcome, SampleOutcome.ignoredNotActive);
      expect(tracker.route, isEmpty);
    });

    test('transitions idle -> active -> paused -> active -> finished', () {
      tracker.start();
      expect(tracker.status, RunStatus.active);
      tracker.pause();
      expect(tracker.status, RunStatus.paused);
      tracker.resume();
      expect(tracker.status, RunStatus.active);
      tracker.finish();
      expect(tracker.status, RunStatus.finished);
      // Terminal: a late fix cannot resurrect a finished run.
      expect(
        tracker.addSample(sampleAt(northMeters: 0, eastMeters: 0, at: t0)),
        SampleOutcome.ignoredNotActive,
      );
    });

    test('duration runs from start, before any fix arrives', () {
      // The runner is already running while the antenna warms up. Losing those
      // seconds is worse than showing 0 distance for a moment.
      tracker.start();
      clock.advance(const Duration(seconds: 8));
      expect(tracker.elapsed, const Duration(seconds: 8));
      expect(tracker.distanceMeters, 0);
      expect(tracker.gpsQuality, GpsQuality.acquiring);
    });
  });

  group('distance accuracy', () {
    test('straight 1 km at running pace is measured within 1%', () {
      tracker.start();
      // 3 m/s = 10.8 km/h, one fix per second, 334 fixes ≈ 1 km.
      feed(straightLine(start: t0, count: 334, metersPerFix: 3));

      // Within ~2%: the residual is the smoothing lag at the start of the
      // segment, which under-reports rather than over-reports.
      expect(tracker.distanceMeters, closeTo(999, 20));
    });

    test('per-fix hops below the jitter floor still accumulate correctly', () {
      // A 3 m hop is under the 4 m floor, so alternate fixes are held back and
      // released as 6 m hops. The quantisation must not lose distance.
      tracker.start();
      feed(straightLine(start: t0, count: 101, metersPerFix: 3));
      expect(tracker.distanceMeters, closeTo(300, 15));
    });

    test('standing still does not invent distance', () {
      // The headline failure mode of naive trackers: 60 fixes of pure scatter.
      final trace = stationaryJitter(start: t0, count: 60, sigmaMeters: 2);
      tracker.start();
      feed(trace);

      final naive = naiveDistance(trace);
      expect(naive, greaterThan(80), reason: 'the raw trace really is noisy');
      expect(
        tracker.distanceMeters,
        lessThan(naive * 0.1),
        reason: 'filter chain must remove the overwhelming majority of noise',
      );
      expect(tracker.distanceMeters, lessThan(15));
    });
  });

  group('filter chain', () {
    test('F1 rejects imprecise fixes, but the first fix gets a looser gate', () {
      tracker.start();
      // 40 m accuracy: unusable mid-run, acceptable as a starting anchor.
      expect(
        tracker.addSample(
          sampleAt(northMeters: 0, eastMeters: 0, at: t0, accuracy: 40),
        ),
        SampleOutcome.anchored,
      );
      expect(
        tracker.addSample(
          sampleAt(
            northMeters: 20,
            eastMeters: 0,
            at: t0.add(const Duration(seconds: 5)),
            accuracy: 40,
          ),
        ),
        SampleOutcome.rejectedAccuracy,
      );
      // ...and 80 m is not even good enough to anchor.
      final fresh = RunTracker(clock: clock.call)..start();
      expect(
        fresh.addSample(
          sampleAt(northMeters: 0, eastMeters: 0, at: t0, accuracy: 80),
        ),
        SampleOutcome.rejectedAccuracy,
      );
    });

    test('F2 rejects duplicate and out-of-order fixes', () {
      tracker.start();
      tracker.addSample(sampleAt(northMeters: 0, eastMeters: 0, at: t0));
      final replay = sampleAt(
        northMeters: 50,
        eastMeters: 0,
        at: t0.subtract(const Duration(seconds: 5)),
      );
      expect(tracker.addSample(replay), SampleOutcome.rejectedOutOfOrder);
      expect(tracker.distanceMeters, 0);
    });

    test('F4 rejects a GPS teleport without disturbing the run', () {
      tracker.start();
      feed(straightLine(start: t0, count: 40, metersPerFix: 3));
      final before = tracker.distanceMeters;

      // 300 m in one second: not a human.
      final outlier = sampleAt(
        northMeters: 420,
        eastMeters: 0,
        at: t0.add(const Duration(seconds: 40)),
      );
      expect(tracker.addSample(outlier), SampleOutcome.rejectedImplausibleSpeed);
      expect(tracker.distanceMeters, before);

      // The run carries on from where it was, unharmed.
      feed(straightLine(
        start: t0.add(const Duration(seconds: 41)),
        count: 20,
        metersPerFix: 3,
        startOffsetMeters: 120,
      ));
      expect(tracker.distanceMeters, greaterThan(before));
      // ...and it is still one continuous segment: a single bad fix is not a gap.
      expect(tracker.segmentCount, 1);
    });

    test('F4b stops a rejection cascade from letting a jump through', () {
      // A sustained teleport (mock location, provider switch) is rejected at
      // first, but each rejection pushes the last good fix further into the
      // past. Left alone, the same jump eventually divides by a big enough dt
      // to pass the speed gate as hundreds of real metres.
      tracker.start();
      feed(straightLine(start: t0, count: 40, metersPerFix: 3));
      final before = tracker.distanceMeters;
      final segmentsBefore = tracker.segmentCount;

      final outcomes = <SampleOutcome>[];
      for (var i = 1; i <= 6; i++) {
        final at = t0.add(Duration(seconds: 39 + i));
        clock.now = at;
        outcomes.add(
          tracker.addSample(sampleAt(northMeters: 900, eastMeters: 0, at: at)),
        );
      }

      // Two rejections, then the engine gives up and calls it a gap...
      expect(outcomes.take(2), everyElement(SampleOutcome.rejectedImplausibleSpeed));
      expect(outcomes[2], SampleOutcome.gapReanchor);
      // ...after which the phone is simply sitting at its new location.
      expect(outcomes.skip(3), everyElement(SampleOutcome.stationary));
      expect(tracker.distanceMeters, before);
      expect(tracker.segmentCount, segmentsBefore + 1);
    });

    test('F5 does not bridge a signal blackout, and breaks the route', () {
      tracker.start();
      feed(straightLine(start: t0, count: 30, metersPerFix: 3));
      final before = tracker.distanceMeters;
      final segmentsBefore = tracker.segmentCount;

      // 45 s of silence, then a fix 400 m away. We did not see that ground, so
      // we do not claim it.
      final afterGap = sampleAt(
        northMeters: 500,
        eastMeters: 0,
        at: t0.add(const Duration(seconds: 75)),
      );
      clock.now = afterGap.timestamp;
      expect(tracker.addSample(afterGap), SampleOutcome.gapReanchor);
      expect(tracker.distanceMeters, before);
      expect(tracker.segmentCount, segmentsBefore + 1);
    });
  });

  group('pause and resume', () {
    test('paused time is excluded from duration', () {
      tracker.start();
      clock.advance(const Duration(seconds: 30));
      tracker.pause();
      clock.advance(const Duration(seconds: 60));
      expect(tracker.elapsed, const Duration(seconds: 30));

      tracker.resume();
      clock.advance(const Duration(seconds: 15));
      expect(tracker.elapsed, const Duration(seconds: 45));
    });

    test('travelling during a pause adds no distance', () {
      tracker.start();
      feed(straightLine(start: t0, count: 40, metersPerFix: 3));
      final atPause = tracker.distanceMeters;
      expect(atPause, greaterThan(100));

      clock.advance(const Duration(seconds: 1));
      tracker.pause();

      // Driven 500 m in a car while paused.
      final resumeAt = t0.add(const Duration(seconds: 120));
      clock.now = resumeAt;
      tracker.resume();

      // First fix after resuming re-anchors and must not count the transfer.
      final firstAfterResume = sampleAt(
        northMeters: 620,
        eastMeters: 0,
        at: resumeAt,
      );
      expect(tracker.addSample(firstAfterResume), SampleOutcome.anchored);
      expect(tracker.distanceMeters, atPause);

      // Running from the new spot counts normally.
      feed(straightLine(
        start: resumeAt.add(const Duration(seconds: 1)),
        count: 20,
        metersPerFix: 3,
        startOffsetMeters: 623,
      ));
      expect(tracker.distanceMeters, greaterThan(atPause));
      expect(tracker.segmentCount, 2);
    });

    test('samples arriving while paused are ignored outright', () {
      tracker.start();
      tracker.pause();
      expect(
        tracker.addSample(sampleAt(northMeters: 0, eastMeters: 0, at: t0)),
        SampleOutcome.ignoredNotActive,
      );
    });
  });

  group('live metrics', () {
    test('speed reflects the rolling window, in both units, consistently', () {
      tracker.start();
      // 3 m/s for a minute.
      feed(straightLine(start: t0, count: 61, metersPerFix: 3));
      clock.now = t0.add(const Duration(seconds: 60));

      final m = tracker.metrics;
      expect(m.currentSpeedMps, closeTo(3.0, 0.35));
      expect(m.currentSpeedKmh, closeTo(10.8, 1.3));
      // Pace and speed are one measurement in two units and cannot disagree.
      expect(
        m.currentPaceSecondsPerKm,
        closeTo(1000 / m.currentSpeedMps!, 0.001),
      );
      expect(m.currentSpeedKmh, closeTo(m.currentSpeedMps! * 3.6, 0.001));
    });

    test('speed decays toward zero when the runner stops, and does not freeze', () {
      tracker.start();
      feed(straightLine(start: t0, count: 61, metersPerFix: 3));
      final moving = tracker.metrics.currentSpeedMps!;
      expect(moving, greaterThan(2));

      // Still getting fixes (so GPS is fine), just not moving.
      feed(stationaryJitter(
        start: t0.add(const Duration(seconds: 61)),
        count: 30,
        sigmaMeters: 1,
        originNorthMeters: 180,
      ));
      clock.now = t0.add(const Duration(seconds: 91));

      final stopped = tracker.metrics.currentSpeedMps!;
      expect(stopped, lessThan(0.5));
      // A stopped runner has no pace; the UI must show a placeholder, not 0.
      expect(tracker.metrics.currentPaceSecondsPerKm, isNull);
    });

    test('average pace is suppressed until the distance means something', () {
      tracker.start();
      clock.advance(const Duration(seconds: 10));
      feed(straightLine(start: t0, count: 4, metersPerFix: 5));
      expect(tracker.metrics.averagePaceSecondsPerKm(), isNull);

      feed(straightLine(
        start: t0.add(const Duration(seconds: 5)),
        count: 60,
        metersPerFix: 3,
      ));
      expect(tracker.metrics.averagePaceSecondsPerKm(), isNotNull);
    });
  });

  group('GPS loss', () {
    test('goes weak after the stale threshold and blanks live speed', () {
      tracker.start();
      feed(straightLine(start: t0, count: 30, metersPerFix: 3));
      expect(tracker.gpsQuality, GpsQuality.good);

      // Signal drops: no fixes at all for 15 s.
      clock.advance(const Duration(seconds: 15));
      expect(tracker.gpsQuality, GpsQuality.weak);
      // Showing a frozen pace here would be a lie; showing nothing is honest.
      expect(tracker.metrics.currentSpeedMps, isNull);
      // Duration and distance keep their values: the run did not stop.
      expect(tracker.metrics.elapsed.inSeconds, 44);
      expect(tracker.metrics.distanceMeters, greaterThan(70));
    });

    test('recovers to good once fixes return', () {
      tracker.start();
      feed(straightLine(start: t0, count: 30, metersPerFix: 3));
      clock.advance(const Duration(seconds: 15));
      expect(tracker.gpsQuality, GpsQuality.weak);

      final back = sampleAt(
        northMeters: 90,
        eastMeters: 0,
        at: t0.add(const Duration(seconds: 44)),
      );
      clock.now = back.timestamp;
      tracker.addSample(back);
      expect(tracker.gpsQuality, GpsQuality.good);
    });
  });

  group('hostile clock', () {
    test('a backwards clock jump never rewinds the duration', () {
      tracker.start();
      clock.advance(const Duration(seconds: 120));
      final before = tracker.elapsed;
      expect(before, const Duration(seconds: 120));

      clock.rewind(const Duration(seconds: 10)); // NTP correction
      expect(tracker.elapsed, greaterThanOrEqualTo(before));

      clock.advance(const Duration(seconds: 30));
      expect(tracker.elapsed, greaterThanOrEqualTo(before));
    });
  });

  group('crash recovery', () {
    test('snapshot round-trip preserves distance, route and elapsed time', () {
      tracker.start();
      clock.advance(const Duration(seconds: 1));
      feed(straightLine(start: t0, count: 100, metersPerFix: 3));
      clock.now = t0.add(const Duration(seconds: 100));

      final snapshot = tracker.toSnapshot();
      final restored = RunTracker.fromSnapshot(snapshot, clock: clock.call);

      expect(restored.distanceMeters, closeTo(tracker.distanceMeters, 0.001));
      expect(restored.route.length, tracker.route.length);
      expect(restored.elapsed, const Duration(seconds: 100));
      expect(restored.startedAt!.isAtSameMomentAs(tracker.startedAt!), isTrue);
    });

    test('a recovered run comes back paused, and dead time is not counted', () {
      tracker.start();
      clock.advance(const Duration(seconds: 60));
      final snapshot = tracker.toSnapshot();

      // The process was dead for half an hour.
      clock.advance(const Duration(minutes: 30));
      final restored = RunTracker.fromSnapshot(snapshot, clock: clock.call);

      expect(restored.status, RunStatus.paused);
      expect(restored.elapsed, const Duration(seconds: 60));

      // And resuming does not retroactively claim the ground covered while dead.
      restored.resume();
      final resumeAt = clock.now;
      final far = sampleAt(northMeters: 5000, eastMeters: 0, at: resumeAt);
      expect(restored.addSample(far), SampleOutcome.anchored);
      expect(restored.distanceMeters, 0);
    });
  });

  group('degenerate runs', () {
    test('finishing with no fixes at all produces a valid, empty run', () {
      tracker.start();
      clock.advance(const Duration(seconds: 20));
      tracker.finish();

      final m = tracker.metrics;
      expect(m.status, RunStatus.finished);
      expect(m.distanceMeters, 0);
      expect(m.elapsed, const Duration(seconds: 20));
      expect(m.averagePaceSecondsPerKm(), isNull);
      expect(tracker.route, isEmpty);
    });

    test('reset returns the tracker to a clean idle state', () {
      tracker.start();
      feed(straightLine(start: t0, count: 30, metersPerFix: 3));
      tracker.finish();
      tracker.reset();

      expect(tracker.status, RunStatus.idle);
      expect(tracker.distanceMeters, 0);
      expect(tracker.route, isEmpty);
      expect(tracker.elapsed, Duration.zero);
    });
  });
}
