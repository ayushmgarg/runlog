import 'package:flutter_test/flutter_test.dart';
import 'package:plexqo_run/ui/format.dart';

void main() {
  group('distance', () {
    test('switches from metres to kilometres at 1 km', () {
      expect(Fmt.distance(0), '0 m');
      expect(Fmt.distance(1), '1 m');
      expect(Fmt.distance(999), '999 m');
      expect(Fmt.distance(1000), '1.00 km');
      expect(Fmt.distance(1049), '1.05 km');
      expect(Fmt.distance(12345), '12.35 km');
    });

    test('value and unit split the same way the combined form does', () {
      expect(Fmt.distanceValue(843), '843');
      expect(Fmt.distanceUnit(843), 'M');
      expect(Fmt.distanceValue(2340), '2.34');
      expect(Fmt.distanceUnit(2340), 'KM');
    });

    test('survives garbage input without throwing', () {
      expect(Fmt.distance(double.nan), '0 m');
      expect(Fmt.distance(-5), '0 m');
      expect(Fmt.distanceValue(double.nan), '0');
    });
  });

  group('duration', () {
    test('drops the hour field below an hour and adds it above', () {
      expect(Fmt.duration(Duration.zero), '00:00');
      expect(Fmt.duration(const Duration(seconds: 7)), '00:07');
      expect(Fmt.duration(const Duration(minutes: 14, seconds: 8)), '14:08');
      expect(Fmt.duration(const Duration(minutes: 59, seconds: 59)), '59:59');
      expect(Fmt.duration(const Duration(hours: 1)), '1:00:00');
      expect(
        Fmt.duration(const Duration(hours: 2, minutes: 5, seconds: 3)),
        '2:05:03',
      );
    });

    test('clamps a negative duration to zero', () {
      expect(Fmt.duration(const Duration(seconds: -5)), '00:00');
    });
  });

  group('pace', () {
    test('formats minutes and seconds per kilometre', () {
      expect(Fmt.pace(342), '5:42');
      expect(Fmt.pace(360), '6:00');
      expect(Fmt.pace(65), '1:05');
    });

    test('shows a placeholder rather than inventing a number', () {
      // The whole point: an unknown pace must never render as 0:00.
      expect(Fmt.pace(null), Fmt.noValue);
      expect(Fmt.pace(0), Fmt.noValue);
      expect(Fmt.pace(-10), Fmt.noValue);
      expect(Fmt.pace(double.nan), Fmt.noValue);
      expect(Fmt.pace(double.infinity), Fmt.noValue);
    });

    test('clamps absurdly slow paces instead of showing five digits', () {
      expect(Fmt.pace(99 * 60 + 59), '99:59');
      expect(Fmt.pace(500000), '99:59');
    });
  });

  group('speed', () {
    test('shows one decimal, and a placeholder when unknown', () {
      expect(Fmt.speed(10.54), '10.5');
      expect(Fmt.speed(0), '0.0');
      expect(Fmt.speed(null), Fmt.noNumber);
      expect(Fmt.speed(double.nan), Fmt.noNumber);
    });
  });

  group('date', () {
    test('renders a fixed, locale-free format', () {
      expect(
        Fmt.dateTime(DateTime(2026, 9, 11, 7, 12)),
        'Fri 11 Sep, 07:12',
      );
      expect(
        Fmt.dateTime(DateTime(2026, 1, 5, 19, 4)),
        'Mon 5 Jan, 19:04',
      );
    });
  });

  group('semantics', () {
    test('spell out the numbers a screen reader cannot infer', () {
      expect(Fmt.distanceSemantics(843), 'Distance 843 metres');
      expect(Fmt.distanceSemantics(2340), 'Distance 2.34 kilometres');
      expect(
        Fmt.durationSemantics(const Duration(minutes: 14, seconds: 8)),
        'Duration 14 minutes 8 seconds',
      );
      expect(Fmt.paceSemantics(null), 'Pace not available yet');
      expect(
        Fmt.paceSemantics(342),
        'Pace 5 minutes 42 seconds per kilometre',
      );
    });
  });
}
