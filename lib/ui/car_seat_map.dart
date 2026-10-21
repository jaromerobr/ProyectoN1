import 'package:flutter/material.dart';

import '../models/seat.dart';
import 'theme.dart';

/// Color fijo de cada asiento (gráficas, líneas de tiempo, leyendas).
Color seatColor(SeatId? s) => switch (s) {
      SeatId.driver => AppColors.driver,
      SeatId.copilot => AppColors.info,
      SeatId.rearLeft => AppColors.passenger,
      SeatId.rearCenter => AppColors.purple,
      SeatId.rearRight => const Color(0xFFFF5C8A),
      null => const Color(0xFF8E8E93),
    };

/// Cómo pintar un asiento en el mapa.
class SeatVisual {
  /// Color de relleno; null = asiento libre.
  final Color? color;

  /// Intensidad 0..1 del relleno (para mapas de calor).
  final double intensity;

  /// Texto pequeño bajo el nombre (p. ej. "#12" o "45 %").
  final String? caption;
  final bool disabled;

  const SeatVisual({
    this.color,
    this.intensity = 1,
    this.caption,
    this.disabled = false,
  });
}

/// Vista cenital del vehículo (frente arriba) con los 5 asientos.
/// El conductor va delante a la izquierda.
class CarSeatMap extends StatelessWidget {
  final Map<SeatId, SeatVisual> seats;
  final double height;

  const CarSeatMap({super.key, required this.seats, this.height = 300});

  static const _rects = <SeatId, Rect>{
    SeatId.driver: Rect.fromLTRB(0.13, 0.33, 0.45, 0.52),
    SeatId.copilot: Rect.fromLTRB(0.55, 0.33, 0.87, 0.52),
    SeatId.rearLeft: Rect.fromLTRB(0.13, 0.60, 0.36, 0.79),
    SeatId.rearCenter: Rect.fromLTRB(0.385, 0.60, 0.615, 0.79),
    SeatId.rearRight: Rect.fromLTRB(0.64, 0.60, 0.87, 0.79),
  };

  @override
  Widget build(BuildContext context) {
    final s = Surfaces.of(context);
    final width = height * 0.58;
    return SizedBox(
      width: width,
      height: height,
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _CarPainter(
                body: s.cardHigh,
                glass: s.textSecondary.withValues(alpha: 0.25),
                outline: s.divider,
              ),
            ),
          ),
          for (final e in _rects.entries)
            Positioned(
              left: e.value.left * width,
              top: e.value.top * height,
              width: e.value.width * width,
              height: e.value.height * height,
              child: _Seat(
                  id: e.key, visual: seats[e.key] ?? const SeatVisual()),
            ),
        ],
      ),
    );
  }
}

class _Seat extends StatelessWidget {
  final SeatId id;
  final SeatVisual visual;
  const _Seat({required this.id, required this.visual});

  @override
  Widget build(BuildContext context) {
    final s = Surfaces.of(context);
    final c = visual.color;
    final active = c != null && !visual.disabled;
    final fill = active
        ? Color.lerp(s.card, c, 0.25 + 0.75 * visual.intensity.clamp(0, 1))!
        : s.card;
    final fg = active && visual.intensity > 0.45 ? Colors.white : null;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 350),
      decoration: BoxDecoration(
        color: visual.disabled ? Colors.transparent : fill,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: active ? c : s.divider,
          width: active ? 2 : 1.2,
        ),
      ),
      child: Opacity(
        opacity: visual.disabled ? 0.35 : 1,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(id.short,
                    style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 14,
                        color: fg ?? (active ? c : s.textSecondary))),
                if (visual.caption != null)
                  Text(visual.caption!,
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: fg ?? s.textSecondary)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CarPainter extends CustomPainter {
  final Color body, glass, outline;
  _CarPainter({required this.body, required this.glass, required this.outline});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final bodyR = RRect.fromRectAndCorners(
      Rect.fromLTWH(w * 0.04, 0, w * 0.92, h),
      topLeft: Radius.elliptical(w * 0.36, h * 0.16),
      topRight: Radius.elliptical(w * 0.36, h * 0.16),
      bottomLeft: Radius.elliptical(w * 0.26, h * 0.08),
      bottomRight: Radius.elliptical(w * 0.26, h * 0.08),
    );
    canvas.drawRRect(bodyR, Paint()..color = body);
    canvas.drawRRect(
        bodyR,
        Paint()
          ..color = outline
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2);

    // Espejos.
    final mirror = Paint()..color = body;
    canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(0, h * 0.27, w * 0.08, h * 0.035),
            const Radius.circular(4)),
        mirror);
    canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(w * 0.92, h * 0.27, w * 0.08, h * 0.035),
            const Radius.circular(4)),
        mirror);

    // Parabrisas y luneta.
    final g = Paint()..color = glass;
    final front = Path()
      ..moveTo(w * 0.17, h * 0.27)
      ..quadraticBezierTo(w * 0.5, h * 0.15, w * 0.83, h * 0.27)
      ..lineTo(w * 0.78, h * 0.31)
      ..quadraticBezierTo(w * 0.5, h * 0.24, w * 0.22, h * 0.31)
      ..close();
    canvas.drawPath(front, g);
    final rear = Path()
      ..moveTo(w * 0.2, h * 0.86)
      ..quadraticBezierTo(w * 0.5, h * 0.9, w * 0.8, h * 0.86)
      ..lineTo(w * 0.76, h * 0.83)
      ..quadraticBezierTo(w * 0.5, h * 0.86, w * 0.24, h * 0.83)
      ..close();
    canvas.drawPath(rear, g);

    // Faros.
    final light = Paint()..color = AppColors.accent.withValues(alpha: 0.7);
    canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(w * 0.16, h * 0.035, w * 0.16, h * 0.02),
            const Radius.circular(4)),
        light);
    canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(w * 0.68, h * 0.035, w * 0.16, h * 0.02),
            const Radius.circular(4)),
        light);
  }

  @override
  bool shouldRepaint(_CarPainter old) =>
      old.body != body || old.glass != glass || old.outline != outline;
}
