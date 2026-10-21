import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/app_settings.dart';
import '../models/detection.dart';
import '../models/seat.dart';
import '../models/trip_record.dart';
import '../utils/person_tracker.dart';
import '../utils/roi_evaluator.dart';
import '../utils/trip_tracker.dart';
import 'database_helper.dart';
import 'evidence_store.dart';
import 'yolo_detector_service.dart';

enum SessionEventKind {
  tripStart,
  entered,
  seatChange,
  exited,
  tripEnd,

  /// Carrera descartada por durar menos del mínimo.
  discarded,

  /// Una carrera recién abierta se unió a la anterior (hueco corto).
  resumed,
}

/// Algo que pasó en la cabina (para el registro en vivo).
class SessionEvent {
  final SessionEventKind kind;
  final DateTime time;
  final int? trackId;
  final SeatId? from, to;
  final Duration? duration;

  const SessionEvent(this.kind, this.time,
      {this.trackId, this.from, this.to, this.duration});
}

/// Recorrido de una persona seguida mientras se forma la carrera.
class _Stint {
  final int trackId;
  final DateTime enter;
  DateTime exit;
  bool exitReported = false;

  /// (asiento, desde) cada vez que cambia el asiento estable.
  final List<(SeatId?, DateTime)> changes = [];

  _Stint(this.trackId, this.enter) : exit = enter;

  SeatId? get lastSeat =>
      changes.lastWhere((c) => c.$1 != null, orElse: () => (null, enter)).$1;

  /// Asiento confirmado para los eventos en vivo y candidato a cambio.
  SeatId? _confirmed;
  (SeatId, DateTime)? _candidate;

  /// Devuelve (anterior, nuevo) cuando el cambio de asiento se confirma: el
  /// nuevo asiento tiene que mantenerse [hold] (evita avisos en vaivén
  /// cuando una persona cubre dos puntos de asiento).
  (SeatId?, SeatId?)? observe(SeatId? seat, DateTime t, Duration hold) {
    exit = t;
    if (changes.isEmpty || changes.last.$1 != seat) changes.add((seat, t));
    if (seat == null) return null;
    if (_confirmed == null || seat == _confirmed) {
      _confirmed = seat;
      _candidate = null;
      return null;
    }
    if (_candidate?.$1 != seat) {
      _candidate = (seat, t);
      return null;
    }
    if (t.difference(_candidate!.$2) < hold) return null;
    final prev = _confirmed;
    _confirmed = seat;
    _candidate = null;
    return (prev, seat);
  }

  /// Tramos limpios: los tramos más cortos que [minSeg] (p. ej. mientras
  /// se desliza de un asiento a otro) se absorben en el tramo anterior.
  List<SeatSegment> segments(Duration minSeg) {
    final raw = <SeatSegment>[
      for (var i = 0; i < changes.length; i++)
        SeatSegment(changes[i].$1, changes[i].$2,
            i + 1 < changes.length ? changes[i + 1].$2 : exit),
    ];
    final out = <SeatSegment>[];
    for (final s in raw) {
      if (out.isNotEmpty &&
          (s.duration < minSeg || s.seat == out.last.seat || s.seat == null)) {
        out[out.length - 1] = SeatSegment(out.last.seat, out.last.from, s.to);
      } else {
        out.add(s);
      }
    }
    if (out.length > 1 && out.first.duration < minSeg) {
      out[1] = SeatSegment(out[1].seat, out.first.from, out[1].to);
      out.removeAt(0);
    }
    return out;
  }
}

/// Une detector + seguimiento + asientos + cronómetro + base de datos. La
/// usan el modo en vivo y el de simulación; cada pantalla solo aporta los
/// fotogramas y el reloj (hora real o tiempo del vídeo).
class DetectionSession extends ChangeNotifier {
  final TripSource source;
  AppSettings settings;
  RoiEvaluator _roi;
  final TripTracker tracker;
  final PersonTracker _people;
  final void Function(TripRecord trip)? onTripSaved;

