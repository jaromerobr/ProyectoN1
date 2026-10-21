import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/detection_session.dart';
import '../services/screen_control.dart';
import '../utils/format.dart';
import '../utils/trip_tracker.dart';

/// Pantalla negra con el brillo al mínimo. La cámara y la detección siguen
/// funcionando debajo; en pantallas OLED el negro casi no consume batería.
/// Muestra un resumen tenue que cambia de sitio cada minuto (evita marcas en
/// la pantalla). Doble toque para salir.
class BlackScreen extends StatefulWidget {
  final DetectionSession session;
  final VoidCallback onExit;
  const BlackScreen({super.key, required this.session, required this.onExit});

  @override
  State<BlackScreen> createState() => _BlackScreenState();
}

class _BlackScreenState extends State<BlackScreen> {
  final _rnd = math.Random();
  Alignment _pos = Alignment.center;
  Timer? _move;
  bool _showHint = true;

  @override
  void initState() {
    super.initState();
    ScreenControl.setBrightness(0.01);
    _move = Timer.periodic(const Duration(minutes: 1), (_) {
      setState(() => _pos = Alignment(
          _rnd.nextDouble() * 1.4 - 0.7, _rnd.nextDouble() * 1.4 - 0.7));
    });
    Future.delayed(const Duration(seconds: 4), () {
      if (mounted) setState(() => _showHint = false);
    });
  }

  @override
  void dispose() {
    _move?.cancel();
    ScreenControl.restoreBrightness();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onDoubleTap: widget.onExit,
      onTap: () => setState(() => _showHint = true),
      child: Container(
        color: Colors.black,
        child: Align(
          alignment: _pos,
          child: ListenableBuilder(
            listenable: widget.session,
            builder: (context, _) {
              final s = widget.session;
              final t = s.tracker;
              const style = TextStyle(color: Color(0xFF555555), fontSize: 18);
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    t.state == TripState.inTrip
                        ? 'En carrera ${formatDuration(t.elapsed(s.clock))}'
                        : 'Libre',
                    style: style,
                  ),
                  Text('${s.passengers} pasajero(s)', style: style),
                  if (_showHint)
                    const Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: Text('Doble toque para salir',
                          style: TextStyle(color: Color(0xFF444444))),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
