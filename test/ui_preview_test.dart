// Genera capturas PNG de las pantallas con datos de ejemplo en
// build/previews/ para revisar el diseño sin teléfono:
//   flutter test test/ui_preview_test.dart
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:taxiff/models/app_settings.dart';
import 'package:taxiff/models/detection.dart';
import 'package:taxiff/models/seat.dart';
import 'package:taxiff/models/trip_record.dart';
import 'package:taxiff/screens/home_screen.dart';
import 'package:taxiff/screens/seat_calibration_screen.dart';
import 'package:taxiff/screens/settings_screen.dart';
import 'package:taxiff/screens/trip_detail_screen.dart';
import 'package:taxiff/screens/trip_history_screen.dart';
import 'package:taxiff/services/detection_session.dart';
import 'package:taxiff/ui/theme.dart';
import 'package:taxiff/widgets/detection_view.dart';
import 'package:taxiff/widgets/trip_status_panel.dart';

final now = DateTime(2026, 10, 15, 18, 30);

/// Dos semanas de carreras verosímiles, con algunos cambios de asiento.
List<TripRecord> fakeTrips() {
  final rnd = math.Random(7);
  final trips = <TripRecord>[];
  var id = 1;
  const seats = [
    SeatId.rearRight, SeatId.rearLeft, SeatId.copilot, SeatId.rearCenter
  ];
  for (var day = 13; day >= 0; day--) {
    final n = day == 0 ? 6 : 3 + rnd.nextInt(6);
    for (var k = 0; k < n; k++) {
      final hour = [7, 8, 9, 12, 13, 17, 18, 19, 21][rnd.nextInt(9)];
      final start = DateTime(now.year, now.month, now.day - day, hour,
          rnd.nextInt(60), rnd.nextInt(60));
      if (start.isAfter(now)) continue;
      final dur = Duration(seconds: 180 + rnd.nextInt(1900));
      final end = start.add(dur);
      final pax = 1 + (rnd.nextDouble() < 0.35 ? 1 : 0) +
          (rnd.nextDouble() < 0.12 ? 1 : 0);
      final stints = <PassengerStint>[];
      for (var p = 0; p < pax; p++) {
        final enter = start.add(Duration(seconds: p * 20));
        final exit = end.subtract(Duration(seconds: (pax - 1 - p) * 15));
        final seat = seats[(p + rnd.nextInt(2)) % seats.length];
        final segs = <SeatSegment>[];
        if (rnd.nextDouble() < 0.2 && p == 0) {
          final mid = enter.add(exit.difference(enter) * 0.4);
          segs
            ..add(SeatSegment(seat, enter, mid))
            ..add(SeatSegment(SeatId.rearCenter, mid, exit));
        } else {
          segs.add(SeatSegment(seat, enter, exit));
        }
        stints.add(PassengerStint(p + 1, enter, exit, segs));
      }
      final km = 1.5 + rnd.nextDouble() * dur.inMinutes * 0.45;
      trips.add(TripRecord(
        id: id++,
        start: start,
        end: end,
        maxPassengers: pax,
        source: rnd.nextDouble() < 0.15 ? TripSource.simulation : TripSource.live,
        passengers: stints,
        driver: day == 0 ? 'Juan Pérez' : (day.isEven ? 'Juan Pérez' : 'Ana Torres'),
        shiftId: day == 0 ? 1 : null,
        origin: const GeoPoint(-2.1709, -79.9224, 'Av. 9 de Octubre 1204, Centro'),
        destination: const GeoPoint(-2.1450, -79.8960, 'Av. Francisco de Orellana, Kennedy'),
        distanceMeters: km * 1000,
      ));
    }
  }
  trips.sort((a, b) => b.start.compareTo(a.start));
  return trips;
}

/// Carrera de detalle con cambio de asiento claro.
TripRecord detailTrip() {
  final s = DateTime(2026, 10, 15, 17, 42, 10);
  return TripRecord(
    id: 99,
    start: s,
    end: s.add(const Duration(minutes: 23, seconds: 40)),
    maxPassengers: 3,
    source: TripSource.live,
    driver: 'Juan Pérez',
    shiftId: 1,
    origin: const GeoPoint(-2.1709, -79.9224, 'Av. 9 de Octubre 1204, Centro'),
    destination:
        const GeoPoint(-2.1450, -79.8960, 'Av. Francisco de Orellana, Kennedy'),
    distanceMeters: 8400,
    passengers: [
      PassengerStint(1, s, s.add(const Duration(minutes: 23, seconds: 40)), [
        SeatSegment(SeatId.rearRight, s, s.add(const Duration(minutes: 9))),
        SeatSegment(SeatId.rearCenter, s.add(const Duration(minutes: 9)),
            s.add(const Duration(minutes: 23, seconds: 40))),
      ]),
      PassengerStint(2, s.add(const Duration(seconds: 12)),
          s.add(const Duration(minutes: 15)), [
        SeatSegment(SeatId.rearLeft, s.add(const Duration(seconds: 12)),
            s.add(const Duration(minutes: 15))),
      ]),
      PassengerStint(3, s.add(const Duration(minutes: 4)),
          s.add(const Duration(minutes: 23, seconds: 40)), [
        SeatSegment(SeatId.copilot, s.add(const Duration(minutes: 4)),
            s.add(const Duration(minutes: 23, seconds: 40))),
      ]),
    ],
  );
}

