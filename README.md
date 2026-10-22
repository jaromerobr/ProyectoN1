# Taxiff

Sistema para contar pasajeros y registrar las carreras de un taxi de forma automática.

Tiene tres partes que se pueden usar por separado o juntas:

| Parte | Qué hace | Carpeta |
|---|---|---|
| **App Android** | Usa la cámara del teléfono. Cuenta pasajeros con YOLO en el propio teléfono, sin internet, y guarda carreras, fotos de evidencia y reportes. | raíz (`lib/`, `android/`, `assets/`) · [docs/app.md](docs/app.md) |
| **Cámara ESP32** | Equipo barato (ESP32-S3 + OV3660) que va fijo en el taxi. Detecta cabezas con un modelo propio (FOMO) y envía fotos al servidor. Sin señal, las guarda y las sube después. | [esp32/](esp32/README.md) |
| **Servidor** | Recibe las fotos de todas las cámaras, cuenta con YOLO, aplica la jaula de cada taxi, arma las carreras y muestra todo en un panel web. También actualiza el firmware de las cámaras por internet. | [servidor/](servidor/README.md) |

```text
Cámara ESP32 (taxi) ──WiFi──► hotspot del taxista ──4G──► Servidor ──► Panel web
```

## Estructura del repositorio

```text
.
├── lib/ android/ test/ assets/   App Android (Flutter)
├── pubspec.yaml
├── esp32/
│   ├── firmware/taxiff_cam/      Programa de la cámara (Arduino)
│   ├── firmware/librerias/       Modelo de cabezas exportado de Edge Impulse
│   └── herramientas/             Scripts: datasets, verificación, fotos de la cámara
├── servidor/
│   ├── app.py                    API + lógica de carreras + panel
│   ├── web/                      Panel web
│   ├── tests/                    Pruebas automáticas
│   └── Dockerfile, docker-compose.yml, Caddyfile   Despliegue
├── modelos/best.pt               YOLO de personas (lo usa el servidor)
└── docs/                         Documentación y plan
```

**Fuera del repositorio** (solo en la PC, ver `.gitignore`):
- Datasets, fotos y videos: `esp32/datos/`.
- Datos del servidor (base de datos, fotos de las cámaras, firmware publicado): `servidor/datos/`.
- Entorno de Python: `servidor/.venv/`.
- Claves: `servidor/.env`.
- Compilaciones: `build/`, `.dart_tool/`.

## Empezar

**Paso a paso para levantar el servidor y conectar la cámara:** [docs/GUIA_RAPIDA.md](docs/GUIA_RAPIDA.md).

- **App:** `flutter pub get` y `flutter run`. Ver [docs/app.md](docs/app.md).
- **Servidor en la PC (pruebas):** `servidor\iniciar_pc.ps1`. Ver [servidor/README.md](servidor/README.md).
- **Cámara:** compilar y cargar el firmware. Ver [esp32/README.md](esp32/README.md).

El estado del proyecto y los próximos pasos están en [docs/PLAN.md](docs/PLAN.md).
