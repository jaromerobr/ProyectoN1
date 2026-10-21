import 'dart:convert';

import 'seat.dart';

enum TripSource { live, simulation }

/// Tramo de tiempo que un pasajero pasó en un asiento (null = en movimiento
/// o fuera de los asientos calibrados).
class SeatSegment {
  final SeatId? seat;
  final DateTime from;
  final DateTime to;

  const SeatSegment(this.seat, this.from, this.to);

  Duration get duration => to.difference(from);

  Map<String, Object?> toJson() => {
        's': seat?.name,
        'a': from.millisecondsSinceEpoch,
        'b': to.millisecondsSinceEpoch,
      };

  static SeatSegment fromJson(Map<String, dynamic> m) => SeatSegment(
        SeatId.tryParse(m['s'] as String?),
        DateTime.fromMillisecondsSinceEpoch(m['a'] as int),
        DateTime.fromMillisecondsSinceEpoch(m['b'] as int),
      );
}

/// Un pasajero dentro de una carrera: cuándo subió, cuándo bajó y por qué
/// asientos pasó ([segments], en orden).
class PassengerStint {
  final int number;
  final DateTime enter;
  final DateTime exit;
  final List<SeatSegment> segments;

  PassengerStint(this.number, this.enter, this.exit,
      [List<SeatSegment>? segments])
      : segments = segments ?? const [];

  Duration get duration => exit.difference(enter);

  /// Asiento donde pasó más tiempo.
  SeatId? get seat {
    final t = <SeatId, Duration>{};
    for (final s in segments) {
      if (s.seat != null) t[s.seat!] = (t[s.seat!] ?? Duration.zero) + s.duration;
    }
    if (t.isEmpty) return null;
    return t.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
  }

  /// Asientos distintos por los que pasó, en orden de visita.
  List<SeatId> get seatPath {
    final out = <SeatId>[];
    for (final s in segments) {
      if (s.seat != null && (out.isEmpty || out.last != s.seat)) out.add(s.seat!);
    }
    return out;
  }

  bool get changedSeat => seatPath.toSet().length > 1;

  Map<String, Object?> toMap(int tripId) => {
        'carrera_id': tripId,
        'numero': number,
        'asiento': seat?.name,
        'entrada': enter.millisecondsSinceEpoch,
        'salida': exit.millisecondsSinceEpoch,
        'recorrido': jsonEncode([for (final s in segments) s.toJson()]),
      };

  factory PassengerStint.fromMap(Map<String, Object?> m) {
    final enter = DateTime.fromMillisecondsSinceEpoch(m['entrada'] as int);
    final exit = DateTime.fromMillisecondsSinceEpoch(m['salida'] as int);
    var segments = <SeatSegment>[];
    final raw = m['recorrido'] as String?;
    if (raw != null && raw.isNotEmpty) {
      try {
        segments = [
          for (final j in jsonDecode(raw) as List)
            SeatSegment.fromJson(j as Map<String, dynamic>),
        ];
      } catch (_) {}
    }
    // Filas de versiones anteriores: un único asiento para todo el tramo.
    if (segments.isEmpty) {
      segments = [
        SeatSegment(SeatId.tryParse(m['asiento'] as String?), enter, exit)
      ];
    }
    return PassengerStint(m['numero'] as int, enter, exit, segments);
  }
}

/// Punto GPS con dirección opcional (resuelta al guardar si hay red).
class GeoPoint {
  final double lat, lng;
  final String? address;
  const GeoPoint(this.lat, this.lng, [this.address]);

  GeoPoint withAddress(String? a) => GeoPoint(lat, lng, a);

  String get label =>
      address ?? '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}';
}

class TripRecord {
  final int? id;
  final DateTime start;
  final DateTime end;
  final int maxPassengers;
  final TripSource source;
  final List<PassengerStint> passengers;

  /// Conductor y turno activos cuando se registró la carrera.
  final String? driver;
  final int? shiftId;

  /// Origen, destino y distancia recorrida (GPS), si estaban disponibles.
  final GeoPoint? origin;
  final GeoPoint? destination;
  final double? distanceMeters;

  /// Carpeta con las fotos de evidencia de la carrera (si se guardaron).
  final String? evidenceDir;

