# App Android (Flutter)

Cuenta pasajeros en la cabina de un taxi con YOLOv11 en el propio teléfono y registra el tiempo de cada carrera sin internet. Los comandos se ejecutan desde la raíz del repositorio.

## Ejecutar

```bash
flutter pub get
flutter run            # con un teléfono Android conectado (depuración USB)
flutter test           # pruebas de ROI, cronómetro y pre/post-procesado
```

Para el modo simulación, copia un vídeo a `assets/video_prueba.mp4`, o elígelo desde la galería dentro de la app.

## Estructura

```text
lib/
├── main.dart
├── models/
│   ├── detection.dart            # caja normalizada + rol (conductor/pasajero)
│   ├── trip_record.dart          # fila de la bitácora
│   └── app_settings.dart         # ajustes persistentes (shared_preferences)
├── services/
│   ├── yolo_detector_service.dart  # intérprete TFLite en un isolate propio
│   ├── detection_session.dart      # detector + ROI + cronómetro + guardado
│   ├── video_frame_source.dart     # fotogramas de vídeo vía canal nativo
│   └── database_helper.dart        # SQLite (sqflite)
├── utils/
│   ├── roi_evaluator.dart        # regla del centroide
│   ├── trip_tracker.dart         # máquina de estados de la carrera
│   ├── yolo_image_ops.dart       # YUV/RGBA → tensor (letterbox) y NMS
│   └── format.dart
├── widgets/
│   ├── detection_view.dart       # overlay de cajas + zona arrastrable
│   └── trip_status_panel.dart
└── screens/
    ├── home_screen.dart
    ├── camera_detector_screen.dart
    ├── video_simulation_screen.dart
    ├── trip_history_screen.dart
    └── settings_screen.dart
android/app/src/main/kotlin/.../MainActivity.kt  # extractor de fotogramas
```

## Decisiones respecto a la especificación

- **Modelo**: `best.tflite` tiene entrada `[1,3,640,640]` (NCHW) y salida `[1,5,8400]` con coordenadas normalizadas. El código detecta NCHW o NHWC y si las coordenadas vienen normalizadas o en píxeles, así que funciona con otros exports de Ultralytics sin cambios.
- **Sin `video_player`**: no da acceso a los píxeles. El modo simulación extrae fotogramas con `MediaMetadataRetriever` (Kotlin) y usa **el tiempo del vídeo como reloj**. Así las duraciones son exactas aunque el teléfono analice más lento que el tiempo real, y las cajas siempre coinciden con el fotograma mostrado.
- **Isolate de inferencia**: el preprocesado (YUV→RGB, rotación, letterbox en una pasada), la inferencia y el NMS corren fuera del hilo de la UI. Los fotogramas que llegan mientras el modelo está ocupado se descartan.
- **Conductor por punto del asiento** (en lugar de la franja `Cx < 0.35`). Con la franja, el pasajero sentado detrás del conductor cae en la misma zona y no se cuenta. Ahora se toca al conductor en la imagen para marcar su asiento. Como mucho **una** persona es el conductor: la que cubre ese punto y tiene el centroide más cerca. Los demás son pasajeros. La regla original sigue disponible en Ajustes → Método → Franja.
- **Cronómetro**:
  - Un pasajero tiene que verse durante 1 s antes de abrir la carrera. Esto evita carreras fantasma por un falso positivo aislado. El inicio se fecha en el primer fotograma en que se vio al pasajero.
  - La carrera se cierra tras más de 5 s con 0 pasajeros. El fin se fecha en el primer fotograma vacío.
  - El máximo de pasajeros solo cuenta conteos que se repiten 3 fotogramas seguidos.
  - Todos estos valores se configuran en Ajustes.
- La pantalla de detección se fija en **vertical** y mantiene la pantalla encendida.

## Segundo plano

Al entrar al modo en vivo arranca `CaptureService.kt`, un servicio en primer plano de tipo cámara con una notificación fija. Si el conductor abre otra app (p. ej. Ktaxi) o apaga la pantalla, el plugin `camera` suelta la cámara y el servicio la abre con CameraX, sin vista previa. Dart sigue recogiendo los fotogramas por el canal `taxiff/background` y los analiza con el mismo pipeline. Al volver a la app, la cámara pasa de nuevo al plugin.

En Samsung conviene activar *Ajustes → Batería sin restricciones* para que el sistema no detenga el servicio.

## Capturas sin teléfono

```bash
flutter test test/ui_preview_test.dart   # genera build/previews/*.png con datos de ejemplo
```

## Rendimiento

El modelo es YOLOv11s en float32 (38 MB). En CPU, cada inferencia tarda varios cientos de ms según el teléfono. Para contar personas sentadas, 1–3 fps son suficientes. Si hace falta más velocidad:

```python
model.export(format="tflite", imgsz=320, half=True)   # o int8=True
```

El código lee el tamaño de entrada del modelo, así que no hay que cambiar nada más.
