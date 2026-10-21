import 'dart:async';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/app_settings.dart';
import '../models/seat.dart';
import '../models/trip_record.dart';
import '../services/detection_session.dart';
import '../services/trip_extras.dart';
import '../services/video_frame_source.dart';
import '../ui/theme.dart';
import '../utils/format.dart';
import '../widgets/detection_view.dart';
import 'seat_calibration_screen.dart';
import '../widgets/seat_calibration_bar.dart';
import '../widgets/trip_status_panel.dart';

/// Modo simulación: recorre un vídeo local fotograma a fotograma (cada
/// `simulationStepMs` de vídeo) y usa el tiempo del vídeo como reloj de la
/// carrera, así las duraciones son correctas aunque el teléfono analice
/// más lento o más rápido que el tiempo real.
class VideoSimulationScreen extends StatefulWidget {
  final AppSettings settings;
  const VideoSimulationScreen({super.key, required this.settings});

  @override
  State<VideoSimulationScreen> createState() => _VideoSimulationScreenState();
}

class _VideoSimulationScreenState extends State<VideoSimulationScreen> {
  late final DetectionSession _session;
  late final TripExtras _extras;
  final _source = VideoFrameSource();

  String? _videoName;
  bool _videoOpen = false;
  bool _searching = true;
  String? _videoError;

  ui.Image? _frame;
  Duration _pos = Duration.zero;

  /// Instante "real" que corresponde a la posición 0 del vídeo.
  DateTime _base = DateTime.now();
  bool _playing = false;
  bool _ended = false;
  int _loopToken = 0;

  /// 0 = tan rápido como pueda el modelo.
  double _speed = 1;

  SeatId? _editingSeat;

  /// Vídeo de más de 3 min: se analiza 1 imagen por segundo de vídeo, con
  /// fotogramas clave (mucho más rápido) y se guarda el avance.
  bool _long = false;
  static const _longVideo = Duration(minutes: 3);

  /// Media móvil del tiempo real que cuesta cada paso (para estimar lo que
  /// falta).
  double _avgStepMs = 0;
  String? _resumeKey;
  DateTime _lastSave = DateTime(0);

  Duration get _step => Duration(
      milliseconds: _long
          ? widget.settings.simulationStepMs.clamp(1000, 5000)
          : widget.settings.simulationStepMs);

  int _failures = 0;

  /// Siguiente fotograma ya pedido (extracción en paralelo al análisis).
  (Duration, Future<VideoFrame?>)? _prefetch;

