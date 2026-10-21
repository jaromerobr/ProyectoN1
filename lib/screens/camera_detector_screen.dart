import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/app_settings.dart';
import '../models/seat.dart';
import '../models/trip_record.dart';
import '../services/background_capture.dart';
import '../services/detection_session.dart';
import '../services/screen_control.dart';
import '../services/trip_extras.dart';
import '../services/trip_location.dart';
import '../ui/theme.dart';
import '../utils/format.dart';
import '../widgets/black_screen.dart';
import '../widgets/detection_view.dart';
import 'seat_calibration_screen.dart';
import '../widgets/seat_calibration_bar.dart';
import '../widgets/trip_status_panel.dart';

/// Modo en vivo.
///
/// - Visible: el plugin `camera` da vista previa + fotogramas YUV.
/// - En segundo plano (otra app abierta o pantalla apagada): CaptureService
///   (servicio en primer plano de Android) abre la cámara sin vista previa y
///   este widget sigue analizando sus fotogramas; la notificación muestra el
///   estado de la carrera.
///
/// La pantalla se fija en vertical (teléfono montado fijo) para que la
/// rotación del fotograma sea siempre `sensorOrientation`.
class CameraDetectorScreen extends StatefulWidget {
  final AppSettings settings;
  const CameraDetectorScreen({super.key, required this.settings});

  @override
  State<CameraDetectorScreen> createState() => _CameraDetectorScreenState();
}

