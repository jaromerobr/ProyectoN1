import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'seat.dart';

/// Esquinas por defecto de la zona de cabina (rectángulo casi completo).
const defaultCabin = <(double, double)>[
  (0.04, 0.06), (0.96, 0.06), (0.96, 0.98), (0.04, 0.98),
];

List<(double, double)> _decodeCabin(String? json) {
  if (json == null) return defaultCabin;
  try {
    final l = [
      for (final p in jsonDecode(json) as List)
        ((p[0] as num).toDouble(), (p[1] as num).toDouble()),
    ];
    return l.length >= 3 ? l : defaultCabin;
  } catch (_) {
    return defaultCabin;
  }
}

String _encodeCabin(List<(double, double)> c) =>
    jsonEncode([for (final p in c) [p.$1, p.$2]]);

/// Aviso al empezar/terminar una carrera.
enum AnnounceMode {
  off('Sin aviso'),
  beep('Pitido'),
  voice('Voz');

  final String label;
  const AnnounceMode(this.label);
}

/// Variantes del modelo incluidas en la app (assets/models/). La precisión
/// (mAP50) está medida sobre las 61 imágenes de validación del dataset de
/// taxis (el .pt original da 0,899).
enum ModelVariant {
  precise('Original', 'best.tflite', '640 px · mAP50 0,884 · 36 MB'),
  balanced('Equilibrado (recomendado)', 'models/best_416.tflite',
      '416 px · mAP50 0,896 · 2,4× menos cálculo'),
  fast('Rápido', 'models/best_320.tflite',
      '320 px · mAP50 0,894 · 4× menos cálculo');

  final String label;
  final String asset;
  final String detail;
  const ModelVariant(this.label, this.asset, this.detail);

  String get assetPath => 'assets/$asset';
}

/// Parámetros ajustables de detección y de la lógica de carrera.
class AppSettings {
  /// Asientos calibrados de la cámara del vehículo (siempre los 5).
  final List<SeatPoint> seats;

  /// Asientos de los vídeos de simulación (otro ángulo de cámara).
  final List<SeatPoint> simSeats;

  /// Mostrar la calibración a pantalla completa al empezar.
  final bool calibrateOnStart;

  /// PIN del propietario ('' = sin PIN): ve y restaura carreras borradas.
  final String ownerPin;

  /// "Jaula": solo cuentan las personas cuyo centro cae dentro de este
  /// polígono (el interior del vehículo). Así se ignora a quien se ve por
  /// las ventanas. [simCabin] es la de los vídeos.
  final bool cabinEnabled;
  final List<(double, double)> cabin;
  final bool simCabinEnabled;
  final List<(double, double)> simCabin;

  /// Distancia máxima (normalizada) entre el centroide de una persona y el
  /// punto del asiento cuando su caja no cubre el punto.
  final double seatRadius;

  /// El usuario ya marcó el asiento del conductor (oculta la ayuda).
  final bool seatCalibrated;

  final double confidence;
  final double iou;

  /// Segundos con 0 pasajeros antes de cerrar la carrera.
  final double exitGraceSeconds;

  /// Segundos que debe verse un pasajero antes de abrir la carrera
  /// (evita carreras fantasma por un falso positivo aislado).
  final double enterConfirmSeconds;

  final bool useGpu;
  final bool useFrontCamera;

  /// Paso entre fotogramas analizados en el modo simulación.
  final int simulationStepMs;

  /// Oculta la imagen de la cámara y muestra solo siluetas.
  final bool privateView;

  /// Pasa a pantalla negra tras 1 min sin tocar (modo en vivo).
  final bool autoBlackScreen;

  /// El conductor aceptó el aviso de privacidad.
  final bool privacyAccepted;

  /// Guardar origen, destino y distancia de cada carrera.
  final bool gpsEnabled;

  final AnnounceMode announce;

  /// Analizar menos fotogramas con el taxi libre y si el teléfono se
  /// calienta (ahorra batería y evita que Android cierre la app).
  final bool adaptiveRate;

  /// Conductores registrados para los turnos.
  final List<String> drivers;

  final ModelVariant model;

  /// Fotos de evidencia de cada carrera (con cajas y hora), solo en el
  /// teléfono.
  final bool evidenceEnabled;
  final int evidenceIntervalSec;

  /// Días que se conservan las fotos (0 = siempre).
  final int evidenceRetentionDays;

  /// Carreras más cortas se descartan (falsos positivos: alguien que se
  /// asoma, un reflejo, un corte en un vídeo).
  final int minTripSeconds;

