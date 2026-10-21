import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../models/app_settings.dart';

/// Aviso sonoro al empezar/terminar una carrera, para que el conductor no
/// tenga que mirar la pantalla. Por discreción no dice cuántos pasajeros hay.
class Announcer {
  static const _ch = MethodChannel('taxiff/screen');
  final AnnounceMode mode;
  FlutterTts? _tts;

  Announcer(this.mode) {
    if (mode == AnnounceMode.voice) {
      _tts = FlutterTts()
        ..setLanguage('es-ES')
        ..setSpeechRate(0.5);
    }
  }

  Future<void> tripStarted() => switch (mode) {
        AnnounceMode.off => Future.value(),
        AnnounceMode.beep => _beep('start'),
        AnnounceMode.voice => _say('Carrera iniciada'),
      };

  Future<void> tripEnded(Duration d) => switch (mode) {
        AnnounceMode.off => Future.value(),
        AnnounceMode.beep => _beep('end'),
        AnnounceMode.voice => _say(
            'Carrera terminada. ${d.inMinutes < 1 ? 'Menos de un minuto' : '${d.inMinutes} ${d.inMinutes == 1 ? 'minuto' : 'minutos'}'}'),
      };

  Future<void> warn(String text) => switch (mode) {
        AnnounceMode.voice => _say(text),
        AnnounceMode.beep => _beep('warn'),
        AnnounceMode.off => Future.value(),
      };

  Future<void> _beep(String kind) async {
    try {
      await _ch.invokeMethod('beep', {'kind': kind});
    } catch (_) {}
  }

  Future<void> _say(String text) async {
    try {
      await _tts?.speak(text);
    } catch (_) {}
  }

  void dispose() => _tts?.stop();
}
