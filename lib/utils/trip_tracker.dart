import 'dart:math' as math;

/// Carrera cerrada por el [TripTracker].
class CompletedTrip {
  final DateTime start;
  final DateTime end;
  final int maxPassengers;
  const CompletedTrip(this.start, this.end, this.maxPassengers);
  Duration get duration => end.difference(start);
}

enum TripState { idle, confirming, inTrip }

/// Máquina de estados del cronómetro de carrera. No conoce relojes: recibe el
/// instante de cada fotograma, así funciona igual con la cámara (hora real) y
/// con un vídeo (tiempo del vídeo), y se puede probar sin esperar.
///
/// - idle → confirming: aparece ≥1 pasajero.
/// - confirming → inTrip: el pasajero sigue presente [enterConfirm]. La hora de
///   inicio es la del primer fotograma en que se vio.
/// - inTrip → idle: 0 pasajeros durante más de [exitGrace]. La hora de fin es
///   la del primer fotograma sin pasajeros.
class TripTracker {
  final Duration enterConfirm;
  final Duration exitGrace;

  /// Un conteo solo cuenta para [maxPassengers] si se repite en estos
  /// fotogramas consecutivos (filtra duplicados puntuales del detector).
  final int stableFrames;

  TripTracker({
    this.enterConfirm = const Duration(seconds: 1),
    this.exitGrace = const Duration(seconds: 5),
    this.stableFrames = 3,
  });

  TripState _state = TripState.idle;
  DateTime? _candidateStart;
  DateTime? _tripStart;
  DateTime? _zeroSince;
  int _maxPassengers = 0;
  final List<int> _recent = [];

  TripState get state => _state;
  bool get inTrip => _state == TripState.inTrip;
  DateTime? get tripStart => _tripStart;
  int get maxPassengers => _maxPassengers;

  /// Segundos que lleva la carrera sin pasajeros (cuenta atrás de cierre).
  Duration? emptyFor(DateTime now) =>
      inTrip && _zeroSince != null ? now.difference(_zeroSince!) : null;

  Duration elapsed(DateTime now) =>
      _tripStart == null ? Duration.zero : now.difference(_tripStart!);

  /// Procesa un fotograma. Devuelve la carrera si se acaba de cerrar.
  CompletedTrip? update(int passengers, DateTime t) {
    _recent.add(passengers);
    if (_recent.length > stableFrames) _recent.removeAt(0);
    final stable = _recent.length == stableFrames ? _recent.reduce(math.min) : 0;

    switch (_state) {
      case TripState.idle:
        if (passengers > 0) {
          _candidateStart = t;
          _state = TripState.confirming;
          _maxPassengers = 0;
          _checkConfirm(t, stable, passengers);
        }
        return null;

      case TripState.confirming:
        if (passengers == 0) {
          _state = TripState.idle;
          _candidateStart = null;
          return null;
        }
        _checkConfirm(t, stable, passengers);
        return null;

      case TripState.inTrip:
        _maxPassengers = math.max(_maxPassengers, stable);
        if (passengers > 0) {
          _zeroSince = null;
          return null;
        }
        _zeroSince ??= t;
        if (t.difference(_zeroSince!) > exitGrace) return _close(_zeroSince!);
        return null;
    }
  }

  void _checkConfirm(DateTime t, int stable, int passengers) {
    if (t.difference(_candidateStart!) >= enterConfirm) {
      _state = TripState.inTrip;
      _tripStart = _candidateStart;
      _zeroSince = null;
      // Si aún no hay suficientes fotogramas para un conteo estable, al menos 1.
      _maxPassengers = math.max(1, stable);
    }
  }

  /// Une la carrera que se acaba de abrir con una anterior que terminó hace
  /// poco (el pasajero dejó de verse un rato): conserva su inicio y máximo.
  void continueFrom(DateTime start, int maxPassengers) {
    if (!inTrip) return;
    _tripStart = start;
    _maxPassengers = math.max(_maxPassengers, maxPassengers);
  }

  /// Cierra la carrera en curso (p. ej. al salir de la pantalla).
  CompletedTrip? forceEnd(DateTime t) {
    if (inTrip) return _close(_zeroSince ?? t);
    _reset();
    return null;
  }

  CompletedTrip _close(DateTime end) {
    final trip = CompletedTrip(_tripStart!, end, math.max(1, _maxPassengers));
    _reset();
    return trip;
  }

  void _reset() {
    _state = TripState.idle;
    _candidateStart = null;
    _tripStart = null;
    _zeroSince = null;
    _maxPassengers = 0;
  }
}
