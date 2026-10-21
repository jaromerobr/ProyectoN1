import 'dart:math' as math;

import '../models/app_settings.dart';
import '../models/detection.dart';
import '../models/seat.dart';

/// Asigna personas a asientos calibrados.
///
/// Una persona puede ocupar un asiento si su caja cubre el punto del asiento o
/// si su centroide está a menos de [radius]. Se asigna por cercanía, y cada
/// asiento admite como mucho una persona. Por eso solo puede haber un
/// conductor, y quien va detrás de él queda en un asiento trasero (o sin
/// asiento), pero nunca como conductor.
class RoiEvaluator {
  final List<SeatPoint> seats;
  final double radius;

  /// Polígono de cabina (null = sin jaula, cuenta toda la imagen).
  final List<(double, double)>? cabin;

  const RoiEvaluator(
      {this.seats = SeatPoint.defaults, this.radius = 0.15, this.cabin});

  /// ¿El centro de la persona está dentro de la cabina?
  bool insideCabin(Detection d) {
    final poly = cabin;
    if (poly == null || poly.length < 3) return true;
    final x = d.cx, y = d.cy;
    var inside = false;
    for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
      final (xi, yi) = poly[i];
      final (xj, yj) = poly[j];
      if ((yi > y) != (yj > y) &&
          x < (xj - xi) * (y - yi) / (yj - yi) + xi) {
        inside = !inside;
      }
    }
    return inside;
  }

  factory RoiEvaluator.fromSettings(AppSettings s) =>
      RoiEvaluator(
          seats: s.seats,
          radius: s.seatRadius,
          cabin: s.cabinEnabled ? s.cabin : null);

  static bool contains(Detection d, SeatPoint s) =>
      s.x >= d.left && s.x <= d.right && s.y >= d.top && s.y <= d.bottom;

  static double distance(Detection d, SeatPoint s) =>
      math.sqrt(math.pow(d.cx - s.x, 2) + math.pow(d.cy - s.y, 2));

  /// Asiento de cada detección en este fotograma (null = ninguno).
  List<SeatId?> assignSeats(List<Detection> ds) {
    final pairs = <(int, SeatId, double)>[];
    for (var i = 0; i < ds.length; i++) {
      for (final s in seats) {
        if (!s.enabled) continue;
        final dist = distance(ds[i], s);
        if (contains(ds[i], s) || dist <= radius) pairs.add((i, s.id, dist));
      }
    }
    pairs.sort((a, b) => a.$3.compareTo(b.$3));

    final result = List<SeatId?>.filled(ds.length, null);
    final taken = <SeatId>{};
    for (final (i, seat, _) in pairs) {
      if (result[i] != null || taken.contains(seat)) continue;
      result[i] = seat;
      taken.add(seat);
    }
    return result;
  }

  /// Clasificación de un solo fotograma (sin seguimiento).
  List<Detection> classify(List<Detection> ds) {
    final seatsOf = assignSeats(ds);
    return [
      for (var i = 0; i < ds.length; i++)
        ds[i].copyWith(
          seat: seatsOf[i],
          clearSeat: seatsOf[i] == null,
          role: seatsOf[i] == SeatId.driver
              ? OccupantRole.driver
              : OccupantRole.passenger,
        ),
    ];
  }

  static int countPassengers(List<Detection> classified) =>
      classified.where((d) => d.role == OccupantRole.passenger).length;
}
