import 'package:flutter/material.dart';

import '../models/seat.dart';
import '../models/trip_record.dart';
import '../ui/car_seat_map.dart';
import '../ui/one_ui.dart';
import '../ui/theme.dart';
import '../utils/format.dart';

/// Fila de carrera para listas: duración, horario, asientos y pasajeros.
class TripTile extends StatelessWidget {
  final TripRecord trip;
  final VoidCallback? onTap;
  const TripTile({super.key, required this.trip, this.onTap});

  @override
  Widget build(BuildContext context) {
    final s = Surfaces.of(context);
    final seats = trip.seats.where((x) => x != SeatId.driver).toList();
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: AppColors.accent.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.person, size: 18, color: AppColors.accent),
                  Text('${trip.maxPassengers}',
                      style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          color: AppColors.accent,
                          height: 1)),
                ],
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(humanDuration(trip.duration),
                          style: const TextStyle(
                              fontSize: 17, fontWeight: FontWeight.w700)),
                      if (trip.source == TripSource.simulation) ...[
                        const SizedBox(width: 8),
                        const Pill('SIM', AppColors.info),
                      ],
                      if (trip.deleted) ...[
                        const SizedBox(width: 8),
                        const Pill('BORRADA', AppColors.danger),
                      ],
                      if (trip.evidenceDir != null) ...[
                        const SizedBox(width: 6),
                        const Icon(Icons.photo_library_outlined,
                            size: 16, color: AppColors.purple),
                      ],
                      if (trip.seatChanges > 0) ...[
                        const SizedBox(width: 6),
                        const Icon(Icons.swap_horiz,
                            size: 18, color: AppColors.info),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                      [
                        '${formatHm(trip.start)} – ${formatHm(trip.end)}',
                        if (trip.distanceKm != null)
                          '${trip.distanceKm!.toStringAsFixed(1)} km',
                        ?trip.driver,
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: s.textSecondary, fontSize: 13.5)),
                ],
              ),
            ),
            // Asientos usados como puntos de color.
            Wrap(
              spacing: 4,
              children: [
                for (final seat in seats.take(4))
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                    decoration: BoxDecoration(
                      color: seatColor(seat).withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(seat.short,
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            color: seatColor(seat))),
                  ),
              ],
            ),
            const SizedBox(width: 4),
            Icon(Icons.chevron_right, color: s.textSecondary),
          ],
        ),
      ),
    );
  }
}
