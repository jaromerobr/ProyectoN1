import 'package:flutter/material.dart';

import '../services/detection_session.dart';
import '../ui/car_seat_map.dart';
import '../ui/one_ui.dart';
import '../ui/theme.dart';
import '../utils/format.dart';
import '../utils/trip_tracker.dart';

/// Panel inferior del modo en vivo / simulación.
class TripStatusPanel extends StatelessWidget {
  final DetectionSession session;
  const TripStatusPanel({super.key, required this.session});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final s = Surfaces.of(context);
        final t = session.tracker;
        final now = session.clock;
        final empty = t.emptyFor(now);
        final grace = session.settings.exitGraceSeconds;

        final (String status, Color color, IconData icon) = switch (t.state) {
          TripState.idle =>
            ('Libre', const Color(0xFF8E8E93), Icons.local_taxi_outlined),
          TripState.confirming =>
            ('Confirmando', AppColors.accent, Icons.hourglass_top_rounded),
          TripState.inTrip =>
            ('En carrera', AppColors.passenger, Icons.local_taxi_rounded),
        };
        final detail = switch (t.state) {
          TripState.idle => 'Esperando pasajeros',
          TripState.confirming => 'Pasajero detectado…',
          TripState.inTrip => empty != null
              ? 'Sin pasajeros · cierra en '
                  '${(grace - empty.inMilliseconds / 1000).clamp(0, 99).toStringAsFixed(0)} s'
              : 'Desde ${formatHm(t.tripStart!)} · máx. ${t.maxPassengers}',
        };
        final occupied = session.occupiedSeats;

        return Container(
          margin: const EdgeInsets.fromLTRB(10, 8, 10, 10),
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
          decoration: BoxDecoration(
            color: s.card,
            borderRadius: BorderRadius.circular(28),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Pill(status.toUpperCase(), color, icon: icon),
                        const SizedBox(height: 8),
                        Text(
                          formatDuration(
                              t.inTrip ? t.elapsed(now) : Duration.zero),
                          style: TextStyle(
                            fontSize: 44,
                            height: 1.05,
                            fontWeight: FontWeight.w300,
                            fontFeatures: const [FontFeature.tabularFigures()],
                            color: t.inTrip ? null : s.textSecondary,
                          ),
                        ),
                        Text(detail,
                            style: TextStyle(
                                color: s.textSecondary, fontSize: 13.5)),
                        if (empty != null) ...[
                          const SizedBox(height: 8),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: (empty.inMilliseconds / 1000 / grace)
                                  .clamp(0, 1),
                              minHeight: 5,
                              color: AppColors.accent,
                              backgroundColor: s.cardHigh,
                            ),
                          ),
                        ],
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            _Count(
                              value: '${session.passengers}',
                              label: 'Pasajeros',
                              color: AppColors.passenger,
                            ),
                            const SizedBox(width: 18),
                            _Count(
                              value: session.drivers > 0 ? 'Sí' : 'No',
                              label: 'Conductor',
                              color: session.drivers > 0
                                  ? AppColors.driver
                                  : s.textSecondary,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  CarSeatMap(
                    height: 168,
                    seats: {
                      for (final p in session.settings.seats)
                        p.id: SeatVisual(
                          disabled: !p.enabled,
                          color: occupied[p.id] == null
                              ? null
                              : seatColor(p.id),
                          intensity: 0.85,
                          caption: occupied[p.id] == null
                              ? null
                              : '#${occupied[p.id]!.trackId}',
                        ),
                    },
                  ),
                ],
              ),
              if (session.events.isNotEmpty) ...[
                const SizedBox(height: 10),
                Divider(color: s.divider),
                const SizedBox(height: 4),
                for (final e in session.events.take(2)) _EventLine(e),
              ],
              if (session.hot) ...[
                const SizedBox(height: 8),
                Pill(
                  'Teléfono caliente (${session.batteryTemp.toStringAsFixed(0)} °C) · '
                  'analizando más despacio',
                  AppColors.danger,
                  icon: Icons.thermostat_rounded,
                ),
              ],
              const SizedBox(height: 6),
              Text(
                session.backend.isEmpty
                    ? 'Cargando modelo…'
                    : [
                        session.modelName,
                        session.backend,
                        '${session.inferMs.toStringAsFixed(0)} ms',
                        '${session.fps.toStringAsFixed(1)} fps',
                        if (session.frameInterval > Duration.zero &&
                            t.state == TripState.idle)
                          'modo ahorro',
                        if (session.evidenceShots > 0 && t.inTrip)
                          '${session.evidenceShots} fotos',
                      ].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: s.textSecondary),
              ),
              if (session.error != null)
                Text(session.error!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: AppColors.danger)),
            ],
          ),
        );
      },
    );
  }
}

class _Count extends StatelessWidget {
  final String value, label;
  final Color color;
  const _Count({required this.value, required this.label, required this.color});

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value,
              style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                  color: color,
                  height: 1.1)),
          Text(label,
              style: TextStyle(
                  fontSize: 12, color: Surfaces.of(context).textSecondary)),
        ],
      );
}

/// Una línea del registro en vivo.
class _EventLine extends StatelessWidget {
  final SessionEvent e;
  const _EventLine(this.e);

  @override
  Widget build(BuildContext context) {
    final s = Surfaces.of(context);
    final id = e.trackId == null ? '' : '#${e.trackId}';
    final (IconData icon, Color c, String text) = switch (e.kind) {
      SessionEventKind.tripStart =>
        (Icons.play_arrow_rounded, AppColors.accent, 'Inicio de carrera'),
      SessionEventKind.entered => (
          Icons.login_rounded,
          AppColors.passenger,
          'Subió $id${e.to == null ? '' : ' · ${e.to!.label}'}'
        ),
      SessionEventKind.seatChange => (
          Icons.swap_horiz_rounded,
          AppColors.info,
          '$id cambió de ${e.from?.short ?? '—'} a ${e.to?.short ?? '—'}'
        ),
      SessionEventKind.exited =>
        (Icons.logout_rounded, const Color(0xFF8E8E93), 'Bajó $id'),
      SessionEventKind.resumed => (
          Icons.replay_rounded,
          AppColors.accent,
          'Continúa la carrera (se volvió a ver al pasajero)'
        ),
      SessionEventKind.discarded => (
          Icons.block_rounded,
          const Color(0xFF8E8E93),
          'Descartada: duró solo ${humanDuration(e.duration ?? Duration.zero)}'
        ),
      SessionEventKind.tripEnd => (
          Icons.check_circle_rounded,
          AppColors.passenger,
          'Carrera guardada · ${formatDuration(e.duration ?? Duration.zero)}'
        ),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(icon, size: 18, color: c),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13.5)),
          ),
          Text(formatTime(e.time),
              style: TextStyle(
                  fontSize: 12,
                  color: s.textSecondary,
                  fontFeatures: const [FontFeature.tabularFigures()])),
        ],
      ),
    );
  }
}
