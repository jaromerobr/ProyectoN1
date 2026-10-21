import 'package:flutter/material.dart';

import '../models/app_settings.dart' show defaultCabin;
import '../models/seat.dart';
import '../ui/car_seat_map.dart';
import '../ui/theme.dart';

/// Resultado de la calibración.
class CalibrationResult {
  final List<SeatPoint> seats;
  final List<(double, double)> cabin;
  final bool cabinEnabled;
  const CalibrationResult(this.seats, this.cabin, this.cabinEnabled);
}

enum _Mode { seats, cabin }

/// Calibración a pantalla completa antes de empezar: la imagen de la cámara
/// (o el primer fotograma del vídeo) ocupa toda la pantalla.
/// - Asientos: cada círculo se arrastra hasta su asiento.
/// - Jaula: se arrastran las esquinas del contorno del interior del vehículo;
///   quien quede fuera (p. ej. visto por la ventana) no se cuenta.
/// Devuelve [CalibrationResult] al pulsar "Empezar", o null al volver.
class SeatCalibrationScreen extends StatefulWidget {
  final Widget background;
  final double aspectRatio;
  final List<SeatPoint> seats;
  final List<(double, double)> cabin;
  final bool cabinEnabled;
  final String title;

  const SeatCalibrationScreen({
    super.key,
    required this.background,
    required this.aspectRatio,
    required this.seats,
    this.cabin = defaultCabin,
    this.cabinEnabled = false,
    this.title = 'Coloca los asientos',
  });

  @override
  State<SeatCalibrationScreen> createState() => _SeatCalibrationScreenState();
}

class _SeatCalibrationScreenState extends State<SeatCalibrationScreen> {
  late List<SeatPoint> _seats = [...widget.seats];
  late List<(double, double)> _cabin = [...widget.cabin];
  late bool _cabinOn = widget.cabinEnabled;
  _Mode _mode = _Mode.seats;
  SeatId? _dragging;
  int? _draggingCorner;

  (double, double) _clampPt(Offset p, Size size) => (
        (p.dx / size.width).clamp(0.0, 1.0),
        (p.dy / size.height).clamp(0.0, 1.0),
      );

  void _moveSeat(SeatId id, Offset local, Size size) {
    final (x, y) = _clampPt(local, size);
    setState(() => _seats = [
          for (final s in _seats)
            s.id == id
                ? s.copyWith(x: x.clamp(0.02, 0.98), y: y.clamp(0.02, 0.98))
                : s,
        ]);
  }

  void _toggle(SeatId id) {
    if (id == SeatId.driver) return; // el conductor siempre existe
    setState(() => _seats = [
          for (final s in _seats)
            s.id == id ? s.copyWith(enabled: !s.enabled) : s,
        ]);
  }