  const AppSettings({
    this.seats = SeatPoint.defaults,
    this.simSeats = SeatPoint.defaults,
    this.calibrateOnStart = true,
    this.ownerPin = '',
    this.cabinEnabled = false,
    this.cabin = defaultCabin,
    this.simCabinEnabled = false,
    this.simCabin = defaultCabin,
    this.seatRadius = 0.15,
    this.seatCalibrated = false,
    this.confidence = 0.45,
    this.iou = 0.45,
    this.exitGraceSeconds = 10,
    this.enterConfirmSeconds = 1,
    this.useGpu = false,
    this.useFrontCamera = false,
    this.simulationStepMs = 200,
    this.privateView = false,
    this.autoBlackScreen = true,
    this.privacyAccepted = false,
    this.gpsEnabled = true,
    this.announce = AnnounceMode.beep,
    this.adaptiveRate = true,
    this.drivers = const [],
    this.model = ModelVariant.balanced,
    this.evidenceEnabled = true,
    this.evidenceIntervalSec = 30,
    this.evidenceRetentionDays = 30,
    this.minTripSeconds = 30,
  });

  SeatPoint seat(SeatId id) => seats.firstWhere((s) => s.id == id);

  AppSettings withSeat(SeatPoint p) =>
      copyWith(seats: [for (final s in seats) s.id == p.id ? p : s]);

  AppSettings copyWith({
    List<SeatPoint>? seats,
    List<SeatPoint>? simSeats,
    bool? calibrateOnStart,
    String? ownerPin,
    bool? cabinEnabled,
    List<(double, double)>? cabin,
    bool? simCabinEnabled,
    List<(double, double)>? simCabin,
    double? seatRadius,
    bool? seatCalibrated,
    double? confidence,
    double? iou,
    double? exitGraceSeconds,
    double? enterConfirmSeconds,
    bool? useGpu,
    bool? useFrontCamera,
    int? simulationStepMs,
    bool? privateView,
    bool? autoBlackScreen,
    bool? privacyAccepted,
    bool? gpsEnabled,
    AnnounceMode? announce,
    bool? adaptiveRate,
    List<String>? drivers,
    ModelVariant? model,
    bool? evidenceEnabled,
    int? evidenceIntervalSec,
    int? evidenceRetentionDays,
    int? minTripSeconds,
  }) =>
      AppSettings(
        seats: seats ?? this.seats,
        simSeats: simSeats ?? this.simSeats,
        calibrateOnStart: calibrateOnStart ?? this.calibrateOnStart,
        ownerPin: ownerPin ?? this.ownerPin,
        cabinEnabled: cabinEnabled ?? this.cabinEnabled,
        cabin: cabin ?? this.cabin,
        simCabinEnabled: simCabinEnabled ?? this.simCabinEnabled,
        simCabin: simCabin ?? this.simCabin,
        seatRadius: seatRadius ?? this.seatRadius,
        seatCalibrated: seatCalibrated ?? this.seatCalibrated,
        confidence: confidence ?? this.confidence,
        iou: iou ?? this.iou,
        exitGraceSeconds: exitGraceSeconds ?? this.exitGraceSeconds,
        enterConfirmSeconds: enterConfirmSeconds ?? this.enterConfirmSeconds,
        useGpu: useGpu ?? this.useGpu,
        useFrontCamera: useFrontCamera ?? this.useFrontCamera,
        simulationStepMs: simulationStepMs ?? this.simulationStepMs,
        privateView: privateView ?? this.privateView,
        autoBlackScreen: autoBlackScreen ?? this.autoBlackScreen,
        privacyAccepted: privacyAccepted ?? this.privacyAccepted,
        gpsEnabled: gpsEnabled ?? this.gpsEnabled,
        announce: announce ?? this.announce,
        adaptiveRate: adaptiveRate ?? this.adaptiveRate,
        drivers: drivers ?? this.drivers,
        model: model ?? this.model,
        evidenceEnabled: evidenceEnabled ?? this.evidenceEnabled,
        evidenceIntervalSec: evidenceIntervalSec ?? this.evidenceIntervalSec,
        evidenceRetentionDays:
            evidenceRetentionDays ?? this.evidenceRetentionDays,
        minTripSeconds: minTripSeconds ?? this.minTripSeconds,
      );

  static List<SeatPoint> _decodeSeats(String? json) {
    final saved = <SeatId, SeatPoint>{};
    if (json != null) {
      try {
        for (final m in jsonDecode(json) as List) {
          final p = SeatPoint.fromJson(m as Map<String, dynamic>);
          if (p != null) saved[p.id] = p;
        }
      } catch (_) {}
    }
    return [for (final d in SeatPoint.defaults) saved[d.id] ?? d];
  }

