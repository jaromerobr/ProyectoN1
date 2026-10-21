import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/seat.dart';
import '../models/trip_record.dart';
import '../services/database_helper.dart';
import '../services/owner_mode.dart';
import '../ui/car_seat_map.dart';
import '../ui/charts.dart';
import '../ui/one_ui.dart';
import '../ui/theme.dart';
import '../utils/format.dart';
import 'evidence_viewer_screen.dart';

/// Detalle de una carrera. Devuelve true al cerrar si se borró.
class TripDetailScreen extends StatelessWidget {
  final TripRecord trip;
  const TripDetailScreen({super.key, required this.trip});

  Future<void> _restore(BuildContext context) async {
    await DatabaseHelper.instance.restoreTrip(trip.id!);
    if (context.mounted) Navigator.pop(context, true);
  }

  Future<void> _purge(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('¿Borrar definitivamente?'),
        content: const Text(
            'Se eliminan la carrera y sus fotos. No se puede deshacer.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Borrar definitivamente',
                  style: TextStyle(color: AppColors.danger))),
        ],
      ),
    );
    if (ok == true) {
      await DatabaseHelper.instance.purgeTrip(trip.id!);
      if (context.mounted) Navigator.pop(context, true);
    }
  }

  Future<void> _delete(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('¿Borrar esta carrera?'),
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
    if (ok == true && trip.id != null) {
      await DatabaseHelper.instance.deleteTrip(trip.id!);
      if (context.mounted) Navigator.pop(context, true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = trip;
    final s = Surfaces.of(context);
    final paxCount = t.passengers.isNotEmpty ? t.passengers.length : t.maxPassengers;

    // Asiento → pasajeros que lo usaron (para colorear el mapa).
    final users = <SeatId, List<int>>{};
    for (final p in t.passengers) {
      for (final seat in p.seatPath) {
        users.putIfAbsent(seat, () => []).add(p.number);
      }
    }

    return OneUiPage(
      title: humanDuration(t.duration),
      subtitle: '${dayLabel(t.start, DateTime.now())} · '
          '${formatHm(t.start)} – ${formatHm(t.end)}',
      actions: [
        if (t.deleted && OwnerMode.unlocked.value) ...[
          IconButton(
            tooltip: 'Restaurar',
            icon: const Icon(Icons.restore_rounded),
            onPressed: () => _restore(context),
          ),
          IconButton(
            tooltip: 'Borrar definitivamente',
            icon: const Icon(Icons.delete_forever_rounded,
                color: AppColors.danger),
            onPressed: () => _purge(context),
          ),
        ] else
          IconButton(
            tooltip: 'Borrar',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _delete(context),
          ),
      ],
      slivers: [
        if (t.deleted)
          SliverToBoxAdapter(
            child: OneCard(
              color: AppColors.danger.withValues(alpha: 0.15),
              child: Row(
                children: [
                  const Icon(Icons.visibility_off_rounded,
                      color: AppColors.danger),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                        'Borrada por el conductor el '
                        '${formatDate(t.deletedAt!)} a las '
                        '${formatHm(t.deletedAt!)}. Solo la ve el propietario.',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
            ),
          ),
        SliverToBoxAdapter(
          child: OneCard(
            child: Row(children: [
              Expanded(
                  child: Kpi(
                      icon: Icons.groups_rounded,
                      color: AppColors.passenger,
                      label: 'Pasajeros',
                      value: '$paxCount')),
              Expanded(
                  child: Kpi(
                      icon: Icons.people_alt_outlined,
                      color: AppColors.accent,
                      label: 'Máx. a la vez',
                      value: '${t.maxPassengers}')),
              Expanded(
                  child: Kpi(
                      icon: Icons.swap_horiz_rounded,
                      color: AppColors.info,
                      label: 'Cambios',
                      value: '${t.seatChanges}')),
            ]),
          ),
        ),
        if (t.evidenceDir != null)
          SliverToBoxAdapter(child: EvidenceCard(dir: t.evidenceDir)),
        if (t.origin != null || t.driver != null)
          SliverToBoxAdapter(child: _RouteCard(t)),
        SliverToBoxAdapter(
          child: OneCard(
            child: Column(
              children: [
                CardHeader('Asientos',
                    trailing: t.source == TripSource.simulation
                        ? 'Simulación'
                        : 'En vivo'),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CarSeatMap(
                      height: 240,
                      seats: {
                        for (final seat in SeatId.values)
                          if (seat != SeatId.driver)
                            seat: SeatVisual(
                              color:
                                  users[seat] == null ? null : seatColor(seat),
                              intensity: 0.85,
                              caption: users[seat]
                                  ?.map((n) => 'P$n')
                                  .join(' '),
                            ),
                        SeatId.driver: const SeatVisual(),
                      },
                    ),
                    const SizedBox(width: 20),
                    Expanded(
                      child: t.passengers.isEmpty
                          ? Text('Sin detalle por pasajero.',
                              style: TextStyle(color: s.textSecondary))
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                for (final p in t.passengers)
                                  _PassengerRow(p),
                              ],
                            ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        if (t.passengers.isNotEmpty)
          SliverToBoxAdapter(
            child: OneCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const CardHeader('Línea de tiempo'),
                  TripTimeline(trip: t),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 12,
                    runSpacing: 6,
                    children: [
                      for (final seat in t.seats)
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 10,
                              height: 10,
                              decoration: BoxDecoration(
                                  color: seatColor(seat),
                                  borderRadius: BorderRadius.circular(3)),
                            ),
                            const SizedBox(width: 6),
                            Text(seat.label,
                                style: TextStyle(
                                    fontSize: 12, color: s.textSecondary)),
                          ],
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        const SliverToBoxAdapter(child: SectionLabel('Eventos')),
        SliverToBoxAdapter(
          child: OneGroup(children: [
            for (final e in _events(t)) e,
          ]),
        ),
      ],
    );
  }

  List<Widget> _events(TripRecord t) {
    final items = <(DateTime, Widget)>[];
    Widget tile(IconData icon, Color c, String title, String sub, DateTime at) =>
        OneTile(
          leading: IconBadge(icon, c, size: 36),
          title: title,
          subtitle: sub,
          trailing: Text(formatTime(at),
              style: const TextStyle(
                  fontFeatures: [FontFeature.tabularFigures()])),
        );

    items.add((
      t.start,
      tile(Icons.play_arrow_rounded, AppColors.accent, 'Inicio de carrera',
          'Primer pasajero detectado', t.start)
    ));
    for (final p in t.passengers) {
      final first = p.segments.isEmpty ? null : p.segments.first.seat;
      items.add((
        p.enter,
        tile(Icons.login_rounded, AppColors.forIndex(p.number - 1),
            'Subió el pasajero ${p.number}', first?.label ?? 'Sin asiento', p.enter)
      ));
      for (var i = 1; i < p.segments.length; i++) {
        final a = p.segments[i - 1].seat, b = p.segments[i].seat;
        if (a == b) continue;
        items.add((
          p.segments[i].from,
          tile(Icons.swap_horiz_rounded, AppColors.info,
              'Pasajero ${p.number} cambió de asiento',
              'De ${a?.label ?? '—'} a ${b?.label ?? '—'}', p.segments[i].from)
        ));
      }
      items.add((
        p.exit,
        tile(Icons.logout_rounded, const Color(0xFF8E8E93),
            'Bajó el pasajero ${p.number}',
            'Viajó ${humanDuration(p.duration)}', p.exit)
      ));
    }
    items.add((
      t.end,
      tile(Icons.flag_rounded, AppColors.passenger, 'Fin de carrera',
          'Duración ${formatDuration(t.duration)}', t.end)
    ));
    items.sort((a, b) => a.$1.compareTo(b.$1));
    return [for (final i in items) i.$2];
  }
}

class _PassengerRow extends StatelessWidget {
  final PassengerStint p;
  const _PassengerRow(this.p);

  @override
  Widget build(BuildContext context) {
    final s = Surfaces.of(context);
    final path = p.seatPath;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 12,
            backgroundColor: AppColors.forIndex(p.number - 1),
            child: Text('${p.number}',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w800)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  path.isEmpty
                      ? 'Sin asiento'
                      : path.map((x) => x.short).join('  ›  '),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                Text(
                    '${formatHm(p.enter)} – ${formatHm(p.exit)} · '
                    '${humanDuration(p.duration)}',
                    style: TextStyle(fontSize: 12, color: s.textSecondary)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Origen → destino, distancia y conductor, con enlace a Google Maps.
class _RouteCard extends StatelessWidget {
  final TripRecord t;
  const _RouteCard(this.t);

  Future<void> _openMaps() async {
    final o = t.origin!, d = t.destination ?? t.origin!;
    final url = Uri.parse('https://www.google.com/maps/dir/?api=1'
        '&origin=${o.lat},${o.lng}&destination=${d.lat},${d.lng}');
    await launchUrl(url, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final s = Surfaces.of(context);
    Widget stop(IconData icon, Color c, String title, String value) => Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: c),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(fontSize: 12, color: s.textSecondary)),
                  Text(value,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          ],
        );

    return OneCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CardHeader('Recorrido',
              trailing: t.distanceKm == null
                  ? null
                  : '${t.distanceKm!.toStringAsFixed(1)} km',
              trailingColor: AppColors.info),
          if (t.origin != null) ...[
            stop(Icons.trip_origin_rounded, AppColors.passenger, 'Origen · ${formatHm(t.start)}',
                t.origin!.label),
            Padding(
              padding: const EdgeInsets.only(left: 9),
              child: Container(width: 2, height: 18, color: s.divider),
            ),
            stop(Icons.location_on_rounded, AppColors.danger, 'Destino · ${formatHm(t.end)}',
                (t.destination ?? t.origin!).label),
          ],
          if (t.driver != null) ...[
            if (t.origin != null) const SizedBox(height: 14),
            stop(Icons.badge_outlined, AppColors.accent, 'Conductor', t.driver!),
          ],
          if (t.origin != null) ...[
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _openMaps,
                icon: const Icon(Icons.map_outlined),
                label: const Text('Ver en Google Maps'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
