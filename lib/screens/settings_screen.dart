import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/app_settings.dart';
import '../models/seat.dart';
import '../services/announcer.dart';
import '../services/background_capture.dart';
import '../services/evidence_store.dart';
import '../services/export_service.dart';
import '../services/owner_mode.dart';
import '../ui/car_seat_map.dart';
import '../ui/one_ui.dart';
import '../ui/theme.dart';
import '../utils/format.dart';
import '../widgets/privacy_notice.dart';

class SettingsScreen extends StatefulWidget {
  final AppSettings initial;
  const SettingsScreen({super.key, required this.initial});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late AppSettings _s = widget.initial;
  Set<String> _assets = {};

  @override
  void initState() {
    super.initState();
    AssetManifest.loadFromAssetBundle(rootBundle).then((m) {
      if (mounted) setState(() => _assets = m.listAssets().toSet());
    }).catchError((_) {});
  }

  Future<String?> _askPin(String title, {bool confirm = false}) async {
    final a = TextEditingController(), b = TextEditingController();
    InputDecoration deco(String hint) =>
        InputDecoration(hintText: hint, counterText: '');
    final pin = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: a,
              autofocus: true,
              obscureText: true,
              maxLength: 8,
              keyboardType: TextInputType.number,
              decoration: deco('PIN (4 a 8 números)'),
            ),
            if (confirm)
              TextField(
                controller: b,
                obscureText: true,
                maxLength: 8,
                keyboardType: TextInputType.number,
                decoration: deco('Repite el PIN'),
              ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar')),
          TextButton(
            onPressed: () {
              final p = a.text.trim();
              final ok = RegExp(r'^\d{4,8}$').hasMatch(p) &&
                  (!confirm || p == b.text.trim());
              Navigator.pop(ctx, ok ? p : '');
            },
            child: const Text('Aceptar'),
          ),
        ],
      ),
    );
    if (pin == '' && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('PIN no válido o no coincide (4 a 8 números).')));
      return null;
    }
    return pin;
  }

  Future<void> _createPin() async {
    final pin = await _askPin('PIN de propietario', confirm: true);
    if (pin == null) return;
    _set(_s.copyWith(ownerPin: pin));
    OwnerMode.unlocked.value = true;
  }

  Future<void> _enterOwner() async {
    final pin = await _askPin('Entrar como propietario');
    if (pin == null || !mounted) return;
    if (pin == _s.ownerPin) {
      OwnerMode.unlocked.value = true;
    } else {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('PIN incorrecto')));
    }
  }

  Future<void> _addDriver() async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Nuevo conductor'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(hintText: 'Nombre'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text),
              child: const Text('Añadir')),
        ],
      ),
    );
    final clean = name?.trim() ?? '';
    if (clean.isEmpty || _s.drivers.contains(clean)) return;
    _set(_s.copyWith(drivers: [..._s.drivers, clean]));
  }

  void _set(AppSettings s) {
    setState(() => _s = s);
    s.save();
  }

  @override
  Widget build(BuildContext context) {
    return OneUiPage(
      title: 'Ajustes',
      actions: [
        TextButton(
          onPressed: () => _set(const AppSettings()
              .copyWith(privacyAccepted: _s.privacyAccepted)),
          child: const Text('Restablecer'),
        ),
      ],
      slivers: [
        const SliverToBoxAdapter(child: SectionLabel('Asientos')),
        SliverToBoxAdapter(
          child: OneCard(
            child: Row(
              children: [
                CarSeatMap(
                  height: 190,
                  seats: {
                    for (final p in _s.seats)
                      p.id: SeatVisual(
                        color: p.enabled ? seatColor(p.id) : null,
                        intensity: 0.35,
                        disabled: !p.enabled,
                      ),
                  },
                ),
                const SizedBox(width: 18),
                const Expanded(
                  child: Text(
                    'Para calibrar, abre el modo en vivo o la simulación, '
                    'pulsa el icono de asiento, elige uno y toca a la persona '
                    'sentada en él.\n\nCada asiento admite una sola persona: '
                    'por eso solo puede haber un conductor.',
                    style: TextStyle(fontSize: 13.5, height: 1.35),
                  ),
                ),
              ],
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: OneGroup(children: [
            for (final seat in _s.seats)
              OneTile(
                leading: CircleAvatar(
                  radius: 16,
                  backgroundColor: seatColor(seat.id)
                      .withValues(alpha: seat.enabled ? 1 : 0.3),
                  child: Text(seat.id.short,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w800)),
                ),
                title: seat.id.label,
                subtitle: seat.id == SeatId.driver
                    ? 'Siempre activo'
                    : seat.enabled
                        ? 'Activo'
                        : 'Desactivado',
                trailing: Switch(
                  value: seat.enabled,
                  onChanged: seat.id == SeatId.driver
                      ? null
                      : (v) => _set(_s.withSeat(seat.copyWith(enabled: v))),
                ),
              ),
            _SliderTile(
              title: 'Tolerancia',
              help: 'Distancia máxima entre una persona y el punto del asiento '
                  'cuando su caja no lo cubre.',
              value: _s.seatRadius,
              min: 0.05,
              max: 0.4,
              divisions: 7,
              label: (v) => '${(v * 100).round()} %',
              onChanged: (v) => _set(_s.copyWith(seatRadius: v)),
            ),
            OneTile(
              title: 'Calibrar al empezar',
              subtitle: 'Al abrir el modo en vivo o cargar un vídeo, primero '
                  'se colocan los asientos a pantalla completa.',
              trailing: Switch(
                value: _s.calibrateOnStart,
                onChanged: (v) => _set(_s.copyWith(calibrateOnStart: v)),
              ),
            ),
            OneTile(
              title: 'Restablecer posiciones',
              subtitle: 'Vuelve a las posiciones iniciales de los asientos',
              subtitleColor: null,
              onTap: () => _set(_s.copyWith(
                  seats: SeatPoint.defaults, seatCalibrated: false)),
            ),
          ]),
        ),
        const SliverToBoxAdapter(child: SectionLabel('Carrera')),
        SliverToBoxAdapter(
          child: OneGroup(children: [
            _SliderTile(
              title: 'Confirmación de entrada',
              help: 'Tiempo que debe verse un pasajero para iniciar la carrera.',
              value: _s.enterConfirmSeconds,
              min: 0,
              max: 5,
              divisions: 10,
              label: (v) => '${v.toStringAsFixed(1)} s',
              onChanged: (v) => _set(_s.copyWith(enterConfirmSeconds: v)),
            ),
            _SliderTile(
              title: 'Espera de salida',
              help: 'Tiempo sin pasajeros para cerrar la carrera.',
              value: _s.exitGraceSeconds,
              min: 1,
              max: 60,
              divisions: 59,
              label: (v) => '${v.toStringAsFixed(0)} s',
              onChanged: (v) => _set(_s.copyWith(exitGraceSeconds: v)),
            ),
            _SliderTile(
              title: 'Duración mínima de una carrera',
              help: 'Las más cortas se descartan como falsos positivos '
                  '(alguien que se asoma, un reflejo, un corte de vídeo).',
              value: _s.minTripSeconds.toDouble(),
              min: 0,
              max: 300,
              divisions: 10,
              label: (v) => v == 0 ? 'sin mínimo' : humanDuration(Duration(seconds: v.round())),
              onChanged: (v) => _set(_s.copyWith(minTripSeconds: v.round())),
            ),
          ]),
        ),
        const SliverToBoxAdapter(child: SectionLabel('Conductores')),
        SliverToBoxAdapter(
          child: OneGroup(children: [
            for (final d in _s.drivers)
              OneTile(
                leading: CircleAvatar(
                  radius: 16,
                  backgroundColor: AppColors.accent.withValues(alpha: 0.2),
                  child: Text(d.isEmpty ? '?' : d[0].toUpperCase(),
                      style: const TextStyle(
                          color: AppColors.accent,
                          fontWeight: FontWeight.w800)),
                ),
                title: d,
                trailing: IconButton(
                  tooltip: 'Quitar',
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => _set(_s.copyWith(
                      drivers: [..._s.drivers]..remove(d))),
                ),
              ),
            OneTile(
              leading: const IconBadge(Icons.person_add_alt_1_rounded,
                  AppColors.accent, size: 32),
              title: 'Añadir conductor',
              subtitle: 'Se elige al iniciar el turno en la pantalla principal',
              onTap: _addDriver,
            ),
          ]),
        ),
        const SliverToBoxAdapter(child: SectionLabel('Carrera: ubicación y avisos')),
        SliverToBoxAdapter(
          child: OneGroup(children: [
            OneTile(
              leading: const IconBadge(Icons.place_rounded, AppColors.danger),
              title: 'Guardar origen, destino y distancia',
              subtitle: 'Usa el GPS solo durante las carreras.',
              trailing: Switch(
                value: _s.gpsEnabled,
                onChanged: (v) => _set(_s.copyWith(gpsEnabled: v)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Aviso al empezar y terminar',
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w500)),
                  const SizedBox(height: 10),
                  SegmentedButton<AnnounceMode>(
                    showSelectedIcon: false,
                    segments: [
                      for (final m in AnnounceMode.values)
                        ButtonSegment(value: m, label: Text(m.label)),
                    ],
                    selected: {_s.announce},
                    onSelectionChanged: (v) =>
                        _set(_s.copyWith(announce: v.first)),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                            'Para no mirar la pantalla al manejar. Por '
                            'discreción no dice cuántos pasajeros hay.',
                            style: TextStyle(
                                fontSize: 13,
                                color: Surfaces.of(context).textSecondary)),
                      ),
                      TextButton(
                        onPressed: _s.announce == AnnounceMode.off
                            ? null
                            : () => Announcer(_s.announce)
                                .tripEnded(const Duration(minutes: 12)),
                        child: const Text('Probar'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ]),
        ),
        const SliverToBoxAdapter(child: SectionLabel('Pantalla y segundo plano')),
        SliverToBoxAdapter(
          child: OneGroup(children: [
            OneTile(
              leading: const IconBadge(Icons.dark_mode_rounded, Color(0xFF5E5CE6)),
              title: 'Pantalla negra automática',
              subtitle: 'Tras 1 minuto sin tocar. Doble toque para volver.',
              trailing: Switch(
                value: _s.autoBlackScreen,
                onChanged: (v) => _set(_s.copyWith(autoBlackScreen: v)),
              ),
            ),
            const OneTile(
              leading: IconBadge(Icons.layers_rounded, AppColors.info),
              title: 'Funciona en segundo plano',
              subtitle: 'Puedes abrir otras apps (p. ej. Ktaxi) o apagar la '
                  'pantalla: el conteo sigue y verás una notificación.',
            ),
            const OneTile(
              leading: IconBadge(Icons.battery_charging_full_rounded,
                  AppColors.passenger),
              title: 'Batería sin restricciones',
              subtitle: 'Recomendado en Samsung para que el sistema no detenga '
                  'el conteo en segundo plano.',
              onTap: BackgroundCapture.requestBatteryUnrestricted,
            ),
          ]),
        ),
        const SliverToBoxAdapter(child: SectionLabel('Evidencias fotográficas')),
        SliverToBoxAdapter(
          child: OneGroup(children: [
            OneTile(
              leading: const IconBadge(Icons.photo_library_rounded, AppColors.purple),
              title: 'Guardar fotos de cada carrera',
              subtitle: 'Con las cajas, el número de cada persona y la hora: '
                  'al empezar, cuando alguien sube, cambia de asiento o baja, '
                  'y cada cierto tiempo. Solo en este teléfono.',
              trailing: Switch(
                value: _s.evidenceEnabled,
                onChanged: (v) => _set(_s.copyWith(evidenceEnabled: v)),
              ),
            ),
            if (_s.evidenceEnabled) ...[
              _ChoiceTile<int>(
                title: 'Una foto cada',
                value: _s.evidenceIntervalSec,
                options: const {15: '15 s', 30: '30 s', 60: '1 min'},
                onChanged: (v) => _set(_s.copyWith(evidenceIntervalSec: v)),
              ),
              _ChoiceTile<int>(
                title: 'Conservar',
                value: _s.evidenceRetentionDays,
                options: const {7: '7 días', 30: '30 días', 0: 'Siempre'},
                onChanged: (v) => _set(_s.copyWith(evidenceRetentionDays: v)),
              ),
            ],
            FutureBuilder<int>(
              future: EvidenceStore.sizeBytes(),
              builder: (context, snap) => OneTile(
                leading: const IconBadge(Icons.delete_sweep_rounded, AppColors.danger),
                title: 'Borrar todas las fotos',
                subtitle: snap.hasData
                    ? 'Ocupan ${(snap.data! / 1048576).toStringAsFixed(1)} MB'
                    : 'Calculando espacio…',
                onTap: () async {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('¿Borrar todas las fotos de evidencia?'),
                      content: const Text('Las carreras se conservan; solo se '
                          'borran sus fotos.'),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: const Text('Cancelar')),
                        TextButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            child: const Text('Borrar',
                                style: TextStyle(color: AppColors.danger))),
                      ],
                    ),
                  );
                  if (ok == true) {
                    await EvidenceStore.deleteAll();
                    if (mounted) setState(() {});
                  }
                },
              ),
            ),
          ]),
        ),
        const SliverToBoxAdapter(child: SectionLabel('Propietario')),
        SliverToBoxAdapter(
          child: ValueListenableBuilder<bool>(
            valueListenable: OwnerMode.unlocked,
            builder: (context, unlocked, _) => OneGroup(children: [
              if (_s.ownerPin.isEmpty)
                OneTile(
                  leading: const IconBadge(
                      Icons.admin_panel_settings_rounded, AppColors.accent),
                  title: 'Crear PIN de propietario',
                  subtitle: 'Con el PIN verás las carreras que borre el '
                      'conductor y podrás restaurarlas.',
                  onTap: _createPin,
                )
              else if (!unlocked)
                OneTile(
                  leading: const IconBadge(
                      Icons.lock_rounded, AppColors.accent),
                  title: 'Entrar como propietario',
                  subtitle: 'Ver y restaurar carreras borradas',
                  onTap: _enterOwner,
                )
              else ...[
                OneTile(
                  leading: const IconBadge(
                      Icons.lock_open_rounded, AppColors.passenger),
                  title: 'Modo propietario activo',
                  subtitle: 'La bitácora muestra también las carreras '
                      'borradas. Toca para salir.',
                  onTap: () => OwnerMode.unlocked.value = false,
                ),
                OneTile(
                  title: 'Cambiar PIN',
                  onTap: _createPin,
                ),
              ],
            ]),
          ),
        ),
        const SliverToBoxAdapter(child: SectionLabel('Privacidad')),
        SliverToBoxAdapter(
          child: OneGroup(children: [
            OneTile(
              leading: const IconBadge(Icons.visibility_off_rounded, Color(0xFF8E8E93)),
              title: 'Vista privada',
              subtitle: 'Ocultar la imagen de la cámara; solo siluetas.',
              trailing: Switch(
                value: _s.privateView,
                onChanged: (v) => _set(_s.copyWith(privateView: v)),
              ),
            ),
            OneTile(
              leading: const IconBadge(Icons.picture_as_pdf_rounded, AppColors.danger),
              title: 'Aviso para el vehículo',
              subtitle: 'Cartel PDF para imprimir y pegar a la vista.',
              onTap: () => ExportService.shareVehicleNotice(
                  photos: _s.evidenceEnabled),
            ),
            OneTile(
              leading: const IconBadge(Icons.policy_rounded, AppColors.passenger),
              title: 'Qué datos guarda la app',
              onTap: () => showPrivacyNotice(context, requireAccept: false),
            ),
          ]),
        ),
        const SliverToBoxAdapter(child: SectionLabel('Modelo de detección')),
        SliverToBoxAdapter(
          child: OneGroup(children: [
            for (final m in ModelVariant.values)
              OneTile(
                leading: Icon(
                  _s.model == m
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_off_rounded,
                  color: _s.model == m ? AppColors.accent : null,
                ),
                title: m.label,
                subtitle: _assets.isNotEmpty && !_assets.contains(m.assetPath)
                    ? '${m.detail} · no incluido en esta versión'
                    : m.detail,
                onTap: () => _set(_s.copyWith(model: m)),
              ),
            OneTile(
              leading: const IconBadge(Icons.speed_rounded, AppColors.passenger),
              title: 'Ritmo adaptativo',
              subtitle: 'Libre: 1 imagen cada 2 s. En carrera: 2 por segundo. '
                  'Más despacio si el teléfono se calienta.',
              trailing: Switch(
                value: _s.adaptiveRate,
                onChanged: (v) => _set(_s.copyWith(adaptiveRate: v)),
              ),
            ),
            _SliderTile(
              title: 'Confianza mínima',
              help: 'Por debajo de este valor no se crean personas nuevas (las '
                  'detecciones débiles solo siguen a alguien ya visto).',
              value: _s.confidence,
              min: 0.1,
              max: 0.9,
              divisions: 16,
              label: (v) => v.toStringAsFixed(2),
              onChanged: (v) => _set(_s.copyWith(confidence: v)),
            ),
            _SliderTile(
              title: 'IoU de NMS',
              help: 'Solapamiento a partir del cual dos cajas son la misma '
                  'persona.',
              value: _s.iou,
              min: 0.2,
              max: 0.8,
              divisions: 12,
              label: (v) => v.toStringAsFixed(2),
              onChanged: (v) => _set(_s.copyWith(iou: v)),
            ),
            OneTile(
              title: 'Usar GPU',
              subtitle: 'Más rápido en muchos teléfonos; si falla se usa la CPU.',
              trailing: Switch(
                value: _s.useGpu,
                onChanged: (v) => _set(_s.copyWith(useGpu: v)),
              ),
            ),
          ]),
        ),
        const SliverToBoxAdapter(child: SectionLabel('Fuentes')),
        SliverToBoxAdapter(
          child: OneGroup(children: [
            OneTile(
              title: 'Cámara frontal',
              subtitle: 'Si el teléfono va con la pantalla hacia la cabina.',
              trailing: Switch(
                value: _s.useFrontCamera,
                onChanged: (v) => _set(_s.copyWith(useFrontCamera: v)),
              ),
            ),
            _SliderTile(
              title: 'Paso de simulación',
              help: 'Cada cuánto tiempo de vídeo se analiza un fotograma.',
              value: _s.simulationStepMs.toDouble(),
              min: 100,
              max: 1000,
              divisions: 9,
              label: (v) => '${v.round()} ms',
              onChanged: (v) => _set(_s.copyWith(simulationStepMs: v.round())),
            ),
          ]),
        ),
      ],
    );
  }
}

