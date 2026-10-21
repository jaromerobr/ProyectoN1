import 'package:flutter/material.dart';

import '../models/app_settings.dart';
import '../models/seat.dart';
import '../models/trip_record.dart';
import '../services/database_helper.dart';
import '../services/evidence_store.dart';
import '../services/owner_mode.dart';
import '../ui/car_seat_map.dart';
import '../ui/charts.dart';
import '../ui/one_ui.dart';
import '../ui/theme.dart';
import '../utils/format.dart';
import '../utils/trip_stats.dart';
import '../widgets/privacy_notice.dart';
import '../widgets/shift_card.dart';
import '../widgets/trip_tile.dart';
import 'camera_detector_screen.dart';
import 'settings_screen.dart';
import 'trip_detail_screen.dart';
import 'trip_history_screen.dart';
import 'video_simulation_screen.dart';

typedef TripLoader = Future<List<TripRecord>> Function();

Future<List<TripRecord>> loadAllTrips() => DatabaseHelper.instance.trips();

/// Bitácora: incluye las carreras borradas si el propietario entró con PIN.
Future<List<TripRecord>> loadHistoryTrips() =>
    DatabaseHelper.instance.trips(includeDeleted: OwnerMode.unlocked.value);

Future<Shift?> loadActiveShift() => DatabaseHelper.instance.activeShift();

class HomeScreen extends StatefulWidget {
  /// Fuente de datos (se sustituye en las vistas previas).
  final TripLoader loader;
  final Future<Shift?> Function() shiftLoader;
  final DateTime Function() now;
  final bool askPrivacy;