Future<void> loadFonts() async {
  Future<void> load(String family, String path) async {
    final bytes = File(path).readAsBytesSync();
    final loader = FontLoader(family)
      ..addFont(Future.value(ByteData.view(bytes.buffer)));
    await loader.load();
  }

  await load('Roboto', 'assets/fonts/Roboto-Regular.ttf');
  await load('Roboto', 'assets/fonts/Roboto-Bold.ttf');
  final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? r'C:\flutter';
  await load('MaterialIcons',
      '$flutterRoot/bin/cache/artifacts/material_fonts/materialicons-regular.otf');
}

final _key = GlobalKey();

Future<void> shoot(WidgetTester tester, String name, Widget screen,
    {Brightness b = Brightness.light, double height = 2340}) async {
  tester.view.physicalSize = Size(1080, height);
  tester.view.devicePixelRatio = 2.625;
  await tester.pumpWidget(RepaintBoundary(
    key: _key,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(b),
      themeAnimationDuration: Duration.zero,
      home: screen,
    ),
  ));
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(seconds: 2));
  await tester.runAsync(() async {
    final boundary =
        _key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2.625 / 2);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    final out = File('build/previews/$name.png')..createSync(recursive: true);
    out.writeAsBytesSync(png!.buffer.asUint8List());
  });
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({'privacyAccepted': true});
    await loadFonts();
  });

  final trips = fakeTrips();
  Future<List<TripRecord>> loader() async => trips;

  testWidgets('inicio', (t) async {
    final home = HomeScreen(
      loader: loader,
      now: () => now,
      askPrivacy: false,
      shiftLoader: () async => Shift(
          id: 1,
          driver: 'Juan Pérez',
          start: now.subtract(const Duration(hours: 9, minutes: 20))),
    );
    await shoot(t, '01_inicio', home);
    await shoot(t, '02_inicio_completo', home, height: 6200);
    await shoot(t, '03_inicio_oscuro', home, b: Brightness.dark, height: 6200);
  });

  testWidgets('bitácora', (t) async {
    await shoot(t, '04_bitacora_completa',
        TripHistoryScreen(loader: loader, now: () => now),
        height: 9000);
  });

  testWidgets('detalle', (t) async {
    await shoot(t, '05_detalle', TripDetailScreen(trip: detailTrip()),
        height: 5600);
    await shoot(t, '06_detalle_oscuro', TripDetailScreen(trip: detailTrip()),
        b: Brightness.dark, height: 5600);
  });

  testWidgets('ajustes', (t) async {
    await shoot(t, '07_ajustes', const SettingsScreen(initial: AppSettings()),
        height: 7000);
  });

  testWidgets('calibración', (t) async {
    await shoot(
      t,
      '10_calibracion',
      SeatCalibrationScreen(
        title: 'Calibra este vídeo',
        aspectRatio: 640 / 360,
        seats: const AppSettings().seats,
        background: Image.file(File('build/previews/frame_video.png'),
            fit: BoxFit.fill),
      ),
      b: Brightness.dark,
    );
  });

  testWidgets('en vivo', (t) async {
    final session = DetectionSession(
        source: TripSource.live,
        settings: const AppSettings(seatCalibrated: true));
    Detection p(double l, double tp, double r, double b) =>
        Detection(left: l, top: tp, right: r, bottom: b, score: 0.9);
    final t0 = DateTime(2026, 10, 15, 18, 20);
    // Conductor + dos pasajeros; uno se cambia de asiento.
    for (var i = 0; i < 40; i++) {
      final x = i < 25 ? 0.6 : 0.6 - (i - 25) * 0.012;
      await session.ingest([
        p(0.05, 0.42, 0.40, 0.98),
        p(0.20, 0.22, 0.40, 0.55),
        p(x, 0.22, x + 0.2, 0.55),
      ], t0.add(Duration(milliseconds: 400 * i)));
    }
    session.inferMs = 182;
    session.fps = 3.4;
    await shoot(
      t,
      '08_en_vivo',
      Theme(
        data: buildTheme(Brightness.dark),
        child: Scaffold(
          appBar: AppBar(title: const Text('En vivo'), actions: const [
            Icon(Icons.event_seat_outlined),
            SizedBox(width: 16),
            Icon(Icons.visibility_outlined),
            SizedBox(width: 16),
            Icon(Icons.dark_mode_outlined),
            SizedBox(width: 16),
            Icon(Icons.stop_circle_outlined),
            SizedBox(width: 16),
          ]),
          body: Column(children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 4, 10, 0),
                child: Center(
                  child: DetectionView(
                    session: session,
                    aspectRatio: 3 / 4,
                    background: Container(
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Color(0xFF3A3F47), Color(0xFF1B1D21)],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            TripStatusPanel(session: session),
          ]),
        ),
      ),
      b: Brightness.dark,
    );
  });
}