  /// Se llama al abrirse una carrera (p. ej. empezar GPS, aviso sonoro).
  final Future<void> Function()? onTripStarted;

  /// Completa la carrera antes de guardarla (GPS, conductor, turno).
  final Future<TripRecord> Function(TripRecord trip)? enrichTrip;

  DetectionSession({
    required this.source,
    required this.settings,
    this.onTripSaved,
    this.onTripStarted,
    this.enrichTrip,
  })  : _roi = RoiEvaluator.fromSettings(settings),
        _people = PersonTracker(highThreshold: settings.confidence),
        tracker = TripTracker(
          enterConfirm: Duration(
              milliseconds: (settings.enterConfirmSeconds * 1000).round()),
          exitGrace:
              Duration(milliseconds: (settings.exitGraceSeconds * 1000).round()),
        );

  static const _minSeatSegment = Duration(seconds: 3);

  YoloDetectorService? _detector;
  bool _disposed = false;

  bool loading = true;
  String? error;
  String get backend => _detector == null
      ? ''
      : _detector!.gpuFallback
          ? '${_detector!.delegate} · GPU no respondió'
          : _detector!.delegate;

  /// Umbral que se pide al modelo: más bajo que el de usuario para que el
  /// tracker pueda usar las detecciones débiles (segunda etapa de ByteTrack).
  double get detectorConfidence => math.min(0.25, settings.confidence);

  List<Track> _visible = const [];
  List<Detection> detections = const [];

  /// Personas detectadas fuera de la cabina en el último fotograma.
  List<Detection> ignored = const [];
  int imageWidth = 0, imageHeight = 0;
  int passengers = 0, drivers = 0;
  double inferMs = 0, preMs = 0, fps = 0;
  DateTime clock = DateTime.now();
  DateTime? _lastFrameWall;
  int tripsSaved = 0;
  final Map<int, _Stint> _stints = {};

  /// Registro de lo ocurrido, el más reciente primero.
  final List<SessionEvent> events = [];

  bool get ready => _detector != null && !_disposed;

  // --- Ritmo adaptativo ------------------------------------------------------

  /// Estado térmico de Android (0 normal, 1 leve, 2 moderado, 3 severo,
  /// 4 crítico…) y temperatura de batería.
  int thermalStatus = 0;
  double batteryTemp = 0;
  DateTime? _lastStart;

  bool get _adaptive => settings.adaptiveRate && source == TripSource.live;

  /// Tiempo mínimo entre fotogramas analizados. Libre: ~0,5 fps (no hace
  /// falta más para ver que sube alguien). En carrera: ~2 fps. Si el
  /// teléfono se calienta, se baja el ritmo antes de que Android lo haga.
  Duration get frameInterval {
    if (!_adaptive) return Duration.zero;
    final idle = tracker.state == TripState.idle;
    final ms = switch (thermalStatus) {
      >= 4 => idle ? 8000 : 4000,
      3 => idle ? 5000 : 2000,
      2 => idle ? 3000 : 1000,
      _ => idle ? 2000 : 500,
    };
    return Duration(milliseconds: ms);
  }

  bool get hot => thermalStatus >= 2;

  void setThermal(int status, double temp) {
    if (status == thermalStatus && (temp - batteryTemp).abs() < 0.5) return;
    thermalStatus = status;
    batteryTemp = temp;
    _notify();
  }

  bool get canAcceptFrame {
    if (!ready || _detector!.isBusy) return false;
    final last = _lastStart;
    return last == null || DateTime.now().difference(last) >= frameInterval;
  }

  String get modelName => _detector?.modelName ?? '';

  /// Asientos ocupados ahora mismo.
  Map<SeatId, Detection> get occupiedSeats => {
        for (final d in detections)
          if (d.seat != null) d.seat!: d,
      };

