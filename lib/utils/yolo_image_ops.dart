import 'dart:math' as math;
import 'dart:typed_data';

/// Funciones puras (sin Flutter) que corren en el isolate de inferencia:
/// convierten un fotograma al tensor de entrada del modelo y decodifican la
/// salida de YOLO. Se pueden probar con `flutter test`.

/// Geometría del letterbox: imagen "derecha" (ya rotada) de [srcW]×[srcH]
/// escalada a [scale] y centrada en la entrada [inW]×[inH] con bordes grises.
class Letterbox {
  final int srcW, srcH, inW, inH;
  final double scale, padX, padY;

  Letterbox._(this.srcW, this.srcH, this.inW, this.inH, this.scale, this.padX,
      this.padY);

  factory Letterbox(int srcW, int srcH, int inW, int inH) {
    final s = math.min(inW / srcW, inH / srcH);
    return Letterbox._(srcW, srcH, inW, inH, s, (inW - srcW * s) / 2,
        (inH - srcH * s) / 2);
  }
}

/// Valor de relleno de Ultralytics (114/255).
const double _pad = 114 / 255;

/// Mapeo de cada píxel de la entrada del modelo a un píxel del buffer fuente.
/// sx = colSx[ox] + rowSx[oy], sy = colSy[ox] + rowSy[oy]; -1 = relleno.
class _SampleMap {
  final Int32List colU, colSx, colSy, rowU, rowSx, rowSy;
  final Letterbox lb;

  _SampleMap._(this.lb, this.colU, this.colSx, this.colSy, this.rowU,
      this.rowSx, this.rowSy);

  /// [bufW]×[bufH] son las dimensiones del buffer tal como llega (sensor).
  /// [rotation] (0/90/180/270, horario) lo pone derecho; [mirror] lo espeja
  /// horizontalmente después de rotar (cámara frontal).
  factory _SampleMap(int bufW, int bufH, int rotation, bool mirror, int inW,
      int inH) {
    final swap = rotation == 90 || rotation == 270;
    final upW = swap ? bufH : bufW;
    final upH = swap ? bufW : bufH;
    final lb = Letterbox(upW, upH, inW, inH);

    // sx = a·ux + b·uy + c ; sy = d·ux + e·uy + f
    late int a, b, c, d, e, f;
    switch (rotation) {
      case 90:
        (a, b, c, d, e, f) = (0, 1, 0, -1, 0, bufH - 1);
      case 180:
        (a, b, c, d, e, f) = (-1, 0, bufW - 1, 0, -1, bufH - 1);
      case 270:
        (a, b, c, d, e, f) = (0, -1, bufW - 1, 1, 0, 0);
      default:
        (a, b, c, d, e, f) = (1, 0, 0, 0, 1, 0);
    }

    final colU = Int32List(inW), colSx = Int32List(inW), colSy = Int32List(inW);
    for (var ox = 0; ox < inW; ox++) {
      var ux = ((ox + 0.5 - lb.padX) / lb.scale).floor();
      if (ux < 0 || ux >= upW) {
        colU[ox] = -1;
        continue;
      }
      if (mirror) ux = upW - 1 - ux;
      colU[ox] = ux;
      colSx[ox] = a * ux + c;
      colSy[ox] = d * ux + f;
    }
    final rowU = Int32List(inH), rowSx = Int32List(inH), rowSy = Int32List(inH);
    for (var oy = 0; oy < inH; oy++) {
      final uy = ((oy + 0.5 - lb.padY) / lb.scale).floor();
      if (uy < 0 || uy >= upH) {
        rowU[oy] = -1;
        continue;
      }
      rowU[oy] = uy;
      rowSx[oy] = b * uy;
      rowSy[oy] = e * uy;
    }
    return _SampleMap._(lb, colU, colSx, colSy, rowU, rowSx, rowSy);
  }
}

/// Escribe un píxel RGB (0..1) en [out] con el layout del modelo.
@pragma('vm:prefer-inline')
void _put(Float32List out, int p, int plane, bool nchw, double r, double g,
    double b) {
  if (nchw) {
    out[p] = r;
    out[plane + p] = g;
    out[2 * plane + p] = b;
  } else {
    final i = p * 3;
    out[i] = r;
    out[i + 1] = g;
    out[i + 2] = b;
  }
}

/// Fotograma YUV 4:2:0 de la cámara. Sirve para 3 planos (YUV_420_888, con
/// cualquier pixelStride) y para NV21 en un solo plano (ver [Yuv420Frame.nv21]).
class Yuv420Frame {
  final int width, height;
  final Uint8List y, u, v;
  final int yRowStride, uvRowStride, uvPixelStride, uOffset, vOffset;

  const Yuv420Frame({
    required this.width,
    required this.height,
    required this.y,
    required this.u,
    required this.v,
    required this.yRowStride,
    required this.uvRowStride,
    required this.uvPixelStride,
    this.uOffset = 0,
    this.vOffset = 0,
  });

  factory Yuv420Frame.nv21(Uint8List bytes, int width, int height,
      [int? rowStride]) {
    final rs = rowStride ?? width;
    final uvBase = rs * height;
    return Yuv420Frame(
      width: width,
      height: height,
      y: bytes,
      u: bytes,
      v: bytes,
      yRowStride: rs,
      uvRowStride: rs,
      uvPixelStride: 2,
      vOffset: uvBase,
      uOffset: uvBase + 1,
    );
  }
}

