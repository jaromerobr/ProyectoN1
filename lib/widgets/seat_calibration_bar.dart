import 'package:flutter/material.dart';

import '../models/seat.dart';
import '../services/detection_session.dart';

/// Barra para calibrar asientos: se elige un asiento y se toca la imagen.
class SeatCalibrationBar extends StatelessWidget {
  final DetectionSession session;
  final SeatId selected;
  final ValueChanged<SeatId> onSelect;
  final VoidCallback onDone;

  const SeatCalibrationBar({
    super.key,
    required this.session,
    required this.selected,
    required this.onSelect,
    required this.onDone,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final s = session.settings;
        final seat = s.seat(selected);
        return Container(
          margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.event_seat, size: 20),
                  const SizedBox(width: 8),
                  Text('Calibrar asientos', style: theme.textTheme.titleSmall),
                  const Spacer(),
                  FilledButton.tonal(onPressed: onDone, child: const Text('Listo')),
                ],
              ),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final p in s.seats)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ChoiceChip(
                          label: Text(p.id.label),
                          avatar: Icon(
                            p.enabled ? Icons.check_circle : Icons.block,
                            size: 16,
                          ),
                          selected: p.id == selected,
                          onSelected: (_) => onSelect(p.id),
                        ),
                      ),
                  ],
                ),
              ),
              if (selected != SeatId.driver)
                SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text('Usar «${selected.label}»'),
                  subtitle: const Text('Desactívalo si el vehículo no tiene '
                      'ese asiento o la cámara no lo ve.'),
                  value: seat.enabled,
                  onChanged: (v) => session
                      .updateSettings(s.withSeat(seat.copyWith(enabled: v))),
                ),
            ],
          ),
        );
      },
    );
  }
}
