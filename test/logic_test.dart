import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:taxiff/models/app_settings.dart';
import 'package:taxiff/models/detection.dart';
import 'package:taxiff/models/seat.dart';
import 'package:taxiff/models/trip_record.dart';
import 'package:taxiff/services/detection_session.dart';
import 'package:taxiff/utils/person_tracker.dart';
import 'package:taxiff/utils/roi_evaluator.dart';
import 'package:taxiff/utils/trip_tracker.dart';
import 'package:taxiff/utils/yolo_image_ops.dart';

Detection box(double l, double r, {double t = 0.2, double b = 0.8}) =>
    Detection(left: l, top: t, right: r, bottom: b, score: 0.9);

void main() {
  group('RoiEvaluator · asientos', () {
    const driverOnly = RoiEvaluator(
      seats: [
        SeatPoint(SeatId.driver, 0.2, 0.6),
        SeatPoint(SeatId.rearLeft, 0.2, 0.37, enabled: false),
      ],
      radius: 0.15,
    );
    const withRear = RoiEvaluator(
      seats: [
        SeatPoint(SeatId.driver, 0.2, 0.6),
        SeatPoint(SeatId.rearLeft, 0.2, 0.37),
      ],
      radius: 0.15,
    );

    test('el pasajero sentado detrás del conductor cuenta como pasajero', () {
      final driver = box(0.0, 0.4, t: 0.25, b: 0.95); // cubre el asiento
      final rear = box(0.1, 0.3, t: 0.2, b: 0.55); // mismo lado, detrás
      final front = box(0.6, 0.95);
      final out = driverOnly.classify([rear, driver, front]);
      expect(out.map((d) => d.role), [
        OccupantRole.passenger,
        OccupantRole.driver,
        OccupantRole.passenger,
      ]);
      expect(RoiEvaluator.countPassengers(out), 2);
      // Con el asiento trasero calibrado, además sabemos dónde va.
      final out2 = withRear.classify([rear, driver]);
      expect(out2.map((d) => d.seat), [SeatId.rearLeft, SeatId.driver]);
    });

    test('un asiento admite una sola persona: gana el centroide más cercano',
        () {
      final a = box(0.05, 0.35, t: 0.3, b: 0.9); // centro (0.20, 0.60)
      final b = box(0.0, 0.5, t: 0.1, b: 0.7); // también cubre el punto
      final out = driverOnly.classify([b, a]);
      expect(out.where((d) => d.role == OccupantRole.driver), hasLength(1));
      expect(out[1].role, OccupantRole.driver);
    });

    test('asiento vacío: todos son pasajeros', () {
      final out = driverOnly
          .classify([box(0.6, 0.9), box(0.4, 0.55, t: 0.0, b: 0.3)]);
      expect(RoiEvaluator.countPassengers(out), 2);
    });

    test('caja que no cubre el punto pero está dentro de la tolerancia', () {
      final near = box(0.24, 0.44, t: 0.4, b: 0.8); // centro (0.34,0.6), d=0.14
      expect(driverOnly.classify([near]).single.role, OccupantRole.driver);
      final far = box(0.3, 0.5, t: 0.4, b: 0.8); // d=0.2 > 0.15
      expect(driverOnly.classify([far]).single.role, OccupantRole.passenger);
    });
  });

  group('RoiEvaluator · jaula', () {
    test('quien está fuera del contorno (ventana) no cuenta', () {
      const roi = RoiEvaluator(cabin: [(0.1, 0.2), (0.9, 0.2), (0.9, 1.0), (0.1, 1.0)]);
      expect(roi.insideCabin(box(0.4, 0.6)), isTrue); // dentro
      expect(roi.insideCabin(box(0.0, 0.08)), isFalse); // en la ventana izquierda
      expect(roi.insideCabin(box(0.4, 0.6, t: 0.0, b: 0.2)), isFalse); // arriba
      expect(const RoiEvaluator().insideCabin(box(0.0, 0.05)), isTrue); // sin jaula
    });
  });

  group('PersonTracker', () {
    final t0 = DateTime(2026, 1, 1, 12);
    DateTime at(double s) => t0.add(Duration(milliseconds: (s * 1000).round()));
    Detection det(double l, double score) =>
        Detection(left: l, top: 0.2, right: l + 0.2, bottom: 0.8, score: score);

    test('mantiene el mismo ID mientras la persona se mueve', () {
      final tr = PersonTracker();
      final ids = <int>{};
      for (var i = 0; i < 10; i++) {
        final vis = tr.update([det(0.1 + i * 0.01, 0.9)], at(i * 0.3));
        ids.addAll(vis.map((t) => t.id));
      }
      expect(ids, hasLength(1));
    });

    test('una detección débil (2.ª etapa) conserva la pista', () {
      final tr = PersonTracker(highThreshold: 0.5);
      tr.update([det(0.1, 0.9)], at(0));
      final id = tr.update([det(0.1, 0.9)], at(0.3)).single.id;
      for (var i = 2; i < 12; i++) {
        final vis = tr.update([det(0.1, 0.3)], at(i * 0.3)); // tapada a medias
        expect(vis.single.id, id);
      }
    });

    test('un falso positivo de un fotograma nunca se confirma', () {
      final tr = PersonTracker();
      expect(tr.update([det(0.5, 0.9)], at(0)), isEmpty);
      expect(tr.update([], at(0.3)), isEmpty);
      expect(tr.tracks, isEmpty);
    });

    test('pérdida breve: se sigue contando; pérdida larga: ID nuevo', () {
      final tr = PersonTracker();
      tr.update([det(0.1, 0.9)], at(0));
      final id = tr.update([det(0.1, 0.9)], at(0.3)).single.id;
      expect(tr.update([], at(1.0)), hasLength(1)); // perdida 0.7 s
      expect(tr.update([], at(4.0)), isEmpty); // perdida 3.7 s → borrada
      tr.update([det(0.1, 0.9)], at(4.3));
      expect(tr.update([det(0.1, 0.9)], at(4.6)).single.id, isNot(id));
    });
  });

  group('DetectionSession · cambio de asiento', () {
    test('el pasajero que se desliza conserva su ID y genera el evento',
        () async {
      final session = DetectionSession(
          source: TripSource.simulation, settings: const AppSettings());
      Detection p(double l, double t, double r, double b) =>
          Detection(left: l, top: t, right: r, bottom: b, score: 0.9);
      final t0 = DateTime(2026, 1, 1, 12);
      // Se desliza de Trasero der. (x≈0.7) a Trasero centro (x≈0.5) y se
      // queda ahí; el cambio se confirma tras 3 s en el asiento nuevo.
      for (var i = 0; i < 55; i++) {
        final x = i < 20 ? 0.6 : (0.6 - (i - 20) * 0.012).clamp(0.4, 0.6);
        await session.ingest([
          p(0.05, 0.42, 0.40, 0.98), // conductor
          p(x, 0.22, x + 0.2, 0.55),
        ], t0.add(Duration(milliseconds: 400 * i)));
      }
      final pax = session.detections
          .where((d) => d.role == OccupantRole.passenger)
          .toList();
      expect(pax.single.seat, SeatId.rearCenter);
      final changes = session.events
          .where((e) => e.kind == SessionEventKind.seatChange)
          .toList();
      expect(changes, hasLength(1));
      expect((changes.single.from, changes.single.to),
          (SeatId.rearRight, SeatId.rearCenter));
      expect(changes.single.trackId, pax.single.trackId);
      session.dispose();
    });
  });

  group('DetectionSession · duración mínima', () {
    test('una carrera de 10 s se descarta como falso positivo', () async {
      final session = DetectionSession(
          source: TripSource.simulation, settings: const AppSettings());
      final t0 = DateTime(2026, 1, 1, 12);
      const pax = Detection(left: 0.6, top: 0.2, right: 0.8, bottom: 0.6, score: 0.9);
      // 10 s con un pasajero y luego 70 s sin nadie (1 imagen por segundo):
      // pasado el margen de unión (45 s) la carrera se evalúa y se descarta.
      for (var i = 0; i < 80; i++) {
        await session.ingest(i < 10 ? [pax] : [], t0.add(Duration(seconds: i)));
      }
      expect(session.tracker.inTrip, isFalse);
      expect(session.events.map((e) => e.kind),
          contains(SessionEventKind.discarded));
      expect(session.tripsSaved, 0);
      session.dispose();
    });
  });

  group('DetectionSession · unión de carreras', () {
    test('un hueco de 20 s sin ver al pasajero no parte la carrera', () async {
      final session = DetectionSession(
          source: TripSource.simulation, settings: const AppSettings());
      final t0 = DateTime(2026, 1, 1, 12);
      const pax = Detection(left: 0.6, top: 0.2, right: 0.8, bottom: 0.6, score: 0.9);
      // 40 s con pasajero, 20 s sin verlo (cierra a los 15 s), 40 s con él.
      for (var i = 0; i < 100; i++) {
        final seen = i < 40 || i >= 60;
        await session.ingest(seen ? [pax] : [], t0.add(Duration(seconds: i)));
      }
      expect(session.tracker.inTrip, isTrue);
      // Conserva el inicio original (la persona se confirma en su 2.º fotograma).
      expect(session.tracker.tripStart, t0.add(const Duration(seconds: 1)));
      expect(session.events.map((e) => e.kind),
          contains(SessionEventKind.resumed));
      expect(session.tripsSaved, 0);
      session.dispose();
    });
  });

  group('TripRecord', () {
    test('GPS, conductor y turno sobreviven al guardado en la BD', () {
      final s = DateTime(2026, 1, 1, 12);
      final t = TripRecord(
        start: s,
        end: s.add(const Duration(minutes: 10)),
        maxPassengers: 2,
        source: TripSource.live,
        driver: 'Ana',
        shiftId: 3,
        origin: const GeoPoint(-2.17, -79.92, 'Centro'),
        destination: const GeoPoint(-2.14, -79.89),
        distanceMeters: 5400,
      );
      final back = TripRecord.fromMap({...t.toMap(), 'id': 7});
      expect(back.id, 7);
      expect((back.driver, back.shiftId), ('Ana', 3));
      expect(back.origin!.label, 'Centro');
      expect(back.destination!.address, isNull);
      expect(back.distanceKm, closeTo(5.4, 1e-9));
    });
  });

  group('TripTracker', () {
    final t0 = DateTime(2026, 1, 1, 12);
    DateTime at(double s) => t0.add(Duration(milliseconds: (s * 1000).round()));

    /// Alimenta el tracker a 5 fps con [count] desde [from] hasta [to] s.
    List<CompletedTrip> feed(TripTracker tr, int count, double from, double to) {
      final done = <CompletedTrip>[];
      for (var s = from; s < to - 1e-9; s += 0.2) {
        final c = tr.update(count, at(s));
        if (c != null) done.add(c);
      }
      return done;
    }

    test('inicia, ignora parpadeos y cierra tras 5 s sin pasajeros', () {
      final tr = TripTracker();
      expect(feed(tr, 0, 0, 2), isEmpty);
      feed(tr, 2, 2, 10);
      expect(tr.inTrip, isTrue);
      expect(tr.tripStart, at(2)); // retroactivo al primer fotograma visto

      // Parpadeo de 3 s sin detección: no cierra.
      expect(feed(tr, 0, 10, 13), isEmpty);
      feed(tr, 1, 13, 20);
      expect(tr.inTrip, isTrue);

      // 0 pasajeros más de 5 s: cierra con fin = primer fotograma vacío.
      final done = feed(tr, 0, 20, 26);
      expect(done, hasLength(1));
      expect(done.single.start, at(2));
      expect(done.single.end, at(20));
      expect(done.single.duration, const Duration(seconds: 18));
      expect(done.single.maxPassengers, 2);
      expect(tr.inTrip, isFalse);
    });

    test('un falso positivo aislado no abre carrera', () {
      final tr = TripTracker();
      tr.update(1, at(0));
      tr.update(0, at(0.2));
      expect(feed(tr, 0, 0.4, 10), isEmpty);
      expect(tr.state, TripState.idle);
    });

    test('un pico de un solo fotograma no sube el máximo', () {
      final tr = TripTracker();
      feed(tr, 1, 0, 5);
      tr.update(3, at(5)); // duplicado puntual
      feed(tr, 1, 5.2, 8);
      final done = tr.forceEnd(at(8));
      expect(done!.maxPassengers, 1);
    });
  });

  group('yolo_image_ops', () {
    test('rotación 90 + letterbox: el píxel marcado cae donde debe', () {
      // Sensor 8×4 (horizontal), rotado 90° → imagen derecha 4×8.
      const w = 8, h = 4;
      final y = Uint8List(w * h);
      y[0 * w + 7] = 255; // esquina sup. derecha del sensor
      final uv = Uint8List(w * h ~/ 2)..fillRange(0, w * h ~/ 2, 128);
      final f = Yuv420Frame(
        width: w, height: h, y: y, u: uv, v: uv,
        yRowStride: w, uvRowStride: w, uvPixelStride: 2, vOffset: 1,
      );
      final out = Float32List(8 * 8 * 3);
      final lb = fillInputFromYuv(f, out,
          inW: 8, inH: 8, nchw: true, rotation: 90);
      expect((lb.srcW, lb.srcH), (4, 8));
      expect(lb.padX, 2);
      // Girar 90° horario lleva la esquina sup. derecha a la inf. derecha:
      // en la imagen derecha (ux=3, uy=7) → entrada (ox=5, oy=7).
      expect(out[7 * 8 + 5], closeTo(1, 1e-6));
      expect(out.sublist(0, 64).where((v) => v > 0.99), hasLength(1));
      expect(out[0], closeTo(114 / 255, 1e-6)); // relleno
    });

    test('decodeYolo: [1,5,N] normalizado, NMS y vuelta a la imagen', () {
      const n = 100; // el resto de anclas quedan a 0 (sin detección)
      // canales: cx, cy, w, h, score  (normalizados 0..1 sobre 640)
      final data = <List<double>>[
        [0.5, 0.5, 0.2, 0.4, 0.9],
        [0.51, 0.5, 0.2, 0.4, 0.8], // duplicado → NMS
        [0.6, 0.5, 0.1, 0.2, 0.7],
        [0.2, 0.5, 0.1, 0.2, 0.1], // baja confianza
      ];
      final out = Float32List(5 * n);
      for (var i = 0; i < data.length; i++) {
        for (var c = 0; c < 5; c++) {
          out[c * n + i] = data[i][c];
        }
      }
      // Imagen derecha 320×640 en entrada 640×640: escala 1, padX 160.
      final lb = Letterbox(320, 640, 640, 640);
      final dets = Detection.fromFlat(decodeYolo(out, [1, 5, n], lb));
      expect(dets, hasLength(2));
      // cx=0.5·640=320 → (320-160)/320 = 0.5 en la imagen.
      expect(dets[0].cx, closeTo(0.5, 1e-5));
      expect(dets[0].width, closeTo(0.2 * 640 / 320, 1e-5));
      expect(dets[1].cx, closeTo((0.6 * 640 - 160) / 320, 1e-5));
    });
  });
}
