# Cámara ESP32 (Taxiff Cam)

Placa ESP32-S3 con cámara OV3660, 16 MB de flash y 8 MB de PSRAM (tipo ESP32-S3-EYE / Freenove S3 CAM). Va fija en el taxi, arriba, cerca del retrovisor, mirando a la cabina.

## Qué hace

- **Detecta cabezas** con un modelo FOMO propio (Edge Impulse, 160×160 en gris): unos 420 ms por foto, unas 2 fotos por segundo. También puede usar el detector de caras de Espressif.
- **Lleva su propia lógica de carrera** (LIBRE → CONFIRMANDO → EN CARRERA) para mostrarla en su página. La que vale es la del servidor.
- **Envía fotos al servidor:** una cada 5 s con la cabina vacía y una por segundo con pasajeros (el ritmo lo indica el servidor). Sin internet, las guarda en su memoria (9 MB) y las sube después, las más viejas primero.
- **Se actualiza sola por internet** cuando se publica un firmware nuevo en el servidor. Si una versión falla 3 veces, no la vuelve a intentar.
- **Página propia** en `http://<ip-de-la-cámara>` o `http://taxiff-cam.local`:
  - imagen en vivo;
  - ajustes (resolución, sensibilidad, orientación, modo noche);
  - temperatura y carga;
  - servidor;
  - fotos para entrenar.
- **Se protege sola:**
  - reinicia la cámara si deja de enviar imagen;
  - baja el ritmo si pasa de 80 °C;
  - vuelve a 320×240 si se colgó con una resolución mayor;
  - guarda el historial de reinicios para diagnosticar fallos.

Cada cámara se identifica por su **ID de fábrica** (`TX-XXXXXX`, sale de la MAC del chip) y un **token** que recibe al registrarse en el servidor.

## Compilar y cargar

Requisitos:
- [arduino-cli](https://arduino.github.io/arduino-cli/).
- Core `esp32:esp32@2.0.17`.
- La librería del modelo instalada una vez:

```powershell
arduino-cli core install esp32:esp32@2.0.17
# Librería del modelo de cabezas (exportada de Edge Impulse):
Expand-Archive esp32\firmware\librerias\ei-taxiff-cabezas-v2-arduino-1.0.1.zip "$HOME\Documents\Arduino\libraries"
```

Compilar:

```powershell
$fq = "esp32:esp32:esp32s3:PSRAM=opi,FlashSize=16M,PartitionScheme=app3M_fat9M_16MB,CDCOnBoot=default"
arduino-cli compile -b $fq --output-dir build_esp32 esp32\firmware\taxiff_cam
```

Primera carga por cable, desde el puerto **UART**. El puerto OTG se reinicia al abrirlo. `arduino-cli upload` falla con esta placa, así que se usa esptool:

```powershell
esptool --chip esp32s3 --port COM4 --baud 460800 write_flash -z --flash_mode dio --flash_freq 80m --flash_size 16MB `
  0x0 build_esp32\taxiff_cam.ino.bootloader.bin 0x8000 build_esp32\taxiff_cam.ino.partitions.bin `
  0xe000 <core>\tools\partitions\boot_app0.bin 0x10000 build_esp32\taxiff_cam.ino.bin
```

Para cargar una versión nueva **en todas las cámaras por internet**:
1. Sube `FW_VERSION` en `taxiff_cam.ino`.
2. Compila.
3. En el panel del servidor, sección "Firmware de las cámaras", sube `taxiff_cam.ino.bin` con esa versión.

## Configurar una cámara

1. **WiFi:**
   - Si no conoce ninguna red, la cámara crea la red `Taxiff-Cam` (clave `taxiff123`). Conéctate y abre `http://192.168.4.1/wifi`.
   - Por cable (puerto serie, 115200): `WIFI <red><TAB><clave>`.
   - En el taxi, se usa el **hotspot del teléfono del conductor**, que tiene que estar en **2.4 GHz**.
2. **Servidor:** en la página de la cámara, sección "Servidor Taxiff", escribe la dirección (por ejemplo `https://taxiff.midominio.com`). Por cable: `SERVER <url>`.
3. **Panel del servidor:**
   - La cámara aparece sola. Si el servidor no aprueba solo, apruébala.
   - Ponle el nombre del taxi.
   - **Dibuja la jaula**: las esquinas de la cabina. Solo cuenta a quien esté dentro.

Otros comandos por cable: `SCAN` (redes visibles), `RESETLOG` (borra el historial de reinicios).

## Herramientas (`herramientas/`)

| Script | Para qué |
|---|---|
| `descargar_fotos.ps1 <ip> [-Borrar]` | Baja las fotos de entrenamiento guardadas en la cámara a `datos/fotos_taxi/`. |
| `fotos_de_video.ps1 -Video <mp4> -Out <carpeta>` | Saca fotos limpias de una grabación de la página de la cámara. Recorta la imagen y descarta las que tienen recuadros dibujados o se repiten. |
| `dataset_v2.ps1` | Arma el dataset para Edge Impulse desde el export YOLOv8 de Roboflow. Agrega versiones con calidad tipo ESP32 y giradas 180°. |
| `verificar_dataset.ps1 -Dataset <carpeta>` | Dibuja las cajas en un mosaico y revisa que el dataset no tenga errores. |

## Modelo de cabezas

Proyecto de Edge Impulse **taxiff-cabezas-v2**:
- FOMO MobileNetV2 0.35, 160×160 en gris, resize "Squash".
- Dataset: 438 fotos etiquetadas en Roboflow + 50 de la propia cámara, ×5 versiones.
- Validación (int8): precisión 0.87, recall 0.87.

El firmware une detecciones cercanas de la misma cabeza antes de contar (ajuste "Unir detecciones cercanas").

Para mejorarlo, junta fotos reales del taxi con "Guardar automáticamente" en la página de la cámara, etiquétalas en Roboflow, regenera el dataset y vuelve a entrenar.
