class Fmt {
  Fmt._();
  static const String noValue = '--:--';
  static const String noNumber = '--';

  static String distance(double meters) {
    if (meters.isNaN || meters < 0) return '0 m';
    if (meters < 1000) return '${meters.round()} m';
    return '${(meters / 1000).toStringAsFixed(2)} km';
  }

  static String distanceUnit(double meters) =>
      (meters.isNaN || meters < 1000) ? 'M' : 'KM';

  static String distanceValue(double meters) {
    if (meters.isNaN || meters < 0) return '0';
    if (meters < 1000) return meters.round().toString();
    return (meters / 1000).toStringAsFixed(2);
  }

  static String duration(Duration d) {
    if (d.isNegative) d = Duration.zero;
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60);
    final seconds = d.inSeconds.remainder(60);
    final mm = minutes.toString().padLeft(2, '0');
    final ss = seconds.toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$mm:$ss' : '$mm:$ss';
  }

  static String pace(double? secondsPerKm) {
    if (secondsPerKm == null ||
        secondsPerKm.isNaN ||
        secondsPerKm.isInfinite ||
        secondsPerKm <= 0) {
      return noValue;
    }
    final total = secondsPerKm.round();
    if (total > 99 * 60 + 59) return '99:59';
    final minutes = total ~/ 60;
    final seconds = total % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  static String speed(double? kmh) {
    if (kmh == null || kmh.isNaN || kmh.isInfinite || kmh < 0) return noNumber;
    return kmh.toStringAsFixed(1);
  }

  static const List<String> _weekdays = [
    'Mon',
    'Tue',
    'Wed',
    'Thu',
    'Fri',
    'Sat',
    'Sun',
  ];

  static const List<String> _months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  static String dateTime(DateTime t) {
    final weekday = _weekdays[t.weekday - 1];
    final month = _months[t.month - 1];
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    return '$weekday ${t.day} $month, $hh:$mm';
  }

  static String distanceSemantics(double meters) {
    if (meters < 1000) return 'Distance ${meters.round()} metres';
    return 'Distance ${(meters / 1000).toStringAsFixed(2)} kilometres';
  }

  static String durationSemantics(Duration d) {
    final parts = <String>[];
    if (d.inHours > 0) parts.add('${d.inHours} hours');
    if (d.inMinutes.remainder(60) > 0) {
      parts.add('${d.inMinutes.remainder(60)} minutes');
    }
    parts.add('${d.inSeconds.remainder(60)} seconds');
    return 'Duration ${parts.join(' ')}';
  }

  static String paceSemantics(double? secondsPerKm) {
    if (secondsPerKm == null) return 'Pace not available yet';
    final total = secondsPerKm.round();
    return 'Pace ${total ~/ 60} minutes ${total % 60} seconds per kilometre';
  }
}