  Future<void> init() async {
    try {
      // La GPU del teléfono se cuelga con los modelos exportados con
      // LiteRT-Torch (416/320): solo se intenta con el modelo original.
      _detector = await YoloDetectorService.create(
          useGpu: settings.useGpu && settings.model == ModelVariant.precise,
          asset: settings.model.assetPath);
      if (_disposed) _detector!.dispose();
    } catch (e) {
      error = e.toString();
    }
    loading = false;
    _notify();
  }

  /// Ejecuta [run] con el detector y procesa el resultado como el fotograma
  /// del instante [t]. Devuelve false si el detector estaba ocupado.
  Future<bool> process(
      Future<DetectionOutput> Function(YoloDetectorService d) run,
      DateTime t) async {
    if (!canAcceptFrame) return false;
    _lastStart = DateTime.now();
    final DetectionOutput out;
    try {
      out = await run(_detector!);
    } catch (e) {
      if (_disposed) return false;
      error = e.toString();
      _notify();
      return false;
    }
    if (_disposed) return false;
    error = null;

    final wall = DateTime.now();
    if (_lastFrameWall != null) {
      final dt = wall.difference(_lastFrameWall!).inMicroseconds / 1e6;
      if (dt > 0) fps = fps == 0 ? 1 / dt : fps * 0.8 + (1 / dt) * 0.2;
    }
    _lastFrameWall = wall;
    imageWidth = out.imageWidth;
    imageHeight = out.imageHeight;
    inferMs = out.inferMs;
    preMs = out.preMs + out.postMs;
    await ingest(out.detections, t);
    return true;
  }

  /// Procesa las detecciones de un fotograma (también lo usan las pruebas y
  /// las vistas previas, sin modelo).
  Future<void> ingest(List<Detection> raw, DateTime t) async {
    clock = t;
    _frameEvents.clear();
    // Jaula: quien está fuera de la cabina (p. ej. visto por la ventana) no
    // se sigue ni se cuenta; se guarda aparte para dibujarlo en gris.
    final inside = <Detection>[], outside = <Detection>[];
    for (final d in raw) {
      (_roi.insideCabin(d) ? inside : outside).add(d);
    }
    ignored = outside;
    _visible = _people.update(inside, t);
    _assignSeats(vote: true);

    final wasInTrip = tracker.inTrip;
    final done = tracker.update(passengers, t);
    if (!wasInTrip && tracker.inTrip) {
      final p = _pending;
      if (p != null && tracker.tripStart!.difference(p.end) <= mergeGap) {
        // Hueco corto: es la misma carrera (no se ve al pasajero un rato).
        tracker.continueFrom(p.start, p.maxPassengers);
        _pending = null;
        _event(SessionEvent(SessionEventKind.resumed, t));
      } else {
        if (p != null) {
          _pending = null;
          await _save(p);
        }
        _event(SessionEvent(SessionEventKind.tripStart, tracker.tripStart!));
        onTripStarted?.call();
      }
    }
    _logStints(t);
    await _evidenceStep(t);
    if (done != null) {
      // No se guarda aún: si alguien vuelve a verse en [mergeGap], sigue.
      _pending = done;
    } else if (_pending != null &&
        tracker.state == TripState.idle &&
        t.difference(_pending!.end) > mergeGap) {
      final p = _pending!;
      _pending = null;
      await _save(p);
    }
    if (tracker.state == TripState.idle && _pending == null) _stints.clear();
    _notify();
  }

  void _assignSeats({required bool vote}) {
    final now = _roi.assignSeats([for (final tr in _visible) tr.box]);
    if (vote) {
      for (var i = 0; i < _visible.length; i++) {
        _visible[i].vote(now[i]);
      }
    }

    // Asiento estable por votos; solo una pista puede ser el conductor.
    final stable = [
      for (var i = 0; i < _visible.length; i++)
        vote ? _visible[i].seat : now[i],
    ];
    final driverIdx = [
      for (var i = 0; i < stable.length; i++)
        if (stable[i] == SeatId.driver) i,
    ];
    if (driverIdx.length > 1) {
      driverIdx.sort((a, b) => _visible[b]
          .votesFor(SeatId.driver)
          .compareTo(_visible[a].votesFor(SeatId.driver)));
      for (final i in driverIdx.skip(1)) {
        stable[i] = null;
      }
    }

    detections = [
      for (var i = 0; i < _visible.length; i++)
        _visible[i].box.copyWith(
          trackId: _visible[i].id,
          seat: stable[i],
          clearSeat: stable[i] == null,
          role: stable[i] == SeatId.driver
              ? OccupantRole.driver
              : OccupantRole.passenger,
        ),
    ];
    passengers = RoiEvaluator.countPassengers(detections);
    drivers = detections.length - passengers;
  }

