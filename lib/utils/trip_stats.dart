import '../models/seat.dart';
import '../models/trip_record.dart';

enum StatsRange {
  today('Hoy'),
  week('7 días'),
  month('30 días'),
  all('Todo');

  final String label;
  const StatsRange(this.label);

  /// Primer instante incluido, o null para todo.
  DateTime? since(DateTime now) {
    final midnight = DateTime(now.year, now.month, now.day);
    return switch (this) {
      StatsRange.today => midnight,
      StatsRange.week => midnight.subtract(const Duration(days: 6)),
      StatsRange.month => midnight.subtract(const Duration(days: 29)),
      StatsRange.all => null,
    };
  }
}

List<TripRecord> inRange(List<TripRecord> trips, StatsRange r, DateTime now) {
  final since = r.since(now);
  return since == null
      ? trips
      : trips.where((t) => !t.start.isBefore(since)).toList();
}

/// Carreras que empezaron entre [from] (incluido) y [to] (excluido).
List<TripRecord> between(List<TripRecord> trips, DateTime from, DateTime to) =>
    trips
        .where((t) => !t.start.isBefore(from) && t.start.isBefore(to))
        .toList();

/// Número de carreras que empezaron en cada hora del día (0..23).
List<int> tripsPerHour(List<TripRecord> trips) {
  final h = List<int>.filled(24, 0);
  for (final t in trips) {
    h[t.start.hour]++;
  }
  return h;
}

/// Carreras por día de los últimos [days] días (el último es hoy).
List<(DateTime, int)> tripsPerDay(
    List<TripRecord> trips, int days, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  return [
    for (var i = days - 1; i >= 0; i--)
      () {
        final d = today.subtract(Duration(days: i));
        return (d, between(trips, d, d.add(const Duration(days: 1))).length);
      }(),
  ];
}

const durationBucketLabels = ['< 5', '5–10', '10–20', '20–40', '40+'];

/// Carreras por rango de duración en minutos ([durationBucketLabels]).
List<int> durationBuckets(List<TripRecord> trips) {
  final b = List<int>.filled(5, 0);
  for (final t in trips) {
    final m = t.duration.inSeconds / 60;
    b[m < 5
        ? 0
        : m < 10
            ? 1
            : m < 20
                ? 2
                : m < 40
                    ? 3
                    : 4]++;
  }
  return b;
}

/// Carreras según el máximo de pasajeros a la vez: [1, 2, 3, 4+].
List<int> occupancyDistribution(List<TripRecord> trips) {
  final d = List<int>.filled(4, 0);
  for (final t in trips) {
    d[(t.maxPassengers.clamp(1, 4)) - 1]++;
  }
  return d;
}

/// Cuántas carreras usaron cada asiento.
Map<SeatId, int> seatUsage(List<TripRecord> trips) {
  final m = {for (final s in SeatId.values) s: 0};
  for (final t in trips) {
    for (final s in t.seats) {
      m[s] = m[s]! + 1;
    }
  }
  return m;
}

/// Tiempo total que los pasajeros pasaron en cada asiento.
Map<SeatId, Duration> seatTime(List<TripRecord> trips) {
  final m = {for (final s in SeatId.values) s: Duration.zero};
  for (final t in trips) {
    for (final p in t.passengers) {
      for (final seg in p.segments) {
        if (seg.seat != null) m[seg.seat!] = m[seg.seat!]! + seg.duration;
      }
    }
  }
  return m;
}

Duration totalDuration(List<TripRecord> trips) =>
    trips.fold(Duration.zero, (s, t) => s + t.duration);

Duration averageDuration(List<TripRecord> trips) =>
    trips.isEmpty ? Duration.zero : totalDuration(trips) ~/ trips.length;

int totalPassengers(List<TripRecord> trips) => trips.fold(
    0, (s, t) => s + (t.passengers.isNotEmpty ? t.passengers.length : t.maxPassengers));

/// Variación porcentual legible ("+25 %", "−10 %") o null si no aplica.
String? percentDelta(num now, num before) {
  if (before == 0) return null;
  final p = ((now - before) / before * 100).round();
  return '${p >= 0 ? '+' : '−'}${p.abs()} %';
}
