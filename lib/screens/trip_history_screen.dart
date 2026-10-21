import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/seat.dart';
import '../models/trip_record.dart';
import '../services/database_helper.dart';
import '../services/export_service.dart';
import '../ui/car_seat_map.dart';
import '../ui/charts.dart';
import '../ui/one_ui.dart';
import '../ui/theme.dart';
import '../utils/format.dart';
import '../utils/trip_stats.dart';
import '../widgets/trip_tile.dart';
import '../services/owner_mode.dart';
import 'home_screen.dart' show TripLoader, loadHistoryTrips;
import 'trip_detail_screen.dart';

enum _Action { excel, pdf, csv, deleteAll }

class TripHistoryScreen extends StatefulWidget {
  final TripLoader loader;
  final DateTime Function() now;
  const TripHistoryScreen(
      {super.key, this.loader = loadHistoryTrips, this.now = DateTime.now});

  @override
  State<TripHistoryScreen> createState() => _TripHistoryScreenState();
}

class _TripHistoryScreenState extends State<TripHistoryScreen> {
  List<TripRecord> _all = [];
  bool _loading = true;
  bool _exporting = false;
  StatsRange _range = StatsRange.week;
  TripSource? _source;

  /// Filtro por conductor ('' = todos).
  String _driver = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final all = await widget.loader();
    if (mounted) {
      setState(() {
        _all = all;
        _loading = false;
      });
    }
  }

  /// Carreras del periodo y filtros, incluidas las borradas (solo llegan
  /// aquí en modo propietario).
  List<TripRecord> get _listed => inRange(
      _all
          .where((t) =>
              (_source == null || t.source == _source) &&
              (_driver.isEmpty || t.driver == _driver))
          .toList(),
      _range,
      widget.now());

  /// Carreras válidas para estadísticas y exportación (sin las borradas).
  List<TripRecord> get _trips => _listed.where((t) => !t.deleted).toList();

  int get _deletedCount => _listed.where((t) => t.deleted).length;

  List<String> get _drivers =>
      {for (final t in _all) ?t.driver}.toList()..sort();

  String get _scopeLabel =>
      '${_range.label} · ${switch (_source) {
        null => 'todas las fuentes',
        TripSource.live => 'en vivo',
        TripSource.simulation => 'simulación',
      }}${_driver.isEmpty ? '' : ' · $_driver'}';

  void _snack(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  Future<void> _onAction(_Action a) async {
    final trips = _trips;
    switch (a) {
      case _Action.excel:
      case _Action.pdf:
        setState(() => _exporting = true);
        try {
          if (a == _Action.excel) {
            await ExportService.shareExcel(trips);
          } else {
            await ExportService.sharePdfReport(trips, filterLabel: _scopeLabel);
          }
        } catch (e) {
          _snack('No se pudo exportar: $e');
        } finally {
          if (mounted) setState(() => _exporting = false);
        }
      case _Action.csv:
        final rows = [
          'id,fecha,inicio,fin,duracion_s,max_pasajeros,asientos,cambios_asiento,fuente',
          for (final t in trips)
            '${t.id},${formatDate(t.start)},${formatTime(t.start)},'
                '${formatTime(t.end)},${t.duration.inSeconds},'
                '${t.maxPassengers},${t.seats.map((s) => s.short).join(' ')},'
                '${t.seatChanges},${t.source.name}',
        ];
        await Clipboard.setData(ClipboardData(text: rows.join('\n')));
        _snack('${trips.length} carreras copiadas como CSV');
      case _Action.deleteAll:
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('¿Borrar carreras?'),
            content: Text('Se borrarán las ${trips.length} carreras de '
                '"$_scopeLabel". No se puede deshacer.'),
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
          for (final t in trips) {
            await DatabaseHelper.instance.deleteTrip(t.id!);
          }
          _load();
        }
    }
  }

  Future<void> _openTrip(TripRecord t) async {
    final deleted = await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => TripDetailScreen(trip: t)));
    if (deleted == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    final now = widget.now();
    final trips = _trips;
    final s = Surfaces.of(context);

    return OneUiPage(
      title: 'Bitácora',
      subtitle: _loading
          ? null
          : '${trips.length} ${trips.length == 1 ? 'carrera' : 'carreras'} · '
              '${humanDuration(totalDuration(trips))}'
              '${_deletedCount > 0 ? ' · $_deletedCount borradas' : ''}',
      actions: [
        if (_exporting)
          const Padding(
            padding: EdgeInsets.all(14),
            child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2)),
          ),
        // Valores en texto: Flutter no llama a onSelected con un valor null.
        PopupMenuButton<String>(
          tooltip: 'Fuente',
          icon: Icon(_source == null
              ? Icons.filter_list_rounded
              : Icons.filter_alt_rounded),
          initialValue: _source?.name ?? 'all',
          onSelected: (v) => setState(
              () => _source = TripSource.values.asNameMap()[v]),
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'all', child: Text('Todas las fuentes')),
            PopupMenuItem(value: 'live', child: Text('Solo en vivo')),
            PopupMenuItem(value: 'simulation', child: Text('Solo simulación')),
          ],
        ),
        if (_drivers.isNotEmpty)
          PopupMenuButton<String>(
            tooltip: 'Conductor',
            icon: Icon(_driver.isEmpty
                ? Icons.person_search_outlined
                : Icons.person_search_rounded),
            initialValue: _driver,
            onSelected: (v) => setState(() => _driver = v),
            itemBuilder: (_) => [
              const PopupMenuItem(value: '', child: Text('Todos los conductores')),
              for (final d in _drivers) PopupMenuItem(value: d, child: Text(d)),
            ],
          ),
        if (OwnerMode.unlocked.value)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 6),
            child: Tooltip(
              message: 'Modo propietario',
              child: Icon(Icons.admin_panel_settings_rounded,
                  color: AppColors.accent),
            ),
          ),
        PopupMenuButton<_Action>(
          enabled: trips.isNotEmpty && !_exporting,
          icon: const Icon(Icons.more_vert),
          onSelected: _onAction,
          itemBuilder: (_) => const [
            PopupMenuItem(
                value: _Action.excel,
                child: ListTile(
                    leading: Icon(Icons.table_chart_outlined),
                    title: Text('Exportar a Excel'))),
            PopupMenuItem(
                value: _Action.pdf,
                child: ListTile(
                    leading: Icon(Icons.picture_as_pdf_outlined),
                    title: Text('Reporte PDF'))),
            PopupMenuItem(
                value: _Action.csv,
                child: ListTile(
                    leading: Icon(Icons.copy_all_outlined),
                    title: Text('Copiar CSV'))),
            PopupMenuItem(
                value: _Action.deleteAll,
                child: ListTile(
                    leading: Icon(Icons.delete_outline),
                    title: Text('Borrar estas carreras'))),
          ],
        ),
      ],
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: SegmentedButton<StatsRange>(
              showSelectedIcon: false,
              segments: [
                for (final r in StatsRange.values)
                  ButtonSegment(value: r, label: Text(r.label)),
              ],
              selected: {_range},
              onSelectionChanged: (v) => setState(() => _range = v.first),
            ),
          ),
        ),
        if (_loading)
          const SliverToBoxAdapter(
              child: Padding(
                  padding: EdgeInsets.all(48),
                  child: Center(child: CircularProgressIndicator())))
        else if (trips.isEmpty)
          const SliverToBoxAdapter(
            child: OneCard(
              child: EmptyState(
                icon: Icons.insights_rounded,
                title: 'Sin carreras en este periodo',
                message: 'Cambia el periodo o el filtro de fuente.',
              ),
            ),
          )
        else ...[
          SliverToBoxAdapter(child: _summary(trips)),
          if (_range != StatsRange.today)
            SliverToBoxAdapter(child: _perDay(trips, now)),
          SliverToBoxAdapter(child: _perHour(trips)),
          SliverToBoxAdapter(child: _durations(trips)),
          SliverToBoxAdapter(child: _occupancy(trips)),
          SliverToBoxAdapter(child: _seats(trips)),
          for (final group in _byDay(_listed)) ...[
            SliverToBoxAdapter(
              child: SectionLabel(
                dayLabel(group.first.start, now),
                trailing: Text(
                    '${group.length} · ${humanDuration(totalDuration(group))}',
                    style: TextStyle(color: s.textSecondary, fontSize: 13)),
              ),
            ),
            SliverToBoxAdapter(
              child: OneGroup(children: [
                for (final t in group)
                  TripTile(trip: t, onTap: () => _openTrip(t)),
              ]),
            ),
          ],
        ],
      ],
    );
  }

  List<List<TripRecord>> _byDay(List<TripRecord> trips) {
    final out = <List<TripRecord>>[];
    for (final t in trips) {
      if (out.isEmpty ||
          formatDate(out.last.first.start) != formatDate(t.start)) {
        out.add([t]);
      } else {
        out.last.add(t);
      }
    }
    return out;
  }

  Widget _summary(List<TripRecord> trips) {
    final longest =
        trips.map((t) => t.duration).reduce((a, b) => a > b ? a : b);
    return OneCard(
      child: Column(
        children: [
          Row(children: [
            Expanded(
                child: Kpi(
                    icon: Icons.local_taxi_rounded,
                    color: AppColors.accent,
                    label: 'Carreras',
                    value: '${trips.length}')),
            Expanded(
                child: Kpi(
                    icon: Icons.groups_rounded,
                    color: AppColors.passenger,
                    label: 'Pasajeros',
                    value: '${totalPassengers(trips)}')),
          ]),
          const SizedBox(height: 18),
          if (trips.any((t) => t.distanceKm != null)) ...[
            Row(children: [
              Expanded(
                  child: Kpi(
                      icon: Icons.route_rounded,
                      color: AppColors.info,
                      label: 'Distancia',
                      value:
                          '${trips.fold(0.0, (a, t) => a + (t.distanceKm ?? 0)).toStringAsFixed(1)} km')),
              Expanded(
                  child: Kpi(
                      icon: Icons.schedule_rounded,
                      color: AppColors.accent,
                      label: 'Tiempo total',
                      value: humanDuration(totalDuration(trips)))),
            ]),
            const SizedBox(height: 18),
          ],
          Row(children: [
            Expanded(
                child: Kpi(
                    icon: Icons.av_timer_rounded,
                    color: AppColors.purple,
                    label: 'Duración media',
                    value: humanDuration(averageDuration(trips)))),
            Expanded(
                child: Kpi(
                    icon: Icons.trending_up_rounded,
                    color: AppColors.info,
                    label: 'Más larga',
                    value: humanDuration(longest))),
          ]),
        ],
      ),
    );
  }

  Widget _perDay(List<TripRecord> trips, DateTime now) {
    final n = _range == StatsRange.week ? 7 : 14;
    final days = tripsPerDay(trips, n, now);
    final best = days.reduce((a, b) => a.$2 >= b.$2 ? a : b);
    return OneCard(
      child: Column(children: [
        CardHeader('Carreras por día',
            trailing: best.$2 == 0 ? null : 'Mejor: ${shortDate(best.$1)}'),
        BarChart(
          values: [for (final d in days) d.$2.toDouble()],
          labels: [
            for (var i = 0; i < days.length; i++)
              n <= 7 || i.isEven ? weekdayInitial(days[i].$1) : ''
          ],
          highlight: days.length - 1,
          tooltip: (i, v) => '${shortDate(days[i].$1)}: ${v.toInt()}',
        ),
      ]),
    );
  }

  Widget _perHour(List<TripRecord> trips) {
    final hours = tripsPerHour(trips);
    final maxV = hours.reduce((a, b) => a > b ? a : b);
    final peak = maxV == 0 ? null : hours.indexOf(maxV);
    String two(int h) => h.toString().padLeft(2, '0');
    return OneCard(
      child: Column(children: [
        CardHeader('Por hora del día',
            trailing: peak == null ? null : 'Hora pico ${two(peak)}:00',
            trailingColor: AppColors.accent),
        BarChart(
          values: [for (final h in hours) h.toDouble()],
          labels: [for (var h = 0; h < 24; h++) h % 6 == 0 ? two(h) : ''],
          highlight: peak,
          height: 120,
          tooltip: (i, v) => '${two(i)}:00 · ${v.toInt()}',
        ),
      ]),
    );
  }

  Widget _durations(List<TripRecord> trips) {
    final b = durationBuckets(trips);
    return OneCard(
      child: Column(children: [
        CardHeader('Duración de las carreras',
            trailing: 'media ${humanDuration(averageDuration(trips))}'),
        BarChart(
          values: [for (final v in b) v.toDouble()],
          labels: [for (final l in durationBucketLabels) '$l min'],
          color: AppColors.purple,
          height: 110,
          tooltip: (i, v) => '${v.toInt()} carrera(s)',
        ),
      ]),
    );
  }

  Widget _occupancy(List<TripRecord> trips) {
    final d = occupancyDistribution(trips);
    final avg = trips.fold(0, (a, t) => a + t.maxPassengers) / trips.length;
    return OneCard(
      child: Column(children: [
        const CardHeader('Pasajeros por carrera'),
        DonutChart(
          centerValue: avg.toStringAsFixed(1),
          centerLabel: 'media',
          segments: [
            DonutSegment(d[0].toDouble(), AppColors.series[0], '1 pasajero'),
            DonutSegment(d[1].toDouble(), AppColors.series[1], '2 pasajeros'),
            DonutSegment(d[2].toDouble(), AppColors.series[2], '3 pasajeros'),
            DonutSegment(d[3].toDouble(), AppColors.series[3], '4 o más'),
          ],
        ),
      ]),
    );
  }

  Widget _seats(List<TripRecord> trips) {
    final usage = seatUsage(trips);
    final time = seatTime(trips);
    final pax = SeatId.values.where((s) => s != SeatId.driver).toList();
    final maxUse = pax.fold(0, (a, s) => usage[s]! > a ? usage[s]! : a);
    final changes = trips.fold(0, (a, t) => a + t.seatChanges);
    return OneCard(
      child: Column(children: [
        CardHeader('Uso de asientos',
            trailing: changes == 0
                ? null
                : '$changes cambio${changes == 1 ? '' : 's'} de asiento',
            trailingColor: AppColors.info),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CarSeatMap(
              height: 230,
              seats: {
                for (final s in pax)
                  s: SeatVisual(
                    color: usage[s]! > 0 ? seatColor(s) : null,
                    intensity: maxUse == 0 ? 0 : usage[s]! / maxUse,
                    caption: '${usage[s]}',
                  ),
                SeatId.driver: const SeatVisual(),
              },
            ),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final s in pax)
                    LabeledBar(
                      label: s.label,
                      value: '${usage[s]} · ${humanDuration(time[s]!)}',
                      fraction: maxUse == 0 ? 0 : usage[s]! / maxUse,
                      color: seatColor(s),
                    ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text('Número de carreras en que se usó cada asiento y tiempo total.',
            style: TextStyle(
                fontSize: 12, color: Surfaces.of(context).textSecondary)),
      ]),
    );
  }
}
