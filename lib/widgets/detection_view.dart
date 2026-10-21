import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/app_settings.dart';
import '../models/detection.dart';
import '../models/seat.dart';
import '../services/detection_session.dart';
import '../ui/car_seat_map.dart';
import '../ui/theme.dart';

const driverColor = AppColors.driver;
const passengerColor = AppColors.passenger;
const seatIdleColor = Color(0xFFB0BEC5);

/// Muestra [background] (vista de cámara o fotograma de vídeo) con las
/// personas seguidas y los asientos encima.
///
/// - Con [editingSeat]: tocar coloca ese asiento (si se toca a una persona,
///   en su centro) y arrastrar lo mueve.
/// - Sin calibrar todavía: tocar al conductor coloca su asiento.
/// - [privateView]: oculta la imagen y deja solo siluetas.
class DetectionView extends StatelessWidget {
  final DetectionSession session;
  final Widget background;
  final double aspectRatio;
  final SeatId? editingSeat;
  final bool privateView;

  const DetectionView({
    super.key,
    required this.session,
    required this.background,
    required this.aspectRatio,
    this.editingSeat,
    this.privateView = false,
  });

  SeatId? get _tapTarget => editingSeat ??
      (session.settings.seatCalibrated ? null : SeatId.driver);

  void _place(SeatId id, Offset p, Size size, {required bool snap}) {
    var x = (p.dx / size.width).clamp(0.0, 1.0);
    var y = (p.dy / size.height).clamp(0.0, 1.0);
    if (snap) {
      Detection? hit;
      double best = double.infinity;
      for (final d in session.detections) {
        if (x < d.left || x > d.right || y < d.top || y > d.bottom) continue;
        final dist = math.pow(d.cx - x, 2) + math.pow(d.cy - y, 2).toDouble();
        if (dist < best) {
          best = dist;
          hit = d;
        }
      }
      if (hit != null) (x, y) = (hit.cx, hit.cy);
    }
    final s = session.settings;
    session.updateSettings(
      s.withSeat(s.seat(id).copyWith(x: x, y: y, enabled: true)).copyWith(
          seatCalibrated: s.seatCalibrated || id == SeatId.driver),
      persist: snap,
    );
  }

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: aspectRatio,
      child: LayoutBuilder(builder: (context, c) {
        final size = c.biggest;
        return ListenableBuilder(
          listenable: session,
          builder: (context, _) {
            final target = _tapTarget;
            return GestureDetector(
              onTapUp: target == null
                  ? null
                  : (d) => _place(target, d.localPosition, size, snap: true),
              onPanUpdate: editingSeat == null
                  ? null
                  : (d) =>
                      _place(editingSeat!, d.localPosition, size, snap: false),
              onPanEnd:
                  editingSeat == null ? null : (_) => session.persistSettings(),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (privateView) const _PrivateBackground() else background,
                    CustomPaint(
                      painter: _OverlayPainter(
                        session.detections,
                        session.settings,
                        editingSeat,
                        privateView,
                        session.ignored,
                      ),
                    ),
                    if (target != null)
                      _Hint(editingSeat != null
                          ? 'Toca o arrastra: ${editingSeat!.label}'
                          : 'Toca al conductor para marcar su asiento'),
                  ],
                ),
              ),
            );
          },
        );
      }),
    );
  }
}

class _PrivateBackground extends StatelessWidget {
  const _PrivateBackground();

  @override
  Widget build(BuildContext context) => Container(
        color: const Color(0xFF101418),
        alignment: Alignment.topRight,
        padding: const EdgeInsets.all(10),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.visibility_off, size: 16, color: Colors.white54),
            SizedBox(width: 6),
            Text('Vista privada', style: TextStyle(color: Colors.white54)),
          ],
        ),
      );
}

class _Hint extends StatelessWidget {
  final String text;
  const _Hint(this.text);

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.bottomCenter,
        child: Container(
          margin: const EdgeInsets.all(12),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.touch_app, size: 18, color: driverColor),
              const SizedBox(width: 8),
              Flexible(
                child: Text(text, style: const TextStyle(color: Colors.white)),
              ),
            ],
          ),
        ),
      );
}

class _OverlayPainter extends CustomPainter {
  final List<Detection> detections;
  final AppSettings s;
  final SeatId? editing;
  final bool private;

  /// Personas fuera de la jaula (no cuentan): se dibujan en gris.
  final List<Detection> ignored;

  _OverlayPainter(
      this.detections, this.s, this.editing, this.private, this.ignored);