class _SliderTile extends StatelessWidget {
  final String title, help;
  final double value, min, max;
  final int divisions;
  final String Function(double) label;
  final ValueChanged<double> onChanged;

  const _SliderTile({
    required this.title,
    required this.help,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.label,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final s = Surfaces.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(title,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w500)),
              ),
              Text(label(value),
                  style: const TextStyle(
                      color: AppColors.accent, fontWeight: FontWeight.w700)),
            ],
          ),
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
          Text(help, style: TextStyle(fontSize: 13, color: s.textSecondary)),
        ],
      ),
    );
  }
}

/// Fila con opciones en botones segmentados.
class _ChoiceTile<T> extends StatelessWidget {
  final String title;
  final T value;
  final Map<T, String> options;
  final ValueChanged<T> onChanged;

  const _ChoiceTile({
    required this.title,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
        child: Row(
          children: [
            Expanded(
              child: Text(title,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w500)),
            ),
            SegmentedButton<T>(
              showSelectedIcon: false,
              style: const ButtonStyle(
                  visualDensity: VisualDensity.compact),
              segments: [
                for (final e in options.entries)
                  ButtonSegment(value: e.key, label: Text(e.value)),
              ],
              selected: {value},
              onSelectionChanged: (v) => onChanged(v.first),
            ),
          ],
        ),
      );
}