/// Convierte YUV → RGB, rota, espeja, redimensiona (vecino más cercano) y
/// aplica letterbox en una sola pasada, directamente sobre [out].
Letterbox fillInputFromYuv(Yuv420Frame f, Float32List out,
    {required int inW,
    required int inH,
    required bool nchw,
    int rotation = 0,
    bool mirror = false}) {
  final m = _SampleMap(f.width, f.height, rotation, mirror, inW, inH);
  final plane = inW * inH;
  final y = f.y, u = f.u, v = f.v;
  final yRs = f.yRowStride, uvRs = f.uvRowStride, uvPs = f.uvPixelStride;
  final uOff = f.uOffset, vOff = f.vOffset;

  for (var oy = 0; oy < inH; oy++) {
    final rowOk = m.rowU[oy] >= 0;
    final rsx = m.rowSx[oy], rsy = m.rowSy[oy];
    for (var ox = 0; ox < inW; ox++) {
      final p = oy * inW + ox;
      if (!rowOk || m.colU[ox] < 0) {
        _put(out, p, plane, nchw, _pad, _pad, _pad);
        continue;
      }
      final sx = m.colSx[ox] + rsx;
      final sy = m.colSy[ox] + rsy;
      final yy = y[sy * yRs + sx].toDouble();
      final uvi = (sy >> 1) * uvRs + (sx >> 1) * uvPs;
      final uu = u[uOff + uvi] - 128.0;
      final vv = v[vOff + uvi] - 128.0;
      final r = (yy + 1.402 * vv).clamp(0.0, 255.0);
      final g = (yy - 0.344136 * uu - 0.714136 * vv).clamp(0.0, 255.0);
      final b = (yy + 1.772 * uu).clamp(0.0, 255.0);
      _put(out, p, plane, nchw, r / 255, g / 255, b / 255);
    }
  }
  return m.lb;
}

/// Igual que [fillInputFromYuv] pero desde un buffer RGBA8888 (vídeo).
Letterbox fillInputFromRgba(Uint8List rgba, int width, int height,
    Float32List out,
    {required int inW,
    required int inH,
    required bool nchw,
    int rotation = 0,
    bool mirror = false}) {
  final m = _SampleMap(width, height, rotation, mirror, inW, inH);
  final plane = inW * inH;
  for (var oy = 0; oy < inH; oy++) {
    final rowOk = m.rowU[oy] >= 0;
    final rsx = m.rowSx[oy], rsy = m.rowSy[oy];
    for (var ox = 0; ox < inW; ox++) {
      final p = oy * inW + ox;
      if (!rowOk || m.colU[ox] < 0) {
        _put(out, p, plane, nchw, _pad, _pad, _pad);
        continue;
      }
      final i = ((m.colSy[ox] + rsy) * width + m.colSx[ox] + rsx) * 4;
      _put(out, p, plane, nchw, rgba[i] / 255, rgba[i + 1] / 255,
          rgba[i + 2] / 255);
    }
  }
  return m.lb;
}

/// Decodifica la salida de YOLOv8/v11 ([1, 4+nc, N] o [1, N, 4+nc]), filtra
/// por [classIndex] y [confidence], aplica NMS y devuelve
/// [l, t, r, b, score] * n en coordenadas normalizadas de la imagen derecha.
Float32List decodeYolo(Float32List out, List<int> shape, Letterbox lb,
    {int classIndex = 0,
    double confidence = 0.45,
    double iou = 0.45,
    int maxDetections = 30}) {
  final dims = shape.where((d) => d != 1).toList();
  if (dims.length != 2) {
    throw ArgumentError('Forma de salida no soportada: $shape');
  }
  final channelsFirst = dims[0] < dims[1];
  final ch = channelsFirst ? dims[0] : dims[1];
  final n = channelsFirst ? dims[1] : dims[0];
  final cls = 4 + (classIndex < ch - 4 ? classIndex : 0);
  double at(int c, int i) => channelsFirst ? out[c * n + i] : out[i * ch + c];

  final cand = <_Box>[];
  var maxCoord = 0.0;
  for (var i = 0; i < n; i++) {
    final s = at(cls, i);
    if (s < confidence) continue;
    final cx = at(0, i), cy = at(1, i), w = at(2, i), h = at(3, i);
    maxCoord = math.max(maxCoord, math.max(cx, cy));
    cand.add(_Box(cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2, s));
  }
  if (cand.isEmpty) return Float32List(0);

  // Los exports recientes de Ultralytics normalizan las cajas a 0..1.
  final normalized = maxCoord <= 2.0;
  final sx = normalized ? lb.inW.toDouble() : 1.0;
  final sy = normalized ? lb.inH.toDouble() : 1.0;

  cand.sort((a, b) => b.score.compareTo(a.score));
  final keep = <_Box>[];
  for (final c in cand) {
    if (keep.length >= maxDetections) break;
    if (keep.every((k) => k.iou(c) <= iou)) keep.add(c);
  }

  double nx(double v) =>
      ((v * sx - lb.padX) / lb.scale / lb.srcW).clamp(0.0, 1.0);
  double ny(double v) =>
      ((v * sy - lb.padY) / lb.scale / lb.srcH).clamp(0.0, 1.0);

  final res = Float32List(keep.length * 5);
  for (var k = 0; k < keep.length; k++) {
    final b = keep[k];
    res[k * 5] = nx(b.l);
    res[k * 5 + 1] = ny(b.t);
    res[k * 5 + 2] = nx(b.r);
    res[k * 5 + 3] = ny(b.b);
    res[k * 5 + 4] = b.score;
  }
  return res;
}

class _Box {
  final double l, t, r, b, score;
  _Box(this.l, this.t, this.r, this.b, this.score);
  double get area => math.max(0, r - l) * math.max(0, b - t);
  double iou(_Box o) {
    final iw = math.min(r, o.r) - math.max(l, o.l);
    final ih = math.min(b, o.b) - math.max(t, o.t);
    if (iw <= 0 || ih <= 0) return 0;
    final inter = iw * ih;
    return inter / (area + o.area - inter);
  }
}