class _CameraDetectorScreenState extends State<CameraDetectorScreen>
    with WidgetsBindingObserver {
  static const _idleBeforeBlack = Duration(minutes: 1);

  late final DetectionSession _session;
  CameraController? _controller;
  CameraDescription? _camera;
  String? _cameraError;

  SeatId? _editingSeat;
  bool _black = false;
  Timer? _idle;
  Timer? _thermalTimer;
  late final TripExtras _extras;

  bool _serviceStarted = false;
  bool _background = false;
  int _bgToken = 0;
  DateTime _lastNotify = DateTime(0);

  late bool _front = widget.settings.useFrontCamera;
  bool _switching = false;

  /// Cambia entre cámara trasera y frontal y lo recuerda.
  Future<void> _switchCamera() async {
    if (_switching) return;
    _switching = true;
    await _stopCamera();
    setState(() => _front = !_front);
    _session.updateSettings(
        _session.settings.copyWith(useFrontCamera: _front));
    await _startCamera();
    _switching = false;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    WakelockPlus.enable();
    _extras = TripExtras(widget.settings, gps: true);
    _session =
        DetectionSession(
            source: TripSource.live,
            settings: widget.settings,
            onTripSaved: _onTripSaved,
            onTripStarted: _extras.onTripStarted,
            enrichTrip: _extras.enrich,
          )
          ..addListener(_updateNotification)
          ..init();
    _pollThermal();
    _thermalTimer = Timer.periodic(
        const Duration(seconds: 15), (_) => _pollThermal());
    _startCamera();
    _resetIdle();
  }

  Future<void> _startCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) throw Exception('No hay cámaras disponibles');
      final wanted = _front
          ? CameraLensDirection.front
          : CameraLensDirection.back;
      _camera = cameras.firstWhere(
        (c) => c.lensDirection == wanted,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        _camera!,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await controller.initialize();
      if (!mounted || _background) {
        controller.dispose();
        return;
      }
      await controller.startImageStream(_onFrame);
      setState(() {
        _controller = controller;
        _cameraError = null;
      });
      _ensureService();
      if (!_calibratedOnce && _session.settings.calibrateOnStart) {
        _calibratedOnce = true;
        _calibrate();
      }
    } catch (e) {
      if (mounted) setState(() => _cameraError = e.toString());
    }
  }

  /// Se arranca con la app visible y el permiso de cámara ya concedido
  /// (Android solo deja usar la cámara en segundo plano en ese caso).
  Future<void> _ensureService() async {
    if (_serviceStarted) return;
    // El permiso de ubicación se pide antes de arrancar el servicio para que
    // Android le permita usar el GPS también en segundo plano.
    if (_extras.useGps) await TripLocation.ensurePermission();
    try {
      await BackgroundCapture.startService();
      _serviceStarted = true;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Puedes abrir otra app o apagar la pantalla: '
              'el conteo sigue en segundo plano.',
            ),
            duration: Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      debugPrint('No se pudo iniciar el servicio: $e');
    }
  }

  void _onFrame(CameraImage image) {
    // Se descartan fotogramas mientras el modelo trabaja en el anterior.
    if (!_session.canAcceptFrame || _background || _calibrating) return;
    final cam = _camera!;
    _session.process(
      (d) => d.detectCameraImage(
        image,
        rotation: cam.sensorOrientation,
        mirror: cam.lensDirection == CameraLensDirection.front,
        confidence: _session.detectorConfidence,
        iou: _session.settings.iou,
      ),
      DateTime.now(),
    );
  }

  // --- Calibración -----------------------------------------------------------

  bool _calibrating = false;
  bool _calibratedOnce = false;

  /// Calibración a pantalla completa sobre la imagen en vivo de la cámara.
  /// Mientras dura no se analizan fotogramas (no se abren carreras).
  Future<void> _calibrate() async {
    final c = _controller;
    if (c == null || _calibrating) return;
    _calibrating = true;
    final ps = c.value.previewSize!;
    final r = await Navigator.of(context).push<CalibrationResult>(
      MaterialPageRoute(
        builder: (_) => SeatCalibrationScreen(
          title: 'Calibra la cámara',
          aspectRatio: ps.height / ps.width,
          seats: _session.settings.seats,
          cabin: _session.settings.cabin,
          cabinEnabled: _session.settings.cabinEnabled,
          background: FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
                width: ps.height, height: ps.width, child: CameraPreview(c)),
          ),
        ),
      ),
    );
    _calibrating = false;
    if (r != null && mounted) {
      _session.updateSettings(_session.settings.copyWith(
          seats: r.seats,
          cabin: r.cabin,
          cabinEnabled: r.cabinEnabled,
          seatCalibrated: true));
    }
    _resetIdle();
  }

  // --- Segundo plano --------------------------------------------------------

  Future<void> _enterBackground() async {
    if (_background || !_serviceStarted) return;
    _background = true;
    await _stopCamera();
    await BackgroundCapture.startCapture(
      front: _front,
      wide:
          _session.imageWidth > 0 &&
          (_session.imageHeight / _session.imageWidth - 16 / 9).abs() < 0.2,
    );
    _backgroundLoop(++_bgToken);
    _updateNotification(force: true);
  }

  Future<void> _leaveBackground() async {
    if (!_background) return;
    _background = false;
    _bgToken++;
    await BackgroundCapture.stopCapture();
    _updateNotification(force: true);
  }

  Future<void> _backgroundLoop(int token) async {
    while (token == _bgToken && mounted) {
      final f = _session.canAcceptFrame
          ? await BackgroundCapture.frame()
          : null;
      if (f == null) {
        await Future.delayed(const Duration(milliseconds: 80));
        continue;
      }
      await _session.process(
        (d) => d.detectRgba(
          f.rgba,
          f.width,
          f.height,
          rotation: f.rotation,
          mirror: _front,
          confidence: _session.detectorConfidence,
          iou: _session.settings.iou,
        ),
        DateTime.now(),
      );
    }
  }

  void _updateNotification({bool force = false}) {
    if (!_serviceStarted) return;
    final now = DateTime.now();
    if (!force && now.difference(_lastNotify) < const Duration(seconds: 1)) {
      return;
    }
    _lastNotify = now;
    final t = _session.tracker;
    final seats = _session.occupiedSeats.keys
        .where((s) => s != SeatId.driver)
        .map((s) => s.short)
        .join(' ');
    final title = t.inTrip
        ? 'En carrera · ${formatDuration(t.elapsed(_session.clock))}'
        : 'Taxiff · Libre';
    final text =
        '${_session.passengers} pasajero(s)'
        '${seats.isEmpty ? '' : ' · $seats'}'
        '${_background ? ' · contando en segundo plano' : ''}';
    BackgroundCapture.notify(title, text).catchError((_) {});
  }

  void _onTripSaved(TripRecord trip) {
    if (!mounted || _black || _background) return;
    final seats = trip.seats.where((s) => s != SeatId.driver);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Carrera guardada: ${humanDuration(trip.duration)} · '
          '${trip.maxPassengers} pasajero(s)'
          '${seats.isEmpty ? '' : ' · ${seats.map((s) => s.short).join(' ')}'}',
        ),
      ),
    );
  }

  // --- Temperatura ----------------------------------------------------------

  Future<void> _pollThermal() async {
    final (status, temp) = await ScreenControl.thermal();
    final wasHot = _session.thermalStatus >= 3;
    _session.setThermal(status, temp);
    if (!wasHot && status >= 3) {
      _extras.announcer.warn('Teléfono caliente, bajando el ritmo');
    }
  }

  // --- Pantalla negra -------------------------------------------------------

  void _resetIdle() {
    _idle?.cancel();
    if (!_session.settings.autoBlackScreen) return;
    _idle = Timer(_idleBeforeBlack, () {
      if (mounted && _editingSeat == null && !_background) _setBlack(true);
    });
  }

  void _setBlack(bool on) {
    if (_black == on) return;
    setState(() => _black = on);
    SystemChrome.setEnabledSystemUIMode(
      on ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
    if (!on) _resetIdle();
  }

  // --- Ciclo de vida --------------------------------------------------------

  Future<void> _stopCamera() async {
    final c = _controller;
    _controller = null;
    if (c == null) return;
    if (c.value.isStreamingImages) await c.stopImageStream();
    await c.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.inactive:
        if (!_background) {
          _stopCamera();
          if (mounted) setState(() {});
        }
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        _enterBackground();
      case AppLifecycleState.resumed:
        () async {
          await _leaveBackground();
          if (_controller == null && mounted) _startCamera();
        }();
      case AppLifecycleState.detached:
        break;
    }
  }

  @override
  void dispose() {
    _idle?.cancel();
    _thermalTimer?.cancel();
    _bgToken++;
    WidgetsBinding.instance.removeObserver(this);
    _session.removeListener(_updateNotification);
    _session.finish(DateTime.now()).whenComplete(() {
      _session.dispose();
      _extras.dispose();
    });
    _stopCamera();
    if (_serviceStarted) {
      BackgroundCapture.stopCapture().whenComplete(
        BackgroundCapture.stopService,
      );
    }
    WakelockPlus.disable();
    SystemChrome.setPreferredOrientations([]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  // --- UI -------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final private = _session.settings.privateView;
    return Theme(
      data: buildTheme(Brightness.dark),
      child: Listener(
        onPointerDown: (_) => _resetIdle(),
        child: Stack(
          children: [
            Scaffold(
              appBar: AppBar(
                title: const Text('En vivo'),
                actions: [
                  IconButton(
                    tooltip: 'Calibrar asientos',
                    icon: Icon(
                      _editingSeat == null
                          ? Icons.event_seat_outlined
                          : Icons.event_seat,
                    ),
                    onPressed: _controller == null ? null : _calibrate,
                  ),
                  IconButton(
                    tooltip: private ? 'Mostrar imagen' : 'Vista privada',
                    icon: Icon(
                      private
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                    ),
                    onPressed: () => setState(
                      () => _session.updateSettings(
                        _session.settings.copyWith(privateView: !private),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip:
                        _front ? 'Usar cámara trasera' : 'Usar cámara frontal',
                    icon: const Icon(Icons.cameraswitch_outlined),
                    onPressed: _controller == null ? null : _switchCamera,
                  ),
                  IconButton(
                    tooltip: 'Pantalla negra',
                    icon: const Icon(Icons.dark_mode_outlined),
                    onPressed: () => _setBlack(true),
                  ),
                  ListenableBuilder(
                    listenable: _session,
                    builder: (_, _) => IconButton(
                      tooltip: 'Cerrar carrera ahora',
                      icon: const Icon(Icons.stop_circle_outlined),
                      onPressed: _session.tracker.inTrip
                          ? () => _session.finish(DateTime.now())
                          : null,
                    ),
                  ),
                ],
              ),
              body: SafeArea(
                top: false,
                child: Column(
                  children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(10, 4, 10, 0),
                        child: Center(child: _buildPreview()),
                      ),
                    ),
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
            ),
            if (_black)
              Positioned.fill(
                child: BlackScreen(
                  session: _session,
                  onExit: () => _setBlack(false),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildPreview() {
    if (_cameraError != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          'Error de cámara: $_cameraError',
          textAlign: TextAlign.center,
        ),
      );
    }
    final c = _controller;
    return ListenableBuilder(
      listenable: _session,
      builder: (context, _) {
        if (_session.error != null && !_session.ready) {
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Text(_session.error!, textAlign: TextAlign.center),
          );
        }
        if (c == null || !c.value.isInitialized || _session.loading) {
          return const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 12),
              Text('Cargando cámara y modelo…'),
            ],
          );
        }
        // previewSize viene en horizontal; en vertical se intercambia.
        final ps = c.value.previewSize!;
        final previewW = ps.height, previewH = ps.width;
        // El overlay usa el aspecto real del fotograma analizado; la vista
        // previa se recorta centrada si su aspecto fuese distinto.
        final aspect = _session.imageWidth > 0
            ? _session.imageWidth / _session.imageHeight
            : previewW / previewH;
        return DetectionView(
          session: _session,
          aspectRatio: aspect,
          editingSeat: _editingSeat,
          privateView: _session.settings.privateView,
          background: FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: previewW,
              height: previewH,
              child: CameraPreview(c),
            ),
          ),
        );
      },
    );
  }
}
