import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

import '../models/detection.dart';
import '../utils/yolo_image_ops.dart';

const defaultModelAsset = 'assets/best.tflite';

class DetectionOutput {
  final List<Detection> detections;

  /// Tamaño de la imagen derecha analizada (para dibujar con su aspecto).
  final int imageWidth, imageHeight;
  final double preMs, inferMs, postMs;

  const DetectionOutput(this.detections, this.imageWidth, this.imageHeight,
      this.preMs, this.inferMs, this.postMs);
}

/// Ejecuta YOLO en un isolate dedicado. El isolate es dueño del intérprete
/// TFLite y hace también el preprocesado (YUV→RGB, rotación, letterbox) y el
/// postprocesado (NMS), así el hilo de la UI nunca se bloquea.
///
/// Atiende una petición a la vez: quien llama debe descartar fotogramas
/// mientras [isBusy] sea true.
class YoloDetectorService {
  final Isolate _isolate;
  final SendPort _send;
  final ReceivePort _receive;
  final Map<int, Completer<Map>> _pending;
  int _nextId = 0;

  /// Descripción del backend usado ("GPU" o "CPU (4 hilos)").
  final String delegate;
  final List<int> inputShape, outputShape;

  YoloDetectorService._(this._isolate, this._send, this._receive,
      this._pending, this.delegate, this.inputShape, this.outputShape);

  bool get isBusy => _pending.isNotEmpty;

  /// Nombre del archivo de modelo cargado.
  String modelName = '';

  /// La GPU no respondió y se cargó en CPU.
  bool gpuFallback = false;

  /// Carga [asset]; si no existe (variante no incluida) usa el modelo base.
  static Future<YoloDetectorService> create(
      {bool useGpu = false,
      // 3 hilos: casi igual de rápido que 4 y el teléfono sigue fluido.
      int threads = 3,
      String asset = defaultModelAsset}) async {
    ByteData data;
    var used = asset;
    try {
      data = await rootBundle.load(asset);
    } catch (_) {
      used = defaultModelAsset;
      data = await rootBundle.load(defaultModelAsset);
    }
    final receive = ReceivePort();
    final pending = <int, Completer<Map>>{};
    final sendPort = Completer<SendPort>();
    receive.listen((msg) {
      if (msg is SendPort) {
        sendPort.complete(msg);
      } else if (msg is Map) {
        pending.remove(msg['id'])?.complete(msg);
      }
    });
    final isolate =
        await Isolate.spawn(_workerMain, receive.sendPort, debugName: 'yolo');
    final send = await sendPort.future;

    final initDone = Completer<Map>();
    pending[-1] = initDone;
    send.send({
      'id': -1,
      'op': 'init',
      'model': TransferableTypedData.fromList(
          [data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes)]),
      'gpu': useGpu,
      'threads': threads,
    });
    // Con algunos modelos el driver de la GPU se queda compilando para
    // siempre (visto en el Galaxy A35): si no responde a tiempo se abandona
    // y se carga en CPU.
    final r = await initDone.future.timeout(
      Duration(seconds: useGpu ? 15 : 90),
      onTimeout: () => {'ok': false, 'error': 'timeout', 'timeout': true},
    );
    if (r['ok'] != true) {
      isolate.kill(priority: Isolate.immediate);
      receive.close();
      if (useGpu) {
        final cpu = await create(useGpu: false, threads: threads, asset: asset);
        cpu.gpuFallback = true;
        return cpu;
      }
      throw Exception('No se pudo cargar el modelo: ${r['error']}');
    }
    return YoloDetectorService._(
      isolate,
      send,
      receive,
      pending,
      r['delegate'] as String,
      (r['in'] as List).cast<int>(),
      (r['out'] as List).cast<int>(),
    )..modelName = used.split('/').last;
  }

  /// Foto de evidencia del último fotograma analizado, con las cajas, sus
  /// etiquetas y [stamp] (fecha/hora) dibujados. JPEG de [width] px de ancho.
  Future<Uint8List?> snapshot(List<SnapBox> boxes,
      {required String stamp, int width = 540}) async {
    final id = _nextId++;
    final c = Completer<Map>();
    _pending[id] = c;
    _send.send({
      'id': id,
      'op': 'snapshot',
      'w': width,
      'stamp': stamp,
      'boxes': [for (final b in boxes) b.toMap()],
    });
    final r = await c.future;
    if (r['ok'] != true) return null;
    return r['jpg'] as Uint8List;
  }

  Future<DetectionOutput> _request(Map<String, Object?> msg) async {
    final id = _nextId++;
    final c = Completer<Map>();
    _pending[id] = c;
    _send.send({...msg, 'id': id});
    final r = await c.future;
    if (r['ok'] != true) throw Exception(r['error']);
    return DetectionOutput(
      Detection.fromFlat(r['dets'] as Float32List),
      r['w'] as int,
      r['h'] as int,
      r['pre'] as double,
      r['infer'] as double,
      r['post'] as double,
    );
  }

  /// [rotation]: grados horarios para poner derecho el fotograma (en vertical
  /// es `sensorOrientation`). [mirror]: true en la cámara frontal para que las
  /// coordenadas coincidan con la vista previa espejada.
  Future<DetectionOutput> detectCameraImage(CameraImage img,
      {required int rotation,
      required bool mirror,
      required double confidence,
      required double iou}) {
    return _request({
      'op': 'yuv',
      'w': img.width,
      'h': img.height,
      'planes': [
        for (final p in img.planes)
          {
            'bytes': TransferableTypedData.fromList([p.bytes]),
            'row': p.bytesPerRow,
            'pix': p.bytesPerPixel,
          }
      ],
      'rot': rotation,
      'mirror': mirror,
      'conf': confidence,
      'iou': iou,
    });
  }

  Future<DetectionOutput> detectRgba(Uint8List rgba, int width, int height,
      {required double confidence,
      required double iou,
      int rotation = 0,
      bool mirror = false}) {
    return _request({
      'op': 'rgba',
      'w': width,
      'h': height,
      'rot': rotation,
      'mirror': mirror,
      'bytes': TransferableTypedData.fromList([rgba]),
      'conf': confidence,
      'iou': iou,
    });
  }

  void dispose() {
    _send.send({'id': -2, 'op': 'close'});
    for (final c in _pending.values) {
      c.complete({'ok': false, 'error': 'Detector cerrado'});
    }
    _pending.clear();
    _receive.close();
    // El worker sale solo tras cerrar el intérprete; esto es por si no responde.
    Future.delayed(const Duration(seconds: 2), _isolate.kill);
  }
}

