import 'seat.dart';

/// Rol asignado a una persona detectada.
enum OccupantRole { driver, passenger }

/// Una persona detectada. Coordenadas normalizadas (0..1) sobre la imagen
/// tal y como se muestra en pantalla (ya rotada y, si es cámara frontal,
/// espejada), de modo que los asientos coinciden con lo que ve el usuario.
class Detection {
  final double left;
  final double top;
  final double right;
  final double bottom;
  final double score;
  final OccupantRole role;

  /// ID estable que asigna el [PersonTracker] (null = sin seguimiento).
  final int? trackId;
  final SeatId? seat;

  const Detection({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    required this.score,
    this.role = OccupantRole.passenger,
    this.trackId,
    this.seat,
  });

  /// Centroide normalizado: Cx = (xmin + xmax) / (2 · ancho).
  double get cx => (left + right) / 2;
  double get cy => (top + bottom) / 2;
  double get width => right - left;
  double get height => bottom - top;
  double get area => width * height;

  Detection copyWith({
    OccupantRole? role,
    int? trackId,
    SeatId? seat,
    bool clearSeat = false,
  }) =>
      Detection(
        left: left,
        top: top,
        right: right,
        bottom: bottom,
        score: score,
        role: role ?? this.role,
        trackId: trackId ?? this.trackId,
        seat: clearSeat ? null : seat ?? this.seat,
      );

  double iou(Detection o) {
    final iw = (right < o.right ? right : o.right) -
        (left > o.left ? left : o.left);
    final ih = (bottom < o.bottom ? bottom : o.bottom) -
        (top > o.top ? top : o.top);
    if (iw <= 0 || ih <= 0) return 0;
    final inter = iw * ih;
    return inter / (area + o.area - inter);
  }

  /// El isolate de inferencia devuelve [l, t, r, b, score] * n.
  static List<Detection> fromFlat(List<double> flat) => [
        for (var i = 0; i + 4 < flat.length; i += 5)
          Detection(
            left: flat[i],
            top: flat[i + 1],
            right: flat[i + 2],
            bottom: flat[i + 3],
            score: flat[i + 4],
          ),
      ];
}
