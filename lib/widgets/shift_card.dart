import 'package:flutter/material.dart';

import '../models/app_settings.dart';
import '../models/trip_record.dart';
import '../ui/one_ui.dart';
import '../ui/theme.dart';
import '../utils/format.dart';
import '../utils/trip_stats.dart';

/// Turno del conductor: quién maneja ahora y su resumen. Las carreras se
/// guardan con el conductor del turno activo.
class ShiftCard extends StatelessWidget {
  final Shift? shift;
  final List<TripRecord> allTrips;
  final Future<void> Function(String driver) onStart;
  final Future<void> Function() onEnd;

  const ShiftCard({
    super.key,
    required this.shift,
    required this.allTrips,
    required this.onStart,
    required this.onEnd,
  });

  @override
  Widget build(BuildContext context) {
    final s = Surfaces.of(context);
    final sh = shift;
    if (sh == null) {
      return OneCard(
        child: Row(
          children: [
            const IconBadge(Icons.badge_outlined, Color(0xFF8E8E93), size: 44),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Sin turno activo',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  Text('Inicia un turno para saber quién hizo cada carrera.',
                      style: TextStyle(fontSize: 13, color: s.textSecondary)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: () => _pickDriver(context),
              child: const Text('Iniciar'),
            ),
          ],
        ),
      );
    }

    final trips = allTrips.where((t) => t.shiftId == sh.id).toList();
    final km = trips.fold(0.0, (a, t) => a + (t.distanceKm ?? 0));
    return OneCard(
      child: Column(
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: AppColors.accent,
                child: Text(_initials(sh.driver),
                    style: const TextStyle(
                        color: Colors.black, fontWeight: FontWeight.w800)),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(sh.driver,
                        style: const TextStyle(
                            fontSize: 17, fontWeight: FontWeight.w700)),
                    Text(
                        'Turno desde ${formatHm(sh.start)} · '
                        '${humanDuration(DateTime.now().difference(sh.start))}',
                        style:
                            TextStyle(fontSize: 13, color: s.textSecondary)),
                  ],
                ),
              ),
              OutlinedButton(
                onPressed: () => _confirmEnd(context, trips, km),
                child: const Text('Terminar'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                  child: Kpi(label: 'Carreras', value: '${trips.length}')),
              Expanded(
                  child: Kpi(
                      label: 'En carrera',
                      value: humanDuration(totalDuration(trips)))),
              Expanded(
                  child: Kpi(
                      label: 'Distancia',
                      value: '${km.toStringAsFixed(1)} km')),
            ],
          ),
        ],
      ),
    );
  }

  static String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    return parts.take(2).map((p) => p.isEmpty ? '' : p[0].toUpperCase()).join();
  }

  Future<void> _pickDriver(BuildContext context) async {
    final settings = await AppSettings.load();
    if (!context.mounted) return;
    final name = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => _DriverPicker(drivers: settings.drivers),
    );
    if (name == null || name.trim().isEmpty) return;
    final clean = name.trim();
    if (!settings.drivers.contains(clean)) {
      await settings.copyWith(drivers: [...settings.drivers, clean]).save();
    }
    await onStart(clean);
  }

  Future<void> _confirmEnd(
      BuildContext context, List<TripRecord> trips, double km) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('¿Terminar el turno de ${shift!.driver}?'),
        content: Text(
            '${trips.length} carreras · ${humanDuration(totalDuration(trips))} '
            'en carrera · ${km.toStringAsFixed(1)} km'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Terminar')),
        ],
      ),
    );
    if (ok == true) await onEnd();
  }
}

class _DriverPicker extends StatefulWidget {
  final List<String> drivers;
  const _DriverPicker({required this.drivers});

  @override
  State<_DriverPicker> createState() => _DriverPickerState();
}

class _DriverPickerState extends State<_DriverPicker> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = Surfaces.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
          20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('¿Quién conduce?',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          for (final d in widget.drivers)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: CircleAvatar(
                backgroundColor: AppColors.accent.withValues(alpha: 0.2),
                child: Text(ShiftCard._initials(d),
                    style: const TextStyle(
                        color: AppColors.accent, fontWeight: FontWeight.w800)),
              ),
              title: Text(d),
              trailing: Icon(Icons.chevron_right, color: s.textSecondary),
              onTap: () => Navigator.pop(context, d),
            ),
          const SizedBox(height: 8),
          TextField(
            controller: _ctrl,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(
              hintText: widget.drivers.isEmpty
                  ? 'Nombre del conductor'
                  : 'Otro conductor…',
              filled: true,
              fillColor: s.cardHigh,
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide.none),
            ),
            onSubmitted: (v) => Navigator.pop(context, v),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: () => Navigator.pop(context, _ctrl.text),
            child: const Text('Iniciar turno'),
          ),
        ],
      ),
    );
  }
}