// ---------------------------------------------------------------------------
// Isolate de inferencia
// ---------------------------------------------------------------------------

void _workerMain(SendPort main) {
  final port = ReceivePort();
  main.send(port.sendPort);

  Interpreter? interpreter;
  late Float32List input;
  late int inW, inH;
  late bool nchw;
  late List<int> outShape;
  // Modelos cuantizados (int8/uint8): parámetros de (de)cuantización.
  TensorType inType = TensorType.float32, outType = TensorType.float32;
  double inScale = 1, outScale = 1;
  int inZero = 0, outZero = 0;
  Uint8List? quantIn;

  // Último fotograma (para las fotos de evidencia): sabe dibujarse derecho
  // a cualquier tamaño.
  Letterbox Function(Float32List out, int w, int h)? lastRender;
  var lastUpW = 0, lastUpH = 0;

  Map<String, Object?> runInference(Letterbox Function() fill, Map m) {
    final sw = Stopwatch()..start();
    final lb = fill();
    final pre = sw.elapsedMicroseconds / 1000;

    sw.reset();
    if (quantIn == null) {
      interpreter!.getInputTensor(0).data = input.buffer.asUint8List();
    } else {
      // q = v / escala + cero, recortado al rango del tipo.
      final q = quantIn!;
      final signed = inType == TensorType.int8;
      for (var i = 0; i < input.length; i++) {
        var v = (input[i] / inScale).round() + inZero;
        v = signed ? v.clamp(-128, 127) : v.clamp(0, 255);
        q[i] = v & 0xFF;
      }
      interpreter!.getInputTensor(0).data = q;
    }
    interpreter!.invoke();
    final raw = interpreter!.getOutputTensor(0).data;
    final infer = sw.elapsedMicroseconds / 1000;

    sw.reset();
    final Float32List out;
    if (outType == TensorType.float32) {
      out = Float32List(raw.lengthInBytes ~/ 4);
      out.buffer.asUint8List().setAll(0, raw);
    } else {
      final signed = outType == TensorType.int8;
      out = Float32List(raw.length);
      for (var i = 0; i < raw.length; i++) {
        final q = signed && raw[i] > 127 ? raw[i] - 256 : raw[i];
        out[i] = (q - outZero) * outScale;
      }
    }
    final dets = decodeYolo(out, outShape, lb,
        confidence: m['conf'] as double, iou: m['iou'] as double);
    final post = sw.elapsedMicroseconds / 1000;

    return {
      'ok': true,
      'dets': dets,
      'w': lb.srcW,
      'h': lb.srcH,
      'pre': pre,
      'infer': infer,
      'post': post,
    };
  }

  port.listen((msg) {
    final m = msg as Map;
    final id = m['id'];
    try {
      switch (m['op']) {
        case 'init':
          final model =
              (m['model'] as TransferableTypedData).materialize().asUint8List();
          String delegate;
          if (m['gpu'] == true) {
            try {
              interpreter = Interpreter.fromBuffer(model,
                  options: InterpreterOptions()..addDelegate(GpuDelegateV2()));
            } catch (_) {
              interpreter = null;
            }
          }
          if (interpreter == null) {
            final threads = m['threads'] as int;
            interpreter = Interpreter.fromBuffer(model,
                options: InterpreterOptions()..threads = threads);
            delegate = m['gpu'] == true
                ? 'CPU ($threads hilos, GPU no disponible)'
                : 'CPU ($threads hilos)';
          } else {
            delegate = 'GPU';
          }

          final inT = interpreter!.getInputTensor(0);
          inType = inT.type;
          if (inType != TensorType.float32 &&
              inType != TensorType.int8 &&
              inType != TensorType.uint8) {
            throw StateError('Entrada ${inT.type} no soportada.');
          }
          if (inType != TensorType.float32) {
            inScale = inT.params.scale;
            inZero = inT.params.zeroPoint;
          }
          final outT = interpreter!.getOutputTensor(0);
          outType = outT.type;
          if (outType != TensorType.float32) {
            outScale = outT.params.scale;
            outZero = outT.params.zeroPoint;
          }
          final s = inT.shape; // [1,3,H,W] o [1,H,W,3]
          nchw = s[1] == 3;
          inH = nchw ? s[2] : s[1];
          inW = nchw ? s[3] : s[2];
          input = Float32List(inW * inH * 3);
          quantIn = inType == TensorType.float32
              ? null
              : Uint8List(inW * inH * 3);
          outShape = interpreter!.getOutputTensor(0).shape;
          main.send({
            'id': id,
            'ok': true,
            'delegate': delegate,
            'in': s,
            'out': outShape,
          });

        case 'yuv':
          final planes = (m['planes'] as List).cast<Map>();
          Uint8List bytes(int i) => (planes[i]['bytes'] as TransferableTypedData)
              .materialize()
              .asUint8List();
          final w = m['w'] as int, h = m['h'] as int;
          final Yuv420Frame frame;
          if (planes.length == 1) {
            frame = Yuv420Frame.nv21(bytes(0), w, h, planes[0]['row'] as int);
          } else {
            frame = Yuv420Frame(
              width: w,
              height: h,
              y: bytes(0),
              u: bytes(1),
              v: bytes(2),
              yRowStride: planes[0]['row'] as int,
              uvRowStride: planes[1]['row'] as int,
              uvPixelStride: (planes[1]['pix'] as int?) ?? 1,
            );
          }
          final rot = m['rot'] as int, mir = m['mirror'] as bool;
          lastRender = (out, ow, oh) => fillInputFromYuv(frame, out,
              inW: ow, inH: oh, nchw: false, rotation: rot, mirror: mir);
          (lastUpW, lastUpH) = rot == 90 || rot == 270 ? (h, w) : (w, h);
          main.send({
            'id': id,
            ...runInference(
                () => fillInputFromYuv(frame, input,
                    inW: inW,
                    inH: inH,
                    nchw: nchw,
                    rotation: m['rot'] as int,
                    mirror: m['mirror'] as bool),
                m),
          });

        case 'rgba':
          final rgba =
              (m['bytes'] as TransferableTypedData).materialize().asUint8List();
          final rw = m['w'] as int, rh = m['h'] as int;
          final rot = m['rot'] as int, mir = m['mirror'] as bool;
          lastRender = (out, ow, oh) => fillInputFromRgba(rgba, rw, rh, out,
              inW: ow, inH: oh, nchw: false, rotation: rot, mirror: mir);
          (lastUpW, lastUpH) = rot == 90 || rot == 270 ? (rh, rw) : (rw, rh);
          main.send({
            'id': id,
            ...runInference(
                () => fillInputFromRgba(
                    rgba, m['w'] as int, m['h'] as int, input,
                    inW: inW,
                    inH: inH,
                    nchw: nchw,
                    rotation: m['rot'] as int,
                    mirror: m['mirror'] as bool),
                m),
          });

        case 'snapshot':
          final render = lastRender;
          if (render == null) throw StateError('Sin fotograma');
          final ow = m['w'] as int;
          final oh = (ow * lastUpH / lastUpW).round();
          final buf = Float32List(ow * oh * 3);
          render(buf, ow, oh);
          final rgb = Uint8List(buf.length);
          for (var i = 0; i < buf.length; i++) {
            rgb[i] = (buf[i] * 255).round().clamp(0, 255);
          }
          final pic = img.Image.fromBytes(
              width: ow, height: oh, bytes: rgb.buffer, numChannels: 3);
          for (final b in (m['boxes'] as List).cast<Map>()) {
            drawSnapBox(pic, SnapBox.fromMap(b));
          }
          drawStamp(pic, m['stamp'] as String);
          main.send({'id': id, 'ok': true, 'jpg': img.encodeJpg(pic, quality: 80)});

        case 'close':
          interpreter?.close();
          port.close();
          Isolate.exit();
      }
    } catch (e) {
      main.send({'id': id, 'ok': false, 'error': e.toString()});
    }
  });
}