  /// Cuándo la borró el conductor (solo la ve el propietario).
  final DateTime? deletedAt;

  bool get deleted => deletedAt != null;

  const TripRecord({
    this.id,
    required this.start,
    required this.end,
    required this.maxPassengers,
    required this.source,
    this.passengers = const [],
    this.driver,
    this.shiftId,
    this.origin,
    this.destination,
    this.distanceMeters,
    this.evidenceDir,
    this.deletedAt,
  });

  Duration get duration => end.difference(start);

  double? get distanceKm =>
      distanceMeters == null ? null : distanceMeters! / 1000;

  /// Asientos usados durante la carrera (en cualquier momento), en orden.
  List<SeatId> get seats => {
        for (final p in passengers)
          for (final s in p.segments)
            if (s.seat != null) s.seat!,
      }.toList()
        ..sort((a, b) => a.index.compareTo(b.index));

  int get seatChanges => passengers.where((p) => p.changedSeat).length;

  TripRecord copyWith({
    int? id,
    String? driver,
    int? shiftId,
    GeoPoint? origin,
    GeoPoint? destination,
    double? distanceMeters,
    String? evidenceDir,
  }) =>
      TripRecord(
        id: id ?? this.id,
        start: start,
        end: end,
        maxPassengers: maxPassengers,
        source: source,
        passengers: passengers,
        driver: driver ?? this.driver,
        shiftId: shiftId ?? this.shiftId,
        origin: origin ?? this.origin,
        destination: destination ?? this.destination,
        distanceMeters: distanceMeters ?? this.distanceMeters,
        evidenceDir: evidenceDir ?? this.evidenceDir,
        deletedAt: deletedAt,
      );

  TripRecord withId(int id) => copyWith(id: id);

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'timestamp_inicio': start.millisecondsSinceEpoch,
        'timestamp_fin': end.millisecondsSinceEpoch,
        'duracion_ms': duration.inMilliseconds,
        'max_pasajeros': maxPassengers,
        'fuente': source.name,
        'asientos': seats.map((s) => s.name).join(','),
        'conductor': driver,
        'turno_id': shiftId,
        'lat_ini': origin?.lat,
        'lng_ini': origin?.lng,
        'dir_ini': origin?.address,
        'lat_fin': destination?.lat,
        'lng_fin': destination?.lng,
        'dir_fin': destination?.address,
        'distancia_m': distanceMeters,
        'evidencias': evidenceDir,
      };

  static GeoPoint? _geo(Object? lat, Object? lng, Object? addr) =>
      lat == null || lng == null
          ? null
          : GeoPoint((lat as num).toDouble(), (lng as num).toDouble(),
              addr as String?);

  factory TripRecord.fromMap(Map<String, Object?> m,
          [List<PassengerStint> passengers = const []]) =>
      TripRecord(
        id: m['id'] as int?,
        start: DateTime.fromMillisecondsSinceEpoch(m['timestamp_inicio'] as int),
        end: DateTime.fromMillisecondsSinceEpoch(m['timestamp_fin'] as int),
        maxPassengers: m['max_pasajeros'] as int,
        source: TripSource.values.byName(m['fuente'] as String),
        passengers: passengers,
        driver: m['conductor'] as String?,
        shiftId: m['turno_id'] as int?,
        origin: _geo(m['lat_ini'], m['lng_ini'], m['dir_ini']),
        destination: _geo(m['lat_fin'], m['lng_fin'], m['dir_fin']),
        distanceMeters: (m['distancia_m'] as num?)?.toDouble(),
        evidenceDir: m['evidencias'] as String?,
        deletedAt: m['borrada'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(m['borrada'] as int),
      );
}

/// Turno de un conductor.
class Shift {
  final int? id;
  final String driver;
  final DateTime start;
  final DateTime? end;

  const Shift({this.id, required this.driver, required this.start, this.end});

  bool get active => end == null;

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'conductor': driver,
        'inicio': start.millisecondsSinceEpoch,
        'fin': end?.millisecondsSinceEpoch,
      };

  factory Shift.fromMap(Map<String, Object?> m) => Shift(
        id: m['id'] as int,
        driver: m['conductor'] as String,
        start: DateTime.fromMillisecondsSinceEpoch(m['inicio'] as int),
        end: m['fin'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(m['fin'] as int),
      );
}