  @override
  void paint(Canvas canvas, Size size) {
    _paintCabin(canvas, size);
    final occupied = {
      for (final d in detections)
        if (d.seat != null) d.seat!,
    };
    for (final seat in s.seats) {
      if (!seat.enabled && seat.id != editing) continue;
      _paintSeat(canvas, size, seat, occupied.contains(seat.id));
    }

    for (final d in detections) {
      final isDriver = d.role == OccupantRole.driver;
      final color = isDriver ? driverColor : passengerColor;
      final r = Rect.fromLTRB(d.left * size.width, d.top * size.height,
          d.right * size.width, d.bottom * size.height);
      final rr = RRect.fromRectAndRadius(r, const Radius.circular(10));
      canvas.drawRRect(
          rr, Paint()..color = color.withValues(alpha: private ? 0.35 : 0.10));
      canvas.drawRRect(
          rr,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = isDriver ? 4 : 3
            ..color = color);
      if (private) _silhouette(canvas, r, color);
      final c = Offset(d.cx * size.width, d.cy * size.height);
      canvas.drawCircle(c, 5, Paint()..color = color);

      final id = d.trackId == null ? '' : ' #${d.trackId}';
      final name = isDriver
          ? 'CONDUCTOR$id'
          : 'PASAJERO$id${d.seat == null ? '' : ' · ${d.seat!.short}'}';
      _label(canvas, name, Offset(r.left, math.max(0, r.top - 26)), color);
    }
  }

  void _paintCabin(Canvas canvas, Size size) {
    if (s.cabinEnabled && s.cabin.length >= 3) {
      final path = Path()
        ..moveTo(s.cabin.first.$1 * size.width, s.cabin.first.$2 * size.height);
      for (final p in s.cabin.skip(1)) {
        path.lineTo(p.$1 * size.width, p.$2 * size.height);
      }
      path.close();
      final outside = Path.combine(PathOperation.difference,
          Path()..addRect(Offset.zero & size), path);
      canvas.drawPath(
          outside, Paint()..color = Colors.black.withValues(alpha: 0.35));
      canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = AppColors.info.withValues(alpha: 0.9));
    }
    for (final d in ignored) {
      final r = Rect.fromLTRB(d.left * size.width, d.top * size.height,
          d.right * size.width, d.bottom * size.height);
      canvas.drawRect(
          r,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = Colors.white54);
      _label(canvas, 'FUERA', Offset(r.left, math.max(0, r.top - 22)),
          Colors.white70,
          small: true);
    }
  }

  void _paintSeat(Canvas canvas, Size size, SeatPoint seat, bool occupied) {
    final p = Offset(seat.x * size.width, seat.y * size.height);
    final isDriver = seat.id == SeatId.driver;
    final selected = seat.id == editing;
    final color = occupied
        ? seatColor(seat.id)
        : (isDriver ? driverColor.withValues(alpha: 0.7) : seatIdleColor);

    if (selected || isDriver) {
      final area = Rect.fromCenter(
          center: p,
          width: s.seatRadius * 2 * size.width,
          height: s.seatRadius * 2 * size.height);
      canvas.drawOval(area, Paint()..color = color.withValues(alpha: 0.10));
      _dashedOval(canvas, area, color);
    }

    final stroke = Paint()
      ..color = color
      ..strokeWidth = selected ? 3.5 : 2.5
      ..style = PaintingStyle.stroke;
    final rad = selected ? 14.0 : 10.0;
    canvas.drawCircle(p, rad, Paint()..color = Colors.black45);
    canvas.drawCircle(p, rad, stroke);
    if (occupied) canvas.drawCircle(p, rad - 4, Paint()..color = color);
    if (isDriver || selected) {
      for (final dir in const [
        Offset(1, 0),
        Offset(-1, 0),
        Offset(0, 1),
        Offset(0, -1)
      ]) {
        canvas.drawLine(p + dir * (rad + 2), p + dir * (rad + 9), stroke);
      }
    }
    _label(
      canvas,
      editing != null ? seat.id.label : seat.id.short,
      p + Offset(-12, rad + 10),
      color,
      small: editing == null,
    );
  }

  /// Silueta simple (cabeza + hombros) para la vista privada.
  void _silhouette(Canvas canvas, Rect r, Color color) {
    final paint = Paint()..color = color.withValues(alpha: 0.55);
    final head = r.shortestSide * 0.22;
    final hc = Offset(r.center.dx, r.top + r.height * 0.28);
    canvas.drawCircle(hc, head, paint);
    canvas.drawRRect(
      RRect.fromRectAndCorners(
        Rect.fromLTRB(r.left + r.width * 0.15, hc.dy + head * 1.2,
            r.right - r.width * 0.15, r.bottom - 4),
        topLeft: Radius.circular(head * 1.5),
        topRight: Radius.circular(head * 1.5),
      ),
      paint,
    );
  }

  void _dashedOval(Canvas canvas, Rect rect, Color color) {
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    const dashes = 36;
    for (var i = 0; i < dashes; i += 2) {
      canvas.drawArc(
          rect, i * 2 * math.pi / dashes, 2 * math.pi / dashes, false, p);
    }
  }

  void _label(Canvas canvas, String text, Offset at, Color bg,
      {bool small = false}) {
    final tp = TextPainter(
      text: TextSpan(
          text: text,
          style: TextStyle(
              fontFamily: 'Roboto',
              color: Colors.black,
              fontSize: small ? 10 : 12,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.4)),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(at.dx, at.dy, tp.width + 12, tp.height + 6),
            const Radius.circular(6)),
        Paint()..color = bg);
    tp.paint(canvas, at + const Offset(6, 3));
  }

  @override
  bool shouldRepaint(_OverlayPainter old) =>
      old.detections != detections ||
      old.ignored != ignored ||
      old.s != s ||
      old.editing != editing ||
      old.private != private;
}
