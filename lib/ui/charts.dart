import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/trip_record.dart';
import '../utils/format.dart';
import 'car_seat_map.dart';
import 'theme.dart';

/// Gráfica de barras redondeadas con líneas guía, animación de entrada y
/// valor al tocar una barra.
class BarChart extends StatefulWidget {
  final List<double> values;
  final List<String> labels;
  final String Function(int i, double v) tooltip;
  final Color color;

  /// Barra resaltada por defecto (p. ej. hoy u hora pico).
  final int? highlight;
  final double height;

  const BarChart({
    super.key,
    required this.values,
    required this.labels,
    required this.tooltip,
    this.color = AppColors.accent,
    this.highlight,
    this.height = 150,
  });

  @override
  State<BarChart> createState() => _BarChartState();
}

class _BarChartState extends State<BarChart> {
  int? _sel;

  @override
  Widget build(BuildContext context) {
    final s = Surfaces.of(context);
    final maxV = widget.values.fold<double>(0, math.max);
    final top = maxV <= 0 ? 1.0 : _niceCeil(maxV);
    final sel = _sel ?? widget.highlight;
    final n = widget.values.length;

    return Column(
      children: [
        SizedBox(
          height: 22,
          child: sel != null && sel < n
              ? Align(
                  alignment: Alignment(n == 1 ? 0 : -1 + 2 * sel / (n - 1), 0),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: widget.color,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(widget.tooltip(sel, widget.values[sel]),
                        style: const TextStyle(
                            color: Colors.black,
                            fontSize: 11,
                            fontWeight: FontWeight.w700)),
                  ),
                )
              : null,
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: widget.height,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // Líneas guía con escala (la línea y su número, centrados).
              for (final f in const [0.0, 0.5, 1.0]) ...[
                Positioned(
                  left: 0,
                  right: 30,
                  bottom: f * (widget.height - 1),
                  child: Container(height: 1, color: s.divider),
                ),
                if (f > 0)
                  Positioned(
                    right: 0,
                    width: 26,
                    bottom: f * (widget.height - 1) - 6,
                    child: Text(
                      _fmt(top * f),
                      textAlign: TextAlign.right,
                      style: TextStyle(
                          fontSize: 10, height: 1.2, color: s.textSecondary),
                    ),
                  ),
              ],
              Padding(
                padding: const EdgeInsets.only(right: 30),
                child: TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: 1),
                  duration: const Duration(milliseconds: 650),
                  curve: Curves.easeOutCubic,
                  builder: (context, anim, _) => Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      for (var i = 0; i < n; i++)
                        Expanded(
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () =>
                                setState(() => _sel = _sel == i ? null : i),
                            child: Align(
                              alignment: Alignment.bottomCenter,
                              child: FractionallySizedBox(
                                widthFactor: n > 12 ? 0.62 : 0.5,
                                child: Container(
                                  height: math.max(
                                      3,
                                      (widget.height - 2) *
                                          anim *
                                          widget.values[i] /
                                          top),
                                  decoration: BoxDecoration(
                                    color: i == sel
                                        ? widget.color
                                        : widget.color.withValues(
                                            alpha: widget.values[i] == 0
                                                ? 0.15
                                                : 0.45),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Padding(
          padding: const EdgeInsets.only(right: 30),
          child: Row(
            children: [
              for (var i = 0; i < n; i++)
                Expanded(
                  child: Text(widget.labels[i],
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.visible,
                      softWrap: false,
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight:
                              i == sel ? FontWeight.w700 : FontWeight.w400,
                          color: i == sel ? null : s.textSecondary)),
                ),
            ],
          ),
        ),
      ],
    );
  }

  static double _niceCeil(double v) {
    if (v <= 4) return v.ceilToDouble().clamp(1, 4);
    final mag = math.pow(10, (math.log(v) / math.ln10).floor()).toDouble();
    for (final m in const [1, 2, 2.5, 5, 10]) {
      if (m * mag >= v) return m * mag;
    }
    return 10 * mag;
  }

  static String _fmt(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);
}

class DonutSegment {
  final double value;
  final Color color;
  final String label;
  const DonutSegment(this.value, this.color, this.label);
}

/// Donut con texto en el centro y leyenda a la derecha.
class DonutChart extends StatelessWidget {
  final List<DonutSegment> segments;
  final String centerValue;
  final String centerLabel;
  final double size;

  const DonutChart({
    super.key,
    required this.segments,
    required this.centerValue,
    required this.centerLabel,
    this.size = 130,
  });

  @override
  Widget build(BuildContext context) {
    final s = Surfaces.of(context);
    final total = segments.fold<double>(0, (a, b) => a + b.value);
    return Row(
      children: [
        SizedBox(
          width: size,
          height: size,
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 800),
            curve: Curves.easeOutCubic,
            builder: (context, t, _) => CustomPaint(
              painter: _DonutPainter(segments, s.cardHigh, t),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(centerValue,
                        style: const TextStyle(
                            fontSize: 24, fontWeight: FontWeight.w700)),
                    Text(centerLabel,
                        style: TextStyle(fontSize: 11, color: s.textSecondary)),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 20),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final seg in segments)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                            color: seg.color, shape: BoxShape.circle),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(seg.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13)),
                      ),
                      Text(
                        total == 0
                            ? '0 %'
                            : '${(seg.value / total * 100).round()} %',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: s.textSecondary),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DonutPainter extends CustomPainter {
  final List<DonutSegment> segments;
  final Color track;
  final double t;
  _DonutPainter(this.segments, this.track, this.t);

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 16.0;
    final rect = Rect.fromCircle(
        center: size.center(Offset.zero),
        radius: size.shortestSide / 2 - stroke / 2);
    canvas.drawArc(
        rect,
        0,
        math.pi * 2,
        false,
        Paint()
          ..color = track
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke);
    final total = segments.fold<double>(0, (a, b) => a + b.value);
    if (total <= 0) return;
    final nonZero = segments.where((s) => s.value > 0).length;
    final gap = nonZero > 1 ? 0.06 : 0.0;
    var start = -math.pi / 2;
    for (final s in segments) {
      if (s.value <= 0) continue;
      final sweep = (s.value / total) * math.pi * 2 * t;
      canvas.drawArc(
          rect,
          start + gap / 2,
          math.max(0.001, sweep - gap),
          false,
          Paint()
            ..color = s.color
            ..style = PaintingStyle.stroke
            ..strokeWidth = stroke
            ..strokeCap = StrokeCap.round);
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(_DonutPainter old) =>
      old.t != t || old.segments != segments || old.track != track;
}

/// Línea de tiempo de una carrera: una fila por pasajero, coloreada según
/// el asiento en cada tramo (los cambios de asiento se ven como cambios de
/// color con un marcador).
class TripTimeline extends StatelessWidget {
  final TripRecord trip;
  const TripTimeline({super.key, required this.trip});

  @override
  Widget build(BuildContext context) {
    final s = Surfaces.of(context);
    final total = math.max(1, trip.duration.inMilliseconds);
    double pos(DateTime t) =>
        (t.difference(trip.start).inMilliseconds / total).clamp(0.0, 1.0);

    return Column(
      children: [
        for (final p in trip.passengers)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                SizedBox(
                  width: 34,
                  child: CircleAvatar(
                    radius: 13,
                    backgroundColor: AppColors.forIndex(p.number - 1),
                    child: Text('${p.number}',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w800)),
                  ),
                ),
                Expanded(
                  child: LayoutBuilder(builder: (context, c) {
                    final w = c.maxWidth;
                    return SizedBox(
                      height: 26,
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: Container(
                              decoration: BoxDecoration(
                                color: s.cardHigh,
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                          ),
                          for (var i = 0; i < p.segments.length; i++)
                            Positioned(
                              left: w * pos(p.segments[i].from),
                              width: math.max(
                                  4,
                                  w *
                                      (pos(p.segments[i].to) -
                                          pos(p.segments[i].from))),
                              top: 0,
                              bottom: 0,
                              child: Container(
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: seatColor(p.segments[i].seat),
                                  borderRadius: BorderRadius.horizontal(
                                    left: Radius.circular(i == 0 ? 8 : 0),
                                    right: Radius.circular(
                                        i == p.segments.length - 1 ? 8 : 0),
                                  ),
                                  border: i == 0
                                      ? null
                                      : const Border(
                                          left: BorderSide(
                                              color: Colors.white, width: 2)),
                                ),
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 4),
                                    child: Text(
                                      p.segments[i].seat?.short ?? '—',
                                      style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.w800,
                                          fontSize: 11),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    );
                  }),
                ),
              ],
            ),
          ),
        const SizedBox(height: 6),
        Row(
          children: [
            const SizedBox(width: 34),
            Text(formatTime(trip.start),
                style: TextStyle(fontSize: 11, color: s.textSecondary)),
            const Spacer(),
            Text(formatTime(trip.start.add(trip.duration ~/ 2)),
                style: TextStyle(fontSize: 11, color: s.textSecondary)),
            const Spacer(),
            Text(formatTime(trip.end),
                style: TextStyle(fontSize: 11, color: s.textSecondary)),
          ],
        ),
      ],
    );
  }
}

/// Barra horizontal de progreso con etiqueta y valor (rankings).
class LabeledBar extends StatelessWidget {
  final String label;
  final String value;
  final double fraction;
  final Color color;
  const LabeledBar({
    super.key,
    required this.label,
    required this.value,
    required this.fraction,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final s = Surfaces.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                  child: Text(label, style: const TextStyle(fontSize: 14))),
              Text(value,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: s.textSecondary)),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: fraction.clamp(0, 1)),
              duration: const Duration(milliseconds: 700),
              curve: Curves.easeOutCubic,
              builder: (context, v, _) => LinearProgressIndicator(
                value: v,
                minHeight: 8,
                color: color,
                backgroundColor: s.cardHigh,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