  /// Añade una esquina en el centro del lado más largo.
  void _addCorner() {
    var best = 0;
    var bestLen = -1.0;
    for (var i = 0; i < _cabin.length; i++) {
      final a = _cabin[i], b = _cabin[(i + 1) % _cabin.length];
      final len = (a.$1 - b.$1) * (a.$1 - b.$1) + (a.$2 - b.$2) * (a.$2 - b.$2);
      if (len > bestLen) {
        bestLen = len;
        best = i;
      }
    }
    final a = _cabin[best], b = _cabin[(best + 1) % _cabin.length];
    setState(() => _cabin.insert(best + 1, ((a.$1 + b.$1) / 2, (a.$2 + b.$2) / 2)));
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: buildTheme(Brightness.dark),
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          title: Text(widget.title),
          actions: [
            TextButton(
              onPressed: () => setState(() {
                if (_mode == _Mode.cabin) {
                  _cabin = [...defaultCabin];
                } else {
                  _seats = [
                    for (final d in SeatPoint.defaults)
                      d.copyWith(
                          enabled:
                              _seats.firstWhere((s) => s.id == d.id).enabled),
                  ];
                }
              }),
              child: const Text('Restablecer'),
            ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              Expanded(
                child: Center(
                  child: AspectRatio(
                    aspectRatio: widget.aspectRatio,
                    child: LayoutBuilder(builder: (context, c) {
                      final size = c.biggest;
                      return ClipRect(
                        child: Stack(
                          children: [
                            Positioned.fill(child: widget.background),
                            Positioned.fill(
                              child: CustomPaint(
                                painter: _CabinPainter(
                                  _cabin,
                                  enabled: _cabinOn,
                                  editing: _mode == _Mode.cabin,
                                ),
                              ),
                            ),
                            for (final s in _seats) _marker(s, size),
                            if (_mode == _Mode.cabin && _cabinOn)
                              for (var i = 0; i < _cabin.length; i++)
                                _corner(i, size),
                          ],
                        ),
                      );
                    }),
                  ),
                ),
              ),
              _panel(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _marker(SeatPoint s, Size size) {
    const r = 30.0;
    final color = seatColor(s.id);
    final active = _dragging == s.id;
    final editable = _mode == _Mode.seats;
    return Positioned(
      left: s.x * size.width - r,
      top: s.y * size.height - r,
      child: IgnorePointer(
        ignoring: !editable,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (_) => setState(() => _dragging = s.id),
          onPanUpdate: (d) => _moveSeat(
              s.id, Offset(s.x * size.width, s.y * size.height) + d.delta, size),
          onPanEnd: (_) => setState(() => _dragging = null),
          onTap: () => _toggle(s.id),
          child: Opacity(
            opacity: !s.enabled ? 0.35 : (editable ? 1 : 0.55),
            child: SizedBox(
              width: r * 2,
              height: r * 2,
              child: Center(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  width: active ? r * 2 : r * 1.6,
                  height: active ? r * 2 : r * 1.6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: color.withValues(alpha: s.enabled ? 0.85 : 0.3),
                    border: Border.all(color: Colors.white, width: 3),
                    boxShadow: const [
                      BoxShadow(color: Colors.black54, blurRadius: 8),
                    ],
                  ),
                  alignment: Alignment.center,
                  child: Text(s.id.short,
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w900,
                          fontSize: 15)),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _corner(int i, Size size) {
    const r = 22.0;
    final (x, y) = _cabin[i];
    final active = _draggingCorner == i;
    return Positioned(
      left: x * size.width - r,
      top: y * size.height - r,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) => setState(() => _draggingCorner = i),
        onPanUpdate: (d) => setState(() => _cabin[i] = _clampPt(
            Offset(x * size.width, y * size.height) + d.delta, size)),
        onPanEnd: (_) => setState(() => _draggingCorner = null),
        child: SizedBox(
          width: r * 2,
          height: r * 2,
          child: Center(
            child: Container(
              width: active ? 26 : 20,
              height: active ? 26 : 20,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(5),
                border: Border.all(color: AppColors.info, width: 3),
                boxShadow: const [
                  BoxShadow(color: Colors.black54, blurRadius: 6),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _panel() {
    final s = Surfaces.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: s.card,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SegmentedButton<_Mode>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(
                  value: _Mode.seats,
                  icon: Icon(Icons.event_seat_rounded),
                  label: Text('Asientos')),
              ButtonSegment(
                  value: _Mode.cabin,
                  icon: Icon(Icons.crop_free_rounded),
                  label: Text('Jaula')),
            ],
            selected: {_mode},
            onSelectionChanged: (v) => setState(() => _mode = v.first),
          ),
          const SizedBox(height: 10),
          if (_mode == _Mode.seats) ...[
            Text(
              'Arrastra cada círculo hasta el asiento donde se sienta esa '
              'persona. Toca un asiento para activarlo o desactivarlo.',
              style: TextStyle(fontSize: 13.5, color: s.textSecondary),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final p in _seats)
                  FilterChip(
                    avatar: CircleAvatar(
                        backgroundColor: seatColor(p.id), radius: 6),
                    label: Text(p.id.label),
                    selected: p.enabled,
                    onSelected:
                        p.id == SeatId.driver ? null : (_) => _toggle(p.id),
                  ),
              ],
            ),
          ] else ...[
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: _cabinOn,
              onChanged: (v) => setState(() => _cabinOn = v),
              title: const Text('Usar jaula',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              subtitle: const Text('Solo cuentan las personas dentro del '
                  'contorno. Quien se vea por las ventanas se ignora.'),
            ),
            if (_cabinOn)
              Row(
                children: [
                  Expanded(
                    child: Text('Arrastra las esquinas al borde del interior.',
                        style:
                            TextStyle(fontSize: 13, color: s.textSecondary)),
                  ),
                  IconButton(
                    tooltip: 'Quitar esquina',
                    onPressed: _cabin.length > 3
                        ? () => setState(() => _cabin.removeLast())
                        : null,
                    icon: const Icon(Icons.remove_circle_outline),
                  ),
                  IconButton(
                    tooltip: 'Añadir esquina',
                    onPressed: _cabin.length < 10 ? _addCorner : null,
                    icon: const Icon(Icons.add_circle_outline),
                  ),
                ],
              ),
          ],
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: () => Navigator.pop(
                context, CalibrationResult(_seats, _cabin, _cabinOn)),
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Text('Empezar'),
          ),
        ],
      ),
    );
  }
}

/// Contorno de la jaula: fuera del polígono se oscurece.
class _CabinPainter extends CustomPainter {
  final List<(double, double)> cabin;
  final bool enabled, editing;
  _CabinPainter(this.cabin, {required this.enabled, required this.editing});

  @override
  void paint(Canvas canvas, Size size) {
    if (!enabled || cabin.length < 3) return;
    final path = Path()
      ..moveTo(cabin.first.$1 * size.width, cabin.first.$2 * size.height);
    for (final p in cabin.skip(1)) {
      path.lineTo(p.$1 * size.width, p.$2 * size.height);
    }
    path.close();
    final outside = Path.combine(
        PathOperation.difference, Path()..addRect(Offset.zero & size), path);
    canvas.drawPath(outside, Paint()..color = Colors.black.withValues(alpha: 0.55));
    canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = editing ? 3 : 2
          ..color = AppColors.info);
  }

  @override
  bool shouldRepaint(_CabinPainter old) => true;
}