  void _logStints(DateTime t) {
    if (tracker.state == TripState.idle) return;
    final seen = <int>{};
    for (final d in detections) {
      if (d.role != OccupantRole.passenger) continue;
      seen.add(d.trackId!);
      final isNew = !_stints.containsKey(d.trackId);
      final s = _stints.putIfAbsent(d.trackId!, () => _Stint(d.trackId!, t));
      final change = s.observe(d.seat, t, _minSeatSegment);
      if (isNew) {
        _event(SessionEvent(SessionEventKind.entered, t,
            trackId: d.trackId, to: d.seat));
      } else if (change != null) {
        _event(SessionEvent(SessionEventKind.seatChange, t,
            trackId: d.trackId, from: change.$1, to: change.$2));
      }
    }
    for (final s in _stints.values) {
      if (!seen.contains(s.trackId) && !s.exitReported) {
        s.exitReported = true;
        _event(SessionEvent(SessionEventKind.exited, s.exit,
            trackId: s.trackId, from: s.lastSeat));
      }
      if (seen.contains(s.trackId)) s.exitReported = false;
    }
  }

  // --- Fotos de evidencia ---------------------------------------------------

  late final EvidenceRecorder? _evidence = settings.evidenceEnabled
      ? EvidenceRecorder(
          interval: Duration(seconds: settings.evidenceIntervalSec))
      : null;

  /// Eventos ocurridos en el fotograma actual (para decidir la foto).
  final List<SessionEvent> _frameEvents = [];

  /// Fotos guardadas en la carrera en curso.
  int evidenceShots = 0;

  /// Carrera cerrada que aún puede continuar si alguien reaparece pronto.
  CompletedTrip? _pending;

  /// Hueco máximo entre dos carreras para considerarlas una sola.
  static const mergeGap = Duration(seconds: 45);

  Future<void> _evidenceStep(DateTime t) async {
    final ev = _evidence, det = _detector;
    if (ev == null || det == null || _disposed) return;
    bool has(SessionEventKind k) => _frameEvents.any((e) => e.kind == k);
    ShotReason? reason;
    if (has(SessionEventKind.tripStart) && !ev.active) {
      try {
        await ev.begin(tracker.tripStart!);
        evidenceShots = 0;
      } catch (_) {
        return;
      }
      reason = ShotReason.start;
    } else if (has(SessionEventKind.seatChange)) {
      reason = ShotReason.seatChange;
    } else if (has(SessionEventKind.entered)) {
      reason = ShotReason.entered;
    } else if (has(SessionEventKind.exited)) {
      reason = ShotReason.exited;
    } else if (tracker.inTrip && ev.due(t)) {
      reason = ShotReason.periodic;
    }
    if (reason == null || !ev.active) return;
    await ev.capture(det, detections, t, reason);
    evidenceShots++;
  }

  void _event(SessionEvent e) {
    _frameEvents.add(e);
    events.insert(0, e);
    if (events.length > 40) events.removeLast();
  }

