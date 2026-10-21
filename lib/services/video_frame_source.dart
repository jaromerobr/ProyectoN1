import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const bundledVideoAsset = 'assets/video_prueba.mp4';

class VideoFrame {
  final Uint8List rgba;
  final int width, height;
  const VideoFrame(this.rgba, this.width, this.height);
}

/// Lee fotogramas de un vídeo local por el canal nativo "taxiff/video_frames"
/// (MediaMetadataRetriever en MainActivity.kt).
class VideoFrameSource {
  static const _ch = MethodChannel('taxiff/video_frames');

  late Duration duration;
  late int width, height;

  /// Fecha y hora de grabación según los metadatos del vídeo, si existen.
  DateTime? recordedAt;

  Future<void> open(String path) async {
    final m = (await _ch.invokeMapMethod<String, Object?>('open', {'path': path}))!;
    duration = Duration(milliseconds: (m['durationMs'] as num).toInt());
    width = m['width'] as int;
    height = m['height'] as int;
    recordedAt = _parseDate(m['date'] as String? ?? '');
  }

  /// "20261015T143000.000Z" → hora local; null si no es una fecha válida.
  static DateTime? _parseDate(String s) {
    final m = RegExp(r'^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})').firstMatch(s);
    if (m == null) return null;
    final v = [for (var i = 1; i <= 6; i++) int.parse(m.group(i)!)];
    if (v[0] < 2000) return null; // 1904/1970: fecha vacía del contenedor
    return DateTime.utc(v[0], v[1], v[2], v[3], v[4], v[5]).toLocal();
  }

  /// Fotograma más cercano a [position], con el lado mayor ≤ [maxSide].
  /// [fast]: fotograma clave más cercano (para vídeos largos).
  Future<VideoFrame?> frameAt(Duration position,
      {int maxSide = 640, bool fast = false}) async {
    final m = await _ch.invokeMapMethod<String, Object?>('frame', {
      'timeMs': position.inMilliseconds,
      'maxSide': maxSide,
      'fast': fast,
    });
    if (m == null) return null;
    return VideoFrame(m['rgba'] as Uint8List, m['width'] as int, m['height'] as int);
  }

  Future<void> close() => _ch.invokeMethod('close');

  /// MediaMetadataRetriever necesita una ruta real: copia el vídeo de assets a
  /// la caché. Devuelve null si la app no trae `assets/video_prueba.mp4`.
  static Future<String?> bundledVideoPath() async {
    final ByteData data;
    try {
      data = await rootBundle.load(bundledVideoAsset);
    } catch (_) {
      return null;
    }
    final file =
        File(p.join((await getTemporaryDirectory()).path, 'video_prueba.mp4'));
    if (!await file.exists() || await file.length() != data.lengthInBytes) {
      await file.writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          flush: true);
    }
    return file.path;
  }
}
