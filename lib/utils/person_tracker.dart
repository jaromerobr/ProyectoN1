import 'dart:math' as math;

import '../models/detection.dart';
import '../models/seat.dart';

/// Una persona seguida entre fotogramas.
class Track {
  final int id;
  Detection box;
  final DateTime firstSeen;
  DateTime lastSeen;
  int hits = 1;
  bool confirmed = false;

  /// Votos con decaimiento por asiento (null = sin asiento). El asiento
  /// estable es el más votado, así un fotograma raro no cambia el asiento.
  final Map<SeatId?, double> _votes = {};

  Track(this.id, this.box, this.firstSeen) : lastSeen = firstSeen;

  void vote(SeatId? seat) {
    _votes.updateAll((_, v) => v * 0.85);
    _votes[seat] = (_votes[seat] ?? 0) + 1;
  }

  double votesFor(SeatId? seat) => _votes[seat] ?? 0;

  SeatId? get seat {
    SeatId? best;
    var bestV = -1.0;
    _votes.forEach((s, v) {
      if (v > bestV) {
        bestV = v;
        best = s;
      }
    });
    return best;
  }
}

/// Seguimiento por persona al estilo ByteTrack (simplificado, sin filtro de
/// Kalman):
/// 1. Las pistas se asocian primero con las detecciones de confianza alta y
///    después con las de confianza baja (por IoU). Así una persona tapada a
///    medias no pierde su ID.
/// 2. Solo las detecciones de confianza alta crean pistas nuevas.
/// 3. Una pista se confirma tras [minHits] fotogramas y se borra si lleva más
///    de [maxLost] sin verse. Mientras está perdida menos de [keepVisible],
///    se sigue mostrando y contando (evita parpadeos en el conteo).
class PersonTracker {
  final double highThreshold;
  final double matchIou;
  final int minHits;
  final Duration maxLost;
  final Duration keepVisible;

  PersonTracker({
    this.highThreshold = 0.45,
    this.matchIou = 0.3,
    this.minHits = 2,
    this.maxLost = const Duration(milliseconds: 2500),
    this.keepVisible = const Duration(milliseconds: 1200),
  });

  final List<Track> tracks = [];
  int _nextId = 1;

  /// Devuelve las pistas confirmadas visibles en el instante [t].
  List<Track> update(List<Detection> dets, DateTime t) {
    final high = dets.where((d) => d.score >= highThreshold).toList();
    final low = dets.where((d) => d.score < highThreshold).toList();

    final pending = List<Track>.of(tracks);
    var unmatchedHigh = _match(pending, high, t);
    _match(pending, low, t);
    unmatchedHigh = _matchByDistance(pending, unmatchedHigh, t);

    for (final d in unmatchedHigh) {
      tracks.add(Track(_nextId++, d, t));
    }
    tracks.removeWhere((tr) {
      final lost = t.difference(tr.lastSeen);
      // Una pista no confirmada que se pierde era casi seguro un falso positivo.
      return lost > maxLost || (!tr.confirmed && lost > Duration.zero);
    });

    return [
      for (final tr in tracks)
        if (tr.confirmed && t.difference(tr.lastSeen) <= keepVisible) tr,
    ];
  }

  /// Asociación voraz por IoU. Quita de [pending] las pistas emparejadas y
  /// devuelve las detecciones sin pareja.
  List<Detection> _match(List<Track> pending, List<Detection> dets, DateTime t) {
    final pairs = <(Track, Detection, double)>[];
    for (final tr in pending) {
      for (final d in dets) {
        final iou = tr.box.iou(d);
        if (iou >= matchIou) pairs.add((tr, d, iou));
      }
    }
    pairs.sort((a, b) => b.$3.compareTo(a.$3));
    return _assign(pending, dets, pairs, t);
  }

  /// Tercera etapa: cuando alguien se cambia de asiento puede moverse tanto
  /// entre dos fotogramas que su caja ya no se solapa con la anterior. Se
  /// asocia por cercanía del centro si el tamaño es parecido.
  List<Detection> _matchByDistance(
      List<Track> pending, List<Detection> dets, DateTime t) {
    final pairs = <(Track, Detection, double)>[];
    for (final tr in pending) {
      if (!tr.confirmed) continue;
      for (final d in dets) {
        final dist = math.sqrt(math.pow(tr.box.cx - d.cx, 2) +
            math.pow(tr.box.cy - d.cy, 2));
        final size = math.max(tr.box.width, d.width);
        final ratio = d.area / math.max(tr.box.area, 1e-6);
        if (dist < size * 0.9 && ratio > 0.4 && ratio < 2.5) {
          pairs.add((tr, d, -dist)); // mayor = mejor
        }
      }
    }
    pairs.sort((a, b) => b.$3.compareTo(a.$3));
    return _assign(pending, dets, pairs, t, smooth: false);
  }

  List<Detection> _assign(List<Track> pending, List<Detection> dets,
      List<(Track, Detection, double)> pairs, DateTime t,
      {bool smooth = true}) {
    final usedT = <Track>{};
    final usedD = <Detection>{};
    for (final (tr, d, _) in pairs) {
      if (usedT.contains(tr) || usedD.contains(d)) continue;
      usedT.add(tr);
      usedD.add(d);
      tr.box = smooth ? _smooth(tr.box, d) : d;
      tr.lastSeen = t;
      tr.hits++;
      if (tr.hits >= minHits) tr.confirmed = true;
    }
    pending.removeWhere(usedT.contains);
    return dets.where((d) => !usedD.contains(d)).toList();
  }

  /// Suaviza la caja para que no tiemble entre fotogramas.
  static Detection _smooth(Detection old, Detection now) {
    const a = 0.7;
    double mix(double o, double n) => o * (1 - a) + n * a;
    return Detection(
      left: mix(old.left, now.left),
      top: mix(old.top, now.top),
      right: mix(old.right, now.right),
      bottom: mix(old.bottom, now.bottom),
      score: now.score,
    );
  }

  void reset() => tracks.clear();
}
