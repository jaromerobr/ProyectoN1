import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/detection.dart';
import 'yolo_detector_service.dart';

/// Motivo de una foto de evidencia.
enum ShotReason {
  start('inicio', 'Inicio de carrera', 'Inicio de carrera'),
  entered('subio', 'Subió un pasajero', 'Subio pasajero'),
  seatChange('cambio', 'Cambio de asiento', 'Cambio de asiento'),
  exited('bajo', 'Bajó un pasajero', 'Bajo pasajero'),
  periodic('periodica', 'En carrera', 'En carrera');

  final String code;
  final String label;

  /// Texto sin tildes para la fuente de mapa de bits de la foto.
  final String ascii;
  const ShotReason(this.code, this.label, this.ascii);

  static ShotReason parse(String code) =>
      values.firstWhere((r) => r.code == code, orElse: () => periodic);
}

class EvidenceShot {
  final File file;
  final DateTime time;
  final ShotReason reason;
  const EvidenceShot(this.file, this.time, this.reason);
}

/// Carpeta de evidencias en el almacenamiento privado de la app (no se ve
/// en la galería ni la usan otras apps).
class EvidenceStore {
  static Future<Directory> root() async {
    final d = Directory(
        p.join((await getApplicationDocumentsDirectory()).path, 'evidencias'));
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// Fotos de una carrera, en orden. Nombre: `<ms>_<motivo>.jpg`.
  static Future<List<EvidenceShot>> list(String? dir) async {
    if (dir == null) return const [];
    final d = Directory(dir);
    if (!await d.exists()) return const [];
    final shots = <EvidenceShot>[];
    await for (final e in d.list()) {
      if (e is! File || !e.path.endsWith('.jpg')) continue;
      final parts = p.basenameWithoutExtension(e.path).split('_');
      final ms = int.tryParse(parts.first);
      if (ms == null) continue;
      shots.add(EvidenceShot(e, DateTime.fromMillisecondsSinceEpoch(ms),
          ShotReason.parse(parts.length > 1 ? parts[1] : '')));
    }
    shots.sort((a, b) => a.time.compareTo(b.time));
    return shots;
  }

  static Future<void> deleteDir(String? dir) async {
    if (dir == null) return;
    final d = Directory(dir);
    if (await d.exists()) await d.delete(recursive: true);
  }

  /// Borra las carpetas de más de [days] días (0 = conservar siempre).
  static Future<void> cleanup(int days) async {
    if (days <= 0) return;
    final limit = DateTime.now().subtract(Duration(days: days));
    await for (final e in (await root()).list()) {
      if (e is Directory && (await e.stat()).modified.isBefore(limit)) {
        await e.delete(recursive: true);
      }
    }
  }

  static Future<int> sizeBytes() async {
    var total = 0;
    await for (final e in (await root()).list(recursive: true)) {
      if (e is File) total += await e.length();
    }
    return total;
  }

  static Future<void> deleteAll() async {
    final r = await root();
    if (await r.exists()) await r.delete(recursive: true);
  }
}

/// Toma las fotos de la carrera en curso: al empezar, en cada evento (sube,
/// cambia de asiento, baja) y cada [interval] mientras dura.
class EvidenceRecorder {
  final Duration interval;
  final int width;
  Directory? _dir;
  DateTime? _last;

  EvidenceRecorder({
    this.interval = const Duration(seconds: 30),
    this.width = 540,
  });

  bool get active => _dir != null;

  bool due(DateTime t) =>
      active && (_last == null || t.difference(_last!) >= interval);

  Future<void> begin(DateTime tripStart) async {
    _dir = Directory(
        p.join((await root()).path, 'carrera_${tripStart.millisecondsSinceEpoch}'));
    await _dir!.create(recursive: true);
    _last = null;
  }

  static Future<Directory> root() => EvidenceStore.root();

  Future<void> capture(YoloDetectorService detector, List<Detection> dets,
      DateTime t, ShotReason reason) async {
    final dir = _dir;
    if (dir == null) return;
    _last = t;
    final boxes = [
      for (final d in dets)
        SnapBox(
          d.left,
          d.top,
          d.right,
          d.bottom,
          d.role == OccupantRole.driver
              ? 'CONDUCTOR'
              : 'P#${d.trackId ?? '?'}${d.seat == null ? '' : ' ${d.seat!.short}'}',
          d.role == OccupantRole.driver ? 0xFF9F0A : 0x30C26B,
        ),
    ];
    final stamp = 'Taxiff  ${_fmt(t)}  ${reason.ascii}';
    try {
      final jpg = await detector.snapshot(boxes, stamp: stamp, width: width);
      if (jpg != null) {
        await File(p.join(dir.path, '${t.millisecondsSinceEpoch}_${reason.code}.jpg'))
            .writeAsBytes(jpg);
      }
    } catch (_) {}
  }

  /// Cierra la carrera: devuelve la carpeta si tiene fotos.
  Future<String?> finish() async {
    final dir = _dir;
    _dir = null;
    _last = null;
    if (dir == null || !await dir.exists()) return null;
    if (await dir.list().isEmpty) {
      await dir.delete();
      return null;
    }
    return dir.path;
  }

  static String _fmt(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }
}
