import 'dart:async';

import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';

import '../models/trip_record.dart';

/// Origen, destino y distancia de una carrera por GPS.
///
/// - [start] al abrir la carrera: toma la posición y empieza a sumar la
///   distancia recorrida (un punto cada ≥25 m).
/// - [stop] al cerrarla: devuelve origen, destino y metros. Las direcciones
///   se buscan al final y solo si hay red; si no, quedan las coordenadas.
class TripLocation {
  StreamSubscription<Position>? _sub;
  Position? _origin, _last;
  double _meters = 0;

  static Future<bool> ensurePermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) return false;
    var p = await Geolocator.checkPermission();
    if (p == LocationPermission.denied) {
      p = await Geolocator.requestPermission();
    }
    return p == LocationPermission.whileInUse || p == LocationPermission.always;
  }

  static Future<bool> hasPermission() async {
    final p = await Geolocator.checkPermission();
    return p == LocationPermission.whileInUse || p == LocationPermission.always;
  }

  bool get active => _sub != null;

  Future<void> start() async {
    await _sub?.cancel();
    _origin = _last = null;
    _meters = 0;
    if (!await hasPermission()) return;
    try {
      _origin = _last = await Geolocator.getLastKnownPosition();
    } catch (_) {}
    _sub = Geolocator.getPositionStream(
      locationSettings: AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 25,
        intervalDuration: const Duration(seconds: 5),
      ),
    ).listen(_onPosition, onError: (_) {});
    // Posición fresca para el origen (la última conocida puede ser vieja).
    Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 15)),
    ).then<void>((p) {
      _origin = p;
      _last ??= p;
    }).catchError((_) {});
  }

  void _onPosition(Position p) {
    // Descarta lecturas imprecisas (túneles, edificios).
    if (p.accuracy > 50) return;
    if (_last != null) {
      _meters += Geolocator.distanceBetween(
          _last!.latitude, _last!.longitude, p.latitude, p.longitude);
    }
    _last = p;
    _origin ??= p;
  }

  /// Termina el seguimiento y devuelve (origen, destino, metros).
  Future<(GeoPoint?, GeoPoint?, double?)> stop() async {
    await _sub?.cancel();
    _sub = null;
    final o = _origin, d = _last;
    if (o == null || d == null) return (null, null, null);
    final origin = GeoPoint(o.latitude, o.longitude, await _address(o));
    final dest = GeoPoint(d.latitude, d.longitude, await _address(d));
    return (origin, dest, _meters);
  }

  static Future<String?> _address(Position p) async {
    try {
      final marks = await Geocoding()
          .placemarkFromCoordinates(p.latitude, p.longitude)
          .timeout(const Duration(seconds: 4));
      if (marks.isEmpty) return null;
      final m = marks.first;
      final street = [m.thoroughfare, m.subThoroughfare]
          .whereType<String>()
          .where((x) => x.isNotEmpty)
          .join(' ');
      final area =
          m.subLocality?.isNotEmpty == true ? m.subLocality : m.locality;
      final out = [street, area]
          .whereType<String>()
          .where((x) => x.isNotEmpty)
          .join(', ');
      return out.isEmpty ? null : out;
    } catch (_) {
      return null; // sin red: se guardan solo coordenadas
    }
  }

  Future<void> dispose() async => _sub?.cancel();
}