  const HomeScreen({
    super.key,
    this.loader = loadAllTrips,
    this.shiftLoader = loadActiveShift,
    this.now = DateTime.now,
    this.askPrivacy = true,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<TripRecord>? _all;
  Shift? _shift;

  @override
  void initState() {
    super.initState();
    _refresh();
    if (widget.askPrivacy) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final s = await AppSettings.load();
        // Borra las fotos de evidencia vencidas.
        EvidenceStore.cleanup(s.evidenceRetentionDays).catchError((_) {});
        if (!s.privacyAccepted && mounted) {
          await showPrivacyNotice(context, requireAccept: true);
        }
      });
    }
  }

  Future<void> _refresh() async {
    final all = await widget.loader();
    Shift? shift;
    try {
      shift = await widget.shiftLoader();
    } catch (_) {}
    if (mounted) {
      setState(() {
        _all = all;
        _shift = shift;
      });
    }
  }

  TripLoader get _historyLoader =>
      widget.loader == loadAllTrips ? loadHistoryTrips : widget.loader;

  Future<void> _open(Widget Function(AppSettings s) builder) async {
    final settings = await AppSettings.load();
    if (!mounted) return;
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => builder(settings)));
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final now = widget.now();
    // En vivo y simulación juntas (las simuladas llevan la etiqueta SIM).
    final all = _all ?? const <TripRecord>[];
    final today = inRange(all, StatsRange.today, now);
    final midnight = DateTime(now.year, now.month, now.day);
    final yesterday =
        between(all, midnight.subtract(const Duration(days: 1)), midnight);
    final week = inRange(all, StatsRange.week, now);
    final prevWeek = between(all, midnight.subtract(const Duration(days: 13)),
        midnight.subtract(const Duration(days: 6)));

    final subtitle = today.isEmpty
        ? 'Sin carreras hoy'
        : '${today.length} ${today.length == 1 ? 'carrera' : 'carreras'} hoy · '
            '${humanDuration(totalDuration(today))} en carrera';

    return OneUiPage(
      title: 'Taxiff',
      subtitle: subtitle,
      showBack: false,
      actions: [
        IconButton(
          tooltip: 'Bitácora',
          icon: const Icon(Icons.bar_chart_rounded),
          onPressed: () => _open((_) => TripHistoryScreen(loader: _historyLoader)),
        ),
        IconButton(
          tooltip: 'Ajustes',
          icon: const Icon(Icons.settings_outlined),
          onPressed: () => _open((s) => SettingsScreen(initial: s)),
        ),
      ],
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
            child: Row(
              children: [
                Expanded(
                  child: _ModeCard(
                    icon: Icons.videocam_rounded,
                    color: AppColors.accent,
                    title: 'En vivo',
                    subtitle: 'Cámara del vehículo',
                    onTap: () =>
                        _open((s) => CameraDetectorScreen(settings: s)),
                  ),
                ),
                Expanded(
                  child: _ModeCard(
                    icon: Icons.movie_filter_rounded,
                    color: AppColors.info,
                    title: 'Simulación',
                    subtitle: 'Probar con un vídeo',
                    onTap: () =>
                        _open((s) => VideoSimulationScreen(settings: s)),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SectionLabel('Turno')),
        SliverToBoxAdapter(
          child: ShiftCard(
            shift: _shift,
            allTrips: all,
            onStart: (driver) async {
              await DatabaseHelper.instance.startShift(driver, DateTime.now());
              _refresh();
            },
            onEnd: () async {
              await DatabaseHelper.instance
                  .endShift(_shift!.id!, DateTime.now());
              _refresh();
            },
          ),
        ),
        const SliverToBoxAdapter(child: SectionLabel('Hoy')),
        SliverToBoxAdapter(
          child: OneCard(
            child: _KpiGrid(children: [
              Kpi(
                icon: Icons.local_taxi_rounded,
                color: AppColors.accent,
                label: 'Carreras',
                value: '${today.length}',
                delta: _vsYesterday(today.length, yesterday.length),
                deltaGood: today.length >= yesterday.length,
              ),
              Kpi(
                icon: Icons.timer_outlined,
                color: AppColors.info,
                label: 'En carrera',
                value: humanDuration(totalDuration(today)),
              ),
              Kpi(
                icon: Icons.groups_rounded,
                color: AppColors.passenger,
                label: 'Pasajeros',
                value: '${totalPassengers(today)}',
              ),
              Kpi(
                icon: Icons.av_timer_rounded,
                color: AppColors.purple,
                label: 'Duración media',
                value: humanDuration(averageDuration(today)),
              ),
            ]),
          ),
        ),
        SliverToBoxAdapter(
          child: OneCard(
            child: Column(
              children: [
                CardHeader(
                  'Últimos 7 días',
                  trailing: percentDelta(week.length, prevWeek.length) == null
                      ? '${week.length} carreras'
                      : '${percentDelta(week.length, prevWeek.length)} vs semana anterior',
                  trailingColor: week.length >= prevWeek.length
                      ? AppColors.passenger
                      : AppColors.danger,
                ),
                () {
                  final days = tripsPerDay(all, 7, now);
                  return BarChart(
                    values: [for (final d in days) d.$2.toDouble()],
                    labels: [for (final d in days) weekdayInitial(d.$1)],
                    highlight: 6,
                    tooltip: (i, v) =>
                        '${dayLabel(days[i].$1, now)}: ${v.toInt()}',
                  );
                }(),
              ],
            ),
          ),
        ),
        SliverToBoxAdapter(child: _SeatsCard(trips: week)),
        SliverToBoxAdapter(
          child: SectionLabel(
            'Recientes',
            trailing: TextButton(
              onPressed: () =>
                  _open((_) => TripHistoryScreen(loader: _historyLoader)),
              child: const Text('Ver todo'),
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: all.isEmpty
              ? const OneCard(
                  child: EmptyState(
                    icon: Icons.receipt_long_rounded,
                    title: 'Aún no hay carreras',
                    message: 'Empieza en el modo en vivo o prueba con un '
                        'vídeo en el modo simulación.',
                  ),
                )
              : OneGroup(children: [
                  for (final t in all.take(4))
                    TripTile(
                      trip: t,
                      onTap: () => _open((_) => TripDetailScreen(trip: t)),
                    ),
                ]),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.lock_outline,
                    size: 14, color: Surfaces.of(context).textSecondary),
                const SizedBox(width: 6),
                Text('Todo se procesa en el teléfono, sin internet',
                    style: TextStyle(
                        fontSize: 12,
                        color: Surfaces.of(context).textSecondary)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  String? _vsYesterday(int now, int before) {
    final p = percentDelta(now, before);
    return p == null ? null : '$p vs ayer';
  }
}

class _ModeCard extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title, subtitle;
  final VoidCallback onTap;
  const _ModeCard({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => OneCard(
        margin: const EdgeInsets.symmetric(horizontal: 4),
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            IconBadge(icon, color, size: 48),
            const SizedBox(height: 18),
            Text(title,
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(subtitle,
                style: TextStyle(
                    fontSize: 13, color: Surfaces.of(context).textSecondary)),
          ],
        ),
      );
}

/// Cuadrícula 2×N de indicadores con separadores.
class _KpiGrid extends StatelessWidget {
  final List<Widget> children;
  const _KpiGrid({required this.children});

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i += 2) {
      if (i > 0) rows.add(const SizedBox(height: 18));
      rows.add(Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: children[i]),
          const SizedBox(width: 16),
          Expanded(
              child: i + 1 < children.length
                  ? children[i + 1]
                  : const SizedBox()),
        ],
      ));
    }
    return Column(children: rows);
  }
}

/// Mapa de calor de asientos (tiempo de uso) con ranking.
class _SeatsCard extends StatelessWidget {
  final List<TripRecord> trips;
  const _SeatsCard({required this.trips});

  @override
  Widget build(BuildContext context) {
    final time = seatTime(trips);
    final pax = SeatId.values.where((s) => s != SeatId.driver).toList();
    final total = pax.fold(Duration.zero, (a, s) => a + time[s]!);
    final maxT = pax.fold(Duration.zero, (a, s) => time[s]! > a ? time[s]! : a);
    double share(SeatId s) =>
        total == Duration.zero ? 0 : time[s]!.inSeconds / total.inSeconds;

    return OneCard(
      child: Column(
        children: [
          const CardHeader('Asientos más usados', trailing: '7 días'),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CarSeatMap(
                height: 230,
                seats: {
                  for (final s in pax)
                    s: SeatVisual(
                      color: time[s]! > Duration.zero ? seatColor(s) : null,
                      intensity: maxT == Duration.zero
                          ? 0
                          : time[s]!.inSeconds / maxT.inSeconds,
                      caption: total == Duration.zero
                          ? null
                          : '${(share(s) * 100).round()}%',
                    ),
                  SeatId.driver: const SeatVisual(),
                },
              ),
              const SizedBox(width: 20),
              Expanded(
                child: total == Duration.zero
                    ? Padding(
                        padding: const EdgeInsets.only(top: 40),
                        child: Text(
                          'Aquí verás qué asientos usan más los pasajeros.',
                          style: TextStyle(
                              color: Surfaces.of(context).textSecondary),
                        ),
                      )
                    : Column(
                        children: [
                          for (final s in [...pax]
                            ..sort((a, b) => time[b]!.compareTo(time[a]!)))
                            LabeledBar(
                              label: s.label,
                              value: humanDuration(time[s]!),
                              fraction: share(s),
                              color: seatColor(s),
                            ),
                        ],
                      ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