  static Future<AppSettings> load() async {
    final p = await SharedPreferences.getInstance();
    const d = AppSettings();
    return AppSettings(
      seats: _decodeSeats(p.getString('seats')),
      simSeats: _decodeSeats(p.getString('simSeats')),
      calibrateOnStart: p.getBool('calibrateOnStart') ?? d.calibrateOnStart,
      ownerPin: p.getString('ownerPin') ?? d.ownerPin,
      cabinEnabled: p.getBool('cabinEnabled') ?? d.cabinEnabled,
      cabin: _decodeCabin(p.getString('cabin')),
      simCabinEnabled: p.getBool('simCabinEnabled') ?? d.simCabinEnabled,
      simCabin: _decodeCabin(p.getString('simCabin')),
      seatRadius: p.getDouble('seatRadius') ?? d.seatRadius,
      seatCalibrated: p.getBool('seatsCalibrated') ?? d.seatCalibrated,
      confidence: p.getDouble('confidence') ?? d.confidence,
      iou: p.getDouble('iou') ?? d.iou,
      // v3 de ajustes: espera de salida 10 s y carrera mínima 30 s (se
      // aplican a los ajustes guardados con versiones anteriores).
      exitGraceSeconds: (p.getInt('settingsVersion') ?? 1) < 3
          ? d.exitGraceSeconds
          : p.getDouble('exitGraceSeconds') ?? d.exitGraceSeconds,
      enterConfirmSeconds:
          p.getDouble('enterConfirmSeconds') ?? d.enterConfirmSeconds,
      useGpu: p.getBool('useGpu') ?? d.useGpu,
      useFrontCamera: p.getBool('useFrontCamera') ?? d.useFrontCamera,
      simulationStepMs: p.getInt('simulationStepMs') ?? d.simulationStepMs,
      privateView: p.getBool('privateView') ?? d.privateView,
      autoBlackScreen: p.getBool('autoBlackScreen') ?? d.autoBlackScreen,
      privacyAccepted: p.getBool('privacyAccepted') ?? d.privacyAccepted,
      gpsEnabled: p.getBool('gpsEnabled') ?? d.gpsEnabled,
      announce: AnnounceMode.values.asNameMap()[p.getString('announce')] ??
          d.announce,
      adaptiveRate: p.getBool('adaptiveRate') ?? d.adaptiveRate,
      drivers: p.getStringList('drivers') ?? d.drivers,
      model: ModelVariant.values.asNameMap()[p.getString('model')] ?? d.model,
      evidenceEnabled: p.getBool('evidenceEnabled') ?? d.evidenceEnabled,
      evidenceIntervalSec:
          p.getInt('evidenceIntervalSec') ?? d.evidenceIntervalSec,
      evidenceRetentionDays:
          p.getInt('evidenceRetentionDays') ?? d.evidenceRetentionDays,
      minTripSeconds: (p.getInt('settingsVersion') ?? 1) < 3
          ? d.minTripSeconds
          : p.getInt('minTripSeconds') ?? d.minTripSeconds,
    );
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
        'seats', jsonEncode([for (final s in seats) s.toJson()]));
    await p.setString(
        'simSeats', jsonEncode([for (final s in simSeats) s.toJson()]));
    await p.setBool('calibrateOnStart', calibrateOnStart);
    await p.setString('ownerPin', ownerPin);
    await p.setBool('cabinEnabled', cabinEnabled);
    await p.setString('cabin', _encodeCabin(cabin));
    await p.setBool('simCabinEnabled', simCabinEnabled);
    await p.setString('simCabin', _encodeCabin(simCabin));
    await p.setDouble('seatRadius', seatRadius);
    await p.setBool('seatsCalibrated', seatCalibrated);
    await p.setDouble('confidence', confidence);
    await p.setDouble('iou', iou);
    await p.setDouble('exitGraceSeconds', exitGraceSeconds);
    await p.setDouble('enterConfirmSeconds', enterConfirmSeconds);
    await p.setBool('useGpu', useGpu);
    await p.setBool('useFrontCamera', useFrontCamera);
    await p.setInt('simulationStepMs', simulationStepMs);
    await p.setBool('privateView', privateView);
    await p.setBool('autoBlackScreen', autoBlackScreen);
    await p.setBool('privacyAccepted', privacyAccepted);
    await p.setBool('gpsEnabled', gpsEnabled);
    await p.setString('announce', announce.name);
    await p.setBool('adaptiveRate', adaptiveRate);
    await p.setStringList('drivers', drivers);
    await p.setString('model', model.name);
    await p.setBool('evidenceEnabled', evidenceEnabled);
    await p.setInt('evidenceIntervalSec', evidenceIntervalSec);
    await p.setInt('evidenceRetentionDays', evidenceRetentionDays);
    await p.setInt('minTripSeconds', minTripSeconds);
    await p.setInt('settingsVersion', 3);
  }
}
