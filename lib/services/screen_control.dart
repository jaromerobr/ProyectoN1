import 'package:flutter/services.dart';

/// Brillo de la ventana (canal nativo "taxiff/screen" en MainActivity.kt).
class ScreenControl {
  static const _ch = MethodChannel('taxiff/screen');

  static Future<void> setBrightness(double value) =>
      _ch.invokeMethod('setBrightness', {'value': value});

  static Future<void> restoreBrightness() => setBrightness(-1);

  /// Estado térmico de Android (0 normal … 6 apagado) y temperatura de la
  /// batería en °C.
  static Future<(int, double)> thermal() async {
    try {
      final m = await _ch.invokeMapMethod<String, Object?>('thermal');
      return (
        (m?['status'] as num?)?.toInt() ?? 0,
        (m?['batteryTemp'] as num?)?.toDouble() ?? 0
      );
    } catch (_) {
      return (0, 0.0);
    }
  }
}