  Duration? get _eta {
    if (_avgStepMs == 0 || !_videoOpen) return null;
    final left = _source.duration - _pos;
    if (left <= Duration.zero) return Duration.zero;
    final steps = left.inMilliseconds / _step.inMilliseconds;
    final perStep = _speed > 0
        ? (_avgStepMs > _step.inMilliseconds / _speed
            ? _avgStepMs
            : _step.inMilliseconds / _speed)
        : _avgStepMs;
    return Duration(milliseconds: (steps * perStep).round());
  }

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    _extras = TripExtras(widget.settings, gps: false);
    _session = DetectionSession(
      source: TripSource.simulation,
      settings: widget.settings.copyWith(
          seats: widget.settings.simSeats,
          cabinEnabled: widget.settings.simCabinEnabled,
          cabin: widget.settings.simCabin),
      onTripSaved: _onTripSaved,
      onTripStarted: _extras.onTripStarted,
      enrichTrip: _extras.enrich,
    );
    _session.init().then((_) => _loadBundledVideo());
  }

  Future<void> _loadBundledVideo() async {
    final path = await VideoFrameSource.bundledVideoPath();
    if (path != null) {
      await _openVideo(path, 'video_prueba.mp4');
    } else if (mounted) {
      setState(() => _searching = false);
    }
  }

  Future<void> _pickVideo() async {
    final files = await FilePicker.pickFiles(type: FileType.video);
    if (files.isEmpty) return;
    final f = files.first;
    // Ruta local o URI content:// (se lee directamente, sin copiar el vídeo).
    await _openVideo(f.path ?? f.uri.toString(), f.name);
  }

  Future<void> _openVideo(String path, String name) async {
    _pause();
    await _session.finish(_session.clock);
    try {
      await _source.open(path);
    } catch (e) {
      if (mounted) {
        setState(() {
          _searching = false;
          _videoError = 'No se pudo abrir el vídeo: $e';
        });
      }
      return;
    }
    if (!mounted) return;
    final long = _source.duration > _longVideo;
    _resumeKey = 'sim_pos_${name}_${_source.duration.inSeconds}';
    final prefs = await SharedPreferences.getInstance();
    final saved = Duration(milliseconds: prefs.getInt(_resumeKey!) ?? 0);
    var start = Duration.zero;
    if (saved > const Duration(minutes: 1) &&
        saved < _source.duration - const Duration(minutes: 1) &&
        mounted) {
      final resume = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('¿Continuar el análisis?'),
          content: Text('Este vídeo se quedó en ${formatDuration(saved)} '
              'de ${formatDuration(_source.duration)}.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Desde el inicio')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Continuar')),
          ],
        ),
      );
      if (resume == true) start = saved;
    }
    if (!mounted) return;
    setState(() {
      _searching = false;
      _videoError = null;
      _videoOpen = true;
      _videoName = name;
      _pos = start;
      _ended = false;
      _long = long;
      _avgStepMs = 0;
      _prefetch = null;
      // Las carreras llevan la hora real de la grabación si el vídeo la tiene.
      _base = _source.recordedAt ?? DateTime.now();
      if (long) _speed = 0; // vídeo largo: lo más rápido posible
    });
    if (_session.settings.calibrateOnStart) await _calibrate();
    if (mounted) _play();
  }

  /// Calibración a pantalla completa sobre el fotograma actual del vídeo.
  Future<void> _calibrate() async {
    final wasPlaying = _playing;
    _pause();
    VideoFrame? f;
    try {
      f = await _source.frameAt(_pos);
    } catch (_) {}
    if (f == null || !mounted) return;
    final img = await _decode(f);
    if (!mounted) {
      img.dispose();
      return;
    }
    setState(() {
      _frame?.dispose();
      _frame = img;
    });
    final r = await Navigator.of(context).push<CalibrationResult>(
      MaterialPageRoute(
        builder: (_) => SeatCalibrationScreen(
          title: 'Calibra este vídeo',
          background: RawImage(image: img, fit: BoxFit.fill),
          aspectRatio: img.width / img.height,
          seats: _session.settings.seats,
          cabin: _session.settings.cabin,
          cabinEnabled: _session.settings.cabinEnabled,
        ),
      ),
    );
    if (r != null) {
      _session.updateSettings(_session.settings.copyWith(
          seats: r.seats,
          cabin: r.cabin,
          cabinEnabled: r.cabinEnabled,
          seatCalibrated: true));
    }
    if (wasPlaying && mounted) _play();
  }

  void _play() {
    if (!_videoOpen || !_session.ready) return;
    if (_ended) _seek(Duration.zero);
    setState(() => _playing = true);
    _run(++_loopToken);
  }

  void _pause() {
    _loopToken++;
    if (mounted) setState(() => _playing = false);
  }

  /// Saltar en el vídeo cierra la carrera en curso y mantiene el reloj
  /// monótono (el tiempo nunca retrocede para el cronómetro).
  void _seek(Duration to) {
    _prefetch = null;
    _session.finish(_session.clock);
    _base = _base.add(_pos - to);
    _pos = to;
    _ended = false;
  }

  Future<void> _run(int token) async {
    final wall = Stopwatch()..start();
    final startPos = _pos;
    while (token == _loopToken && mounted) {
      if (_pos > _source.duration) {
        await _session.finish(_base.add(_source.duration));
        if (_resumeKey != null) {
          (await SharedPreferences.getInstance()).remove(_resumeKey!);
        }
        if (mounted) {
          setState(() {
            _ended = true;
            _playing = false;
          });
        }
        return;
      }

      final stepWatch = Stopwatch()..start();
      final VideoFrame? frame;
      try {
        // Usa el fotograma pedido por adelantado si es el de esta posición.
        final pre = _prefetch;
        _prefetch = null;
        frame = await (pre != null && pre.$1 == _pos
            ? pre.$2
            : _source.frameAt(_pos, fast: _long));
        // Mientras el modelo analiza este, se extrae el siguiente.
        final next = _pos + _step;
        if (next <= _source.duration) {
          _prefetch = (next, _source.frameAt(next, fast: _long));
        }
      } catch (e) {
        if (mounted) setState(() => _videoError = e.toString());
        _pause();
        return;
      }
      if (token != _loopToken || !mounted) return;

      if (frame != null) {
        final decoded = _decode(frame);
        final ok = await _session.process(
          (d) => d.detectRgba(
            frame!.rgba,
            frame.width,
            frame.height,
            confidence: _session.detectorConfidence,
            iou: _session.settings.iou,
          ),
          _base.add(_pos),
        );
        // Si el modelo falla seguido, se detiene en vez de recorrer el vídeo
        // sin analizar nada.
        _failures = ok || _session.error == null ? 0 : _failures + 1;
        if (_failures >= 3) {
          (await decoded).dispose();
          if (mounted) {
            setState(() => _videoError =
                'El modelo falló al analizar el vídeo (${_session.error}). '
                'Prueba otro modelo en Ajustes › Modelo de detección.');
          }
          _pause();
          return;
        }
        final img = await decoded;
        if (!mounted) {
          img.dispose();
          return;
        }
        setState(() {
          _frame?.dispose();
          _frame = img;
        });
      }

      _pos += _step;
      final ms = stepWatch.elapsedMilliseconds.toDouble();
      _avgStepMs = _avgStepMs == 0 ? ms : _avgStepMs * 0.9 + ms * 0.1;
      if (_resumeKey != null &&
          DateTime.now().difference(_lastSave) > const Duration(seconds: 20)) {
        _lastSave = DateTime.now();
        SharedPreferences.getInstance()
            .then((p) => p.setInt(_resumeKey!, _pos.inMilliseconds));
      }
      if (_speed > 0) {
        final target = (_pos - startPos) * (1 / _speed);
        final wait = target - wall.elapsed;
        if (wait > Duration.zero) await Future.delayed(wait);
      }
    }
  }

  Future<ui.Image> _decode(VideoFrame f) {
    final c = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      f.rgba,
      f.width,
      f.height,
      ui.PixelFormat.rgba8888,
      c.complete,
    );
    return c.future;
  }

  void _onTripSaved(TripRecord trip) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Carrera guardada: ${humanDuration(trip.duration)} · '
          '${trip.maxPassengers} pasajero(s)',
        ),
      ),
    );
  }

  @override
  void dispose() {
    _loopToken++;
    _session.finish(_session.clock).whenComplete(() {
      _session.dispose();
      _extras.dispose();
    });
    if (_videoOpen) _source.close();
    _frame?.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Theme(
    data: buildTheme(Brightness.dark),
    child: Builder(builder: _scaffold),
  );

  Widget _scaffold(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _videoName ?? 'Modo simulación',
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: 'Calibrar asientos',
            icon: Icon(
              _editingSeat == null
                  ? Icons.event_seat_outlined
                  : Icons.event_seat,
            ),
            onPressed: _videoOpen ? _calibrate : null,
          ),
          IconButton(
            tooltip: _session.settings.privateView
                ? 'Mostrar imagen'
                : 'Vista privada',
            icon: Icon(
              _session.settings.privateView
                  ? Icons.visibility_off
                  : Icons.visibility,
            ),
            onPressed: () => setState(
              () => _session.updateSettings(
                _session.settings.copyWith(
                  privateView: !_session.settings.privateView,
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Elegir vídeo',
            icon: const Icon(Icons.video_library_outlined),
            onPressed: _session.ready ? _pickVideo : null,
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Center(child: _buildVideo()),
              ),
            ),
            if (_videoOpen) _buildControls(),
            if (_editingSeat != null)
              SeatCalibrationBar(
                session: _session,
                selected: _editingSeat!,
                onSelect: (s) => setState(() => _editingSeat = s),
                onDone: () => setState(() => _editingSeat = null),
              ),
            TripStatusPanel(session: _session),
          ],
        ),
      ),
    );
  }

  Widget _buildVideo() {
    return ListenableBuilder(
      listenable: _session,
      builder: (context, _) {
        final error = _videoError ?? (_session.ready ? null : _session.error);
        if (error != null) {
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Text(error, textAlign: TextAlign.center),
          );
        }
        if (_session.loading || _searching) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 14),
              Text(_session.loading ? 'Cargando el modelo de IA…' : 'Buscando vídeo…'),
            ],
          );
        }
        if (!_videoOpen) {
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'No hay vídeo de prueba.\n'
                  'Añade assets/video_prueba.mp4 al proyecto o elige uno '
                  'de la galería.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _pickVideo,
                  icon: const Icon(Icons.video_library_outlined),
                  label: const Text('Elegir vídeo'),
                ),
              ],
            ),
          );
        }
        final f = _frame;
        if (f == null) return const CircularProgressIndicator();
        return DetectionView(
          editingSeat: _editingSeat,
          privateView: _session.settings.privateView,
          session: _session,
          aspectRatio: f.width / f.height,
          background: RawImage(image: f, fit: BoxFit.fill),
        );
      },
    );
  }

  Widget _buildControls() {
    final total = _source.duration;
    final pos = _pos > total ? total : _pos;
    final pct = total.inMilliseconds == 0
        ? 0
        : (pos.inMilliseconds / total.inMilliseconds * 100).round();
    final eta = _eta;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
          child: Row(
            children: [
              Icon(_long ? Icons.speed_rounded : Icons.movie_outlined,
                  size: 16, color: Surfaces.of(context).textSecondary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  [
                    'Analizado $pct %',
                    if (_playing && eta != null && eta > Duration.zero)
                      'quedan ~${humanDuration(eta)}',
                    _long
                        ? '1 imagen por segundo de vídeo'
                        : '${(1000 / _step.inMilliseconds).toStringAsFixed(0)} imágenes/s',
                    if (_source.recordedAt != null)
                      'grabado ${formatHm(_source.recordedAt!)}',
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 12,
                      color: Surfaces.of(context).textSecondary),
                ),
              ),
            ],
          ),
        ),
        _controlsRow(total, pos),
      ],
    );
  }

  Widget _controlsRow(Duration total, Duration pos) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          IconButton(
            icon: Icon(
              _playing
                  ? Icons.pause
                  : _ended
                  ? Icons.replay
                  : Icons.play_arrow,
            ),
            onPressed: _playing ? _pause : _play,
          ),
          Text(formatDuration(pos)),
          Expanded(
            child: Slider(
              value: pos.inMilliseconds.toDouble(),
              max: total.inMilliseconds.toDouble().clamp(1, double.infinity),
              onChanged: (v) {
                final wasPlaying = _playing;
                _pause();
                setState(() => _seek(Duration(milliseconds: v.round())));
                if (wasPlaying) _play();
              },
            ),
          ),
          Text(formatDuration(total)),
          PopupMenuButton<double>(
            tooltip: 'Velocidad',
            initialValue: _speed,
            onSelected: (v) => setState(() {
              _speed = v;
              if (_playing) {
                _pause();
                _play();
              }
            }),
            itemBuilder: (_) => [
              for (final v in const [1.0, 2.0, 4.0, 0.0])
                PopupMenuItem(
                  value: v,
                  child: Text(v == 0 ? 'Máx.' : '${v.toInt()}×'),
                ),
            ],
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                _speed == 0 ? 'Máx.' : '${_speed.toInt()}×',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
