# Servidor Taxiff

API en Python (FastAPI). Recibe las fotos de las cámaras, cuenta pasajeros con YOLO (`../modelos/best.pt`), aplica la jaula de cada taxi, arma las carreras y sirve el panel web.

## Probar en la PC

Una sola vez:

```powershell
cd servidor
py -3.12 -m venv .venv
.venv\Scripts\python -m pip install torch torchvision --index-url https://download.pytorch.org/whl/cpu
.venv\Scripts\python -m pip install -r requirements-dev.txt
```

Arrancar:

```powershell
.\iniciar_pc.ps1                         # solo en tu WiFi: http://<ip-de-la-pc>:8000
.\iniciar_pc.ps1 -Tunel                  # + dirección pública https (para probar en el taxi con datos móviles)
.\iniciar_pc.ps1 -Tunel -Esp 192.168.1.61   # y además configura esa cámara para usarla
```

- **Panel:** `http://localhost:8000`. Pide entrar en `/entrar`, con el usuario `admin` y la clave `TAXIFF_CLAVE_PANEL` (por defecto `taxiff`).
- **Dueños:** el admin les crea cuentas en el panel (sección "Dueños") y les asigna sus taxis. Cada dueño entra con su usuario y ve `/dueno`: sus carreras, con el cobro y los km estimados, y su odómetro. No ve fotos ni la cámara.
- **Scripts:** HTTP Basic con la clave del panel sigue funcionando (`admin:<clave>`).
- **Dirección del túnel gratuito:** cambia cada vez que se arranca. Para algo fijo, usa un servidor en la nube (abajo).

Pruebas automáticas (no necesitan cámara ni modelo):

```powershell
.venv\Scripts\python -m pytest -q
```

Simular una cámara (sin ESP32):

```powershell
.\pruebas\simular_camara.ps1 -Id TX-PRUEBA1
```

## Desplegar en un servidor (producción)

Hace falta:
- **Un VPS Linux con Docker.** Sirve uno de 2 vCPU y 4 GB de RAM: Hetzner CX22 (unos 5 € al mes), DigitalOcean, o Oracle Cloud Free Tier (ARM, gratis).
- **Un dominio** apuntando a la IP del VPS, por ejemplo `taxiff.midominio.com`.

Pasos:

```bash
git clone <repositorio> && cd <repositorio>/servidor
./preparar_docker.sh          # copia el modelo y crea .env
nano .env                     # TAXIFF_CLAVE_PANEL, TAXIFF_AUTO_APROBAR=0, DOMINIO
docker compose up -d --build  # servidor + HTTPS automático (Caddy + Let's Encrypt)
```

Después:
1. Abre `https://<dominio>`.
2. En cada cámara, configura el servidor `https://<dominio>`.
3. Aprueba cada cámara en el panel y dibuja su jaula.

**Copias de seguridad:** todo vive en `servidor/datos/` (`taxiff.db`, `fotos/`, `firmware/`). Basta con copiar esa carpeta, por ejemplo cada noche con `cron` y `rclone` a otro almacenamiento.

## Configuración (`.env`)

| Variable | Por defecto | Qué hace |
|---|---|---|
| `TAXIFF_CLAVE_PANEL` | `taxiff` | Clave del panel. **Cambiarla.** |
| `TAXIFF_AUTO_APROBAR` | `1` | `1`: las cámaras nuevas quedan aprobadas solas. En producción, `0`. |
| `TAXIFF_CONF` | `0.35` | Confianza mínima de YOLO. |
| `TAXIFF_DATOS` | `servidor/datos` | Dónde se guardan la base de datos, las fotos y el firmware. |
| `TAXIFF_MODELO` | `modelos/best.pt` | Modelo YOLO. |
| `DOMINIO` | – | Dominio público (solo docker-compose). |

## API de las cámaras

| Método | Ruta | Qué hace |
|---|---|---|
| POST | `/api/v1/registro` | `{"id": "TX-…", "fw": "1.9"}` → `{"token": …}`. Una vez por cámara. Para registrarla de nuevo, se permite en el panel. |
| POST | `/api/v1/foto` | JPEG en el cuerpo. Cabeceras: `X-Dispositivo`, `Authorization: Bearer <token>`, `X-Ts` (hora de la foto), `X-Conteo` (lo que vio la cámara), `X-Temp`, `X-Rssi`, `X-Fw`. Responde `modo`, `intervalo_ms`, `pasajeros`, `estado` y `firmware` (la versión más nueva). |
| GET | `/api/v1/firmware?id=&token=&actual=` | Dice si hay firmware nuevo y dónde bajarlo. |
| POST | `/api/v1/posiciones` | Para cuando haya GPS (hoy nadie lo usa): `[[ts, lat, lon], …]` con las cabeceras `X-Dispositivo` y `Authorization` de siempre. Con posiciones, los km y el mapa de cada carrera salen del recorrido real. |
| GET | `/api/salud` | Para el monitoreo. |

**Lógica de carrera:**
- El conteo es la mediana de las 3 últimas fotos.
- La carrera empieza cuando hay pasajero durante 3 s.
- Termina tras 10 s sin nadie.
- Si dura menos de 30 s se guarda como **descartada**.
- Si la cámara deja de enviar durante una carrera, se cierra a los 15 min.

**Fotos:** las que no son evidencia de una carrera se borran a las 24 h.
