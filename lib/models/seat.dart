/// Asientos del vehículo. Izquierda/derecha se refieren a cómo se ven en la
/// imagen de la cámara.
enum SeatId {
  driver('Conductor', 'C'),
  copilot('Copiloto', 'CP'),
  rearLeft('Trasero izq.', 'TI'),
  rearCenter('Trasero centro', 'TC'),
  rearRight('Trasero der.', 'TD');

  final String label;
  final String short;
  const SeatId(this.label, this.short);

  static SeatId? tryParse(String? name) =>
      SeatId.values.where((s) => s.name == name).firstOrNull;
}

/// Punto calibrado de un asiento, normalizado (0..1) sobre la imagen.
class SeatPoint {
  final SeatId id;
  final double x, y;
  final bool enabled;

  const SeatPoint(this.id, this.x, this.y, {this.enabled = true});

  SeatPoint copyWith({double? x, double? y, bool? enabled}) =>
      SeatPoint(id, x ?? this.x, y ?? this.y, enabled: enabled ?? this.enabled);

  Map<String, Object> toJson() =>
      {'id': id.name, 'x': x, 'y': y, 'on': enabled};

  static SeatPoint? fromJson(Map<String, dynamic> m) {
    final id = SeatId.tryParse(m['id'] as String?);
    if (id == null) return null;
    return SeatPoint(id, (m['x'] as num).toDouble(), (m['y'] as num).toDouble(),
        enabled: m['on'] as bool? ?? true);
  }

  /// Posiciones iniciales (cámara al frente mirando hacia atrás, en vertical,
  /// conductor a la izquierda de la imagen). Se recalibran tocando la imagen.
  static const defaults = <SeatPoint>[
    SeatPoint(SeatId.driver, 0.22, 0.62),
    SeatPoint(SeatId.copilot, 0.78, 0.62),
    SeatPoint(SeatId.rearLeft, 0.30, 0.38),
    SeatPoint(SeatId.rearCenter, 0.50, 0.36),
    SeatPoint(SeatId.rearRight, 0.70, 0.38),
  ];
}
