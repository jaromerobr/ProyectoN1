import 'package:flutter/services.dart';

class BackgroundFrame {
  final Uint8List rgba;
  final int width, height, rotation;
  const BackgroundFrame(this.rgba, this.width, this.height, this.rotation);
}

/// Canal "taxiff/background" hacia CaptureService.kt: servicio en primer
/// plano que sigue capturando fotogramas cuando la app no está visible.
class BackgroundCapture {
  static const _ch = MethodChannel('taxiff/background');

  static Future<void> startService() => _ch.invokeMethod('startService');
  static Future<void> stopService() => _ch.invokeMethod('stopService');

  /// [wide]: usar 16:9 como la vista de la app (si no, 4:3), para que los
  /// asientos calibrados caigan en el mismo sitio de la imagen.
  static Future<void> startCapture({required bool front, bool wide = true}) =>
      _ch.invokeMethod('startCapture', {'front': front, 'wide': wide});
  static Future<void> stopCapture() => _ch.invokeMethod('stopCapture');

  /// Último fotograma nuevo, o null si no hay ninguno desde la última vez.
  static Future<BackgroundFrame?> frame() async {
    final m = await _ch.invokeMapMethod<String, Object?>('frame');
    if (m == null) return null;
    return BackgroundFrame(m['rgba'] as Uint8List, m['width'] as int,
        m['height'] as int, m['rotation'] as int);
  }

  static Future<void> notify(String title, String text) =>
      _ch.invokeMethod('notify', {'title': title, 'text': text});

  static Future<bool> batteryUnrestricted() async =>
      await _ch.invokeMethod<bool>('batteryUnrestricted') ?? false;

  static Future<void> requestBatteryUnrestricted() =>
      _ch.invokeMethod('requestBatteryUnrestricted');
}