  /// Convierte los recorridos seguidos en pasajeros de la carrera: descarta
  /// los muy cortos y une los recorridos que continúan en el mismo asiento
  /// tras una pérdida breve del seguimiento (cambio de ID).
  List<PassengerStint> _buildPassengers(CompletedTrip trip) {
    final list = _stints.values
        // Menos de 3 s: casi siempre un ID suelto (cortes de cámara,
        // alguien que pasa por fuera), no un pasajero.
        .where((s) => s.exit.difference(s.enter) >= const Duration(seconds: 3))
        .toList()
      ..sort((a, b) => a.enter.compareTo(b.enter));
    final gap = tracker.exitGrace;
    final merged = <List<SeatSegment>>[];
    for (final s in list) {
      final segs = s.segments(_minSeatSegment);
      if (segs.isEmpty) continue;
      final prev = merged.lastIndexWhere((m) =>
          m.last.seat != null &&
          m.last.seat == segs.first.seat &&
          !m.last.to.isAfter(segs.first.from) &&
          !segs.first.from.isAfter(m.last.to.add(gap)));
      if (prev >= 0) {
        final m = merged[prev];
        m[m.length - 1] = SeatSegment(m.last.seat, m.last.from, segs.first.to);
        m.addAll(segs.skip(1));
      } else {
        merged.add(segs);
      }
    }
    DateTime clamp(DateTime d) => d.isBefore(trip.start)
        ? trip.start
        : d.isAfter(trip.end)
            ? trip.end
            : d;
    final out = <PassengerStint>[];
    for (final segs in merged) {
      final clamped = [
        for (final s in segs) SeatSegment(s.seat, clamp(s.from), clamp(s.to)),
      ];
      out.add(PassengerStint(out.length + 1, clamped.first.from,
          clamped.last.to, clamped));
    }
    return out;
  }

  /// Cambia asientos/tolerancia en caliente (calibración sobre la imagen).
  void updateSettings(AppSettings s, {bool persist = true}) {
    settings = s;
    _roi = RoiEvaluator.fromSettings(s);
    _assignSeats(vote: false);
    if (persist) persistSettings();
    _notify();
  }

  /// Guarda los ajustes. En simulación los asientos van a `simSeats` (cada
  /// vídeo tiene otro ángulo) y no pisan los de la cámara del vehículo.
  Future<void> persistSettings() async {
    final cur = settings;
    if (source == TripSource.simulation) {
      final saved = await AppSettings.load();
      await cur
          .copyWith(
            seats: saved.seats,
            simSeats: cur.seats,
            cabinEnabled: saved.cabinEnabled,
            cabin: saved.cabin,
            simCabinEnabled: cur.cabinEnabled,
            simCabin: cur.cabin,
          )
          .save();
    } else {
      await cur.save();
    }
  }

  /// Cierra (y guarda) la carrera en curso y reinicia el seguimiento.
  Future<void> finish(DateTime t) async {
    final p = _pending;
    _pending = null;
    if (p != null) await _save(p);
    final done = tracker.forceEnd(t);
    if (done != null) await _save(done);
    _stints.clear();
    _people.reset();
    _visible = const [];
    detections = const [];
    passengers = drivers = 0;
    _notify();
  }

  Future<void> _save(CompletedTrip c) async {
    // Demasiado corta para ser una carrera real: se descarta con sus fotos.
    if (c.duration < Duration(seconds: settings.minTripSeconds)) {
      _stints.clear();
      try {
        await EvidenceStore.deleteDir(await _evidence?.finish());
      } catch (_) {}
      _event(SessionEvent(SessionEventKind.discarded, c.end,
          duration: c.duration));
      return;
    }
    var trip = TripRecord(
      start: c.start,
      end: c.end,
      maxPassengers: c.maxPassengers,
      source: source,
      passengers: _buildPassengers(c),
    );
    _stints.clear();
    try {
      final dir = await _evidence?.finish();
      if (dir != null) trip = trip.copyWith(evidenceDir: dir);
    } catch (_) {}
    if (enrichTrip != null) {
      try {
        trip = await enrichTrip!(trip);
      } catch (_) {}
    }
    _event(SessionEvent(SessionEventKind.tripEnd, c.end,
        duration: c.duration));
    final id = await DatabaseHelper.instance.insertTrip(trip);
    tripsSaved++;
    onTripSaved?.call(trip.withId(id));
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _detector?.dispose();
    super.dispose();
  }
}