/// Caja a dibujar en una foto de evidencia (coordenadas normalizadas).
class SnapBox {
  final double l, t, r, b;
  final String label;
  final int color; // 0xRRGGBB

  const SnapBox(this.l, this.t, this.r, this.b, this.label, this.color);

  Map<String, Object> toMap() =>
      {'l': l, 't': t, 'r': r, 'b': b, 'label': label, 'c': color};

  factory SnapBox.fromMap(Map m) => SnapBox(
      (m['l'] as num).toDouble(),
      (m['t'] as num).toDouble(),
      (m['r'] as num).toDouble(),
      (m['b'] as num).toDouble(),
      m['label'] as String,
      m['c'] as int);
}

void drawSnapBox(img.Image pic, SnapBox s) {
  final c = img.ColorRgb8((s.color >> 16) & 0xFF, (s.color >> 8) & 0xFF, s.color & 0xFF);
  final x1 = (s.l * pic.width).round(), y1 = (s.t * pic.height).round();
  final x2 = (s.r * pic.width).round(), y2 = (s.b * pic.height).round();
  img.drawRect(pic, x1: x1, y1: y1, x2: x2, y2: y2, color: c, thickness: 3);
  final tw = s.label.length * 9 + 10;
  final ty = (y1 - 20).clamp(0, pic.height - 20);
  img.fillRect(pic, x1: x1, y1: ty, x2: x1 + tw, y2: ty + 19, color: c);
  img.drawString(pic, s.label,
      font: img.arial14, x: x1 + 4, y: ty + 2, color: img.ColorRgb8(0, 0, 0));
}

/// Banda inferior con la fecha y hora (prueba de cuándo se tomó).
void drawStamp(img.Image pic, String stamp) {
  img.fillRect(pic,
      x1: 0,
      y1: pic.height - 24,
      x2: pic.width,
      y2: pic.height,
      color: img.ColorRgba8(0, 0, 0, 170));
  img.drawString(pic, stamp,
      font: img.arial14, x: 8, y: pic.height - 20, color: img.ColorRgb8(255, 255, 255));
}
