"""Servidor Taxiff.

Recibe las fotos que envían las cámaras ESP32 de los taxis, cuenta pasajeros
con el modelo YOLO (modelos/best.pt), aplica la jaula de cada taxi, arma las
carreras y sirve el panel web.

Cada cámara se identifica por su ID de fábrica (TX-XXXXXX, sale de la MAC del
chip) y un token que recibe la primera vez que se registra.

Arranque:  .venv\\Scripts\\python -m uvicorn app:app --host 0.0.0.0 --port 8000
"""

import base64
import hashlib
import hmac
import json
import logging
import logging.handlers
import math
import os
import re
import secrets
import sqlite3
import statistics
import struct
import threading
import time
from collections import deque
from datetime import datetime, timedelta
from pathlib import Path
from urllib.parse import quote, unquote

from fastapi import Depends, FastAPI, Header, HTTPException, Request
from fastapi.responses import FileResponse, JSONResponse, RedirectResponse, Response
from fastapi.staticfiles import StaticFiles
from starlette.concurrency import run_in_threadpool

import diagnostico

BASE = Path(__file__).resolve().parent
WEB = BASE / "web"

# Configuración por variables de entorno (ver .env.example).
DATOS = Path(os.environ.get("TAXIFF_DATOS", BASE / "datos"))
MODELO = Path(os.environ.get("TAXIFF_MODELO", BASE.parent / "modelos" / "best.pt"))
CLAVE_PANEL = os.environ.get("TAXIFF_CLAVE_PANEL", "taxiff")
AUTO_APROBAR = os.environ.get("TAXIFF_AUTO_APROBAR", "1") == "1"
CONF_MIN = float(os.environ.get("TAXIFF_CONF", "0.35"))
FOTOS = DATOS / "fotos"
FIRMWARE = DATOS / "firmware"  # taxiff_cam-<versión>.bin: la más nueva se instala sola en las cámaras

# Lógica de carrera (los mismos tiempos que la app y el ESP32).
CONFIRMAR_S = 3      # pasajero visto este tiempo seguido => empieza la carrera
GRACIA_S = 20        # sin pasajeros este tiempo => termina (alguien que se agacha no corta la carrera)
MINIMO_S = 30        # carreras más cortas se guardan como descartadas
CAMBIO_S = 3         # un cambio en el conteo dura esto => alguien subió o bajó
HUECO_S = 10 * 60    # sin fotos este tiempo DENTRO de una carrera (cámara apagada) => se cierra
SIN_FOTOS_S = 15 * 60  # cámara callada (y sin fotos pendientes) en carrera => se cierra
MAX_ATRASO_S = 30 * 86400  # fotos guardadas sin internet hasta 30 días se aceptan con su hora
GUARDAR_FOTOS_H = int(os.environ.get("TAXIFF_GUARDAR_FOTOS_H", "72"))  # las que no son evidencia

FOTOS.mkdir(parents=True, exist_ok=True)
FIRMWARE.mkdir(parents=True, exist_ok=True)
LOGS = DATOS / "logs"
LOGS_CAMARAS = LOGS / "camaras"
LOGS_CAMARAS.mkdir(parents=True, exist_ok=True)

# Registro del servidor: datos/logs/servidor.log (rota a los 5 MB, guarda 10).
# Ahí quedan cámaras que se registran, lotes recibidos, carreras, cambios en el
# panel y errores. Los registros que mandan las cámaras van a datos/logs/camaras/.
log = logging.getLogger("taxiff")
if not log.handlers:
    _h = logging.handlers.RotatingFileHandler(LOGS / "servidor.log", maxBytes=5_000_000, backupCount=10,
                                              encoding="utf-8")
    _h.setFormatter(logging.Formatter("%(asctime)s %(levelname)-7s %(message)s", "%Y-%m-%d %H:%M:%S"))
    log.addHandler(_h)
    log.setLevel(logging.INFO)
    logging.getLogger("uvicorn.error").addHandler(_h)  # arranques y errores del servidor web

# ---------------------------------------------------------------- base de datos

_db = sqlite3.connect(DATOS / "taxiff.db", check_same_thread=False)
_db.row_factory = sqlite3.Row
_db_lock = threading.Lock()
with _db_lock:
    # WAL: escribir no frena a quien lee (y una copia de la base se puede leer mientras el servidor escribe).
    _db.execute("PRAGMA journal_mode=WAL")
    _db.executescript("""
    CREATE TABLE IF NOT EXISTS dispositivos (
        id TEXT PRIMARY KEY, token_hash TEXT, nombre TEXT DEFAULT '',
        aprobado INTEGER DEFAULT 0, jaula TEXT DEFAULT '[]', creado REAL,
        visto REAL, fw TEXT, rssi INTEGER, temp REAL, ultima_foto TEXT,
        pax INTEGER DEFAULT 0, pax_esp INTEGER DEFAULT 0, estado TEXT DEFAULT 'LIBRE',
        fotos_recibidas INTEGER DEFAULT 0);
    CREATE TABLE IF NOT EXISTS carreras (
        id INTEGER PRIMARY KEY AUTOINCREMENT, dispositivo TEXT, inicio REAL,
        fin REAL, duracion REAL, max_pax INTEGER, valida INTEGER, fotos TEXT);
    CREATE INDEX IF NOT EXISTS carreras_disp ON carreras(dispositivo, inicio);
    CREATE TABLE IF NOT EXISTS estado_carreras (dispositivo TEXT PRIMARY KEY, datos TEXT);
    CREATE TABLE IF NOT EXISTS eventos (
        id INTEGER PRIMARY KEY AUTOINCREMENT, dispositivo TEXT, recibido REAL,
        origen TEXT, nivel TEXT, texto TEXT);
    CREATE INDEX IF NOT EXISTS eventos_disp ON eventos(dispositivo, id);
    CREATE TABLE IF NOT EXISTS duenos (
        id INTEGER PRIMARY KEY AUTOINCREMENT, usuario TEXT UNIQUE, nombre TEXT DEFAULT '',
        clave TEXT, activo INTEGER DEFAULT 1, creado REAL, entro REAL);
    CREATE TABLE IF NOT EXISTS odometro (
        id INTEGER PRIMARY KEY AUTOINCREMENT, dispositivo TEXT, fecha REAL, km REAL,
        nota TEXT DEFAULT '', anotado REAL, por TEXT);
    CREATE INDEX IF NOT EXISTS odometro_disp ON odometro(dispositivo, fecha);
    CREATE TABLE IF NOT EXISTS posiciones (
        dispositivo TEXT, ts REAL, lat REAL, lon REAL, PRIMARY KEY (dispositivo, ts));
    CREATE TABLE IF NOT EXISTS mantenimiento (
        id INTEGER PRIMARY KEY AUTOINCREMENT, dispositivo TEXT, nombre TEXT, cada_km REAL,
        ultimo_km REAL, creado REAL);
    CREATE TABLE IF NOT EXISTS turnos (
        id INTEGER PRIMARY KEY AUTOINCREMENT, dispositivo TEXT, nombre TEXT, desde INTEGER, hasta INTEGER);
    CREATE TABLE IF NOT EXISTS alertas (
        id INTEGER PRIMARY KEY AUTOINCREMENT, dispositivo TEXT, ts REAL, tipo TEXT, titulo TEXT, texto TEXT);
    CREATE INDEX IF NOT EXISTS alertas_disp ON alertas(dispositivo, ts);
    CREATE TABLE IF NOT EXISTS config (clave TEXT PRIMARY KEY, valor TEXT);
    CREATE TABLE IF NOT EXISTS gastos (
        id INTEGER PRIMARY KEY AUTOINCREMENT, dispositivo TEXT, fecha TEXT, categoria TEXT, descripcion TEXT DEFAULT '',
        monto REAL, km REAL, pago TEXT DEFAULT '', lugar TEXT DEFAULT '', creado REAL, por TEXT);
    CREATE INDEX IF NOT EXISTS gastos_disp ON gastos(dispositivo, fecha);
    CREATE TABLE IF NOT EXISTS recordatorios (
        id INTEGER PRIMARY KEY AUTOINCREMENT, dispositivo TEXT, nombre TEXT, categoria TEXT, monto REAL,
        frecuencia TEXT, proxima TEXT, creado REAL);
    """)
    # Liquidaciones: una por día y turno (0 = sin turnos), con su fuente:
    # "chofer" (lo que dijo) o "taximetro" (lectura del aparato; solo esas calibran).
    # La primera versión (26/10/2026) era una por día, sin turno ni fuente: se pasa a la nueva.
    _cols = [r[1] for r in _db.execute("PRAGMA table_info(reportes)")]
    if _cols and "turno" not in _cols:
        _db.execute("ALTER TABLE reportes RENAME TO reportes_v1")
    _db.executescript("""
    CREATE TABLE IF NOT EXISTS reportes (
        dispositivo TEXT, dia TEXT, turno INTEGER DEFAULT 0, monto REAL, fuente TEXT DEFAULT 'chofer',
        nota TEXT DEFAULT '', anotado REAL, por TEXT, PRIMARY KEY (dispositivo, dia, turno));
    """)
    if _cols and "turno" not in _cols:
        _db.execute("INSERT INTO reportes (dispositivo, dia, turno, monto, fuente, nota, anotado, por) "
                    "SELECT dispositivo, dia, 0, monto, 'chofer', nota, anotado, por FROM reportes_v1")
        _db.execute("DROP TABLE reportes_v1")
    _db.commit()
    # Columnas agregadas después (bases de datos ya creadas).
    for tabla, col in (("dispositivos", "cola INTEGER DEFAULT 0"),
                       ("dispositivos", "ajustes TEXT DEFAULT '{}'"), ("dispositivos", "ajustes_ver INTEGER DEFAULT 0"),
                       ("dispositivos", "cfg_camara TEXT"), ("dispositivos", "ajustes_aplicados INTEGER DEFAULT 0"),
                       ("dispositivos", "ip_local TEXT"), ("dispositivos", "contacto REAL"),
                       ("dispositivos", "cola_max INTEGER DEFAULT 0"),
                       ("dispositivos", "contar_con_wifi INTEGER DEFAULT 0"),
                       ("dispositivos", "dueno INTEGER"), ("dispositivos", "tarifa TEXT DEFAULT '{}'"),
                       ("dispositivos", "redes TEXT"), ("dispositivos", "red_actual TEXT"),
                       ("dispositivos", "wifi_olvidar TEXT DEFAULT '[]'"), ("dispositivos", "abrir_portal INTEGER DEFAULT 0"),
                       ("dispositivos", "wifi_orden INTEGER DEFAULT 0"),
                       ("turnos", "cuenta REAL"), ("reportes", "entregado REAL"),
                       ("carreras", "pasajeros INTEGER"), ("carreras", "eventos TEXT"),
                       ("carreras", "revisar INTEGER DEFAULT 0"), ("carreras", "con_wifi INTEGER DEFAULT 0")):
        try:
            _db.execute(f"ALTER TABLE {tabla} ADD COLUMN {col}")
        except sqlite3.OperationalError:
            pass  # ya existe


def db(sql, args=(), one=False):
    with _db_lock:
        cur = _db.execute(sql, args)
        _db.commit()
        rows = cur.fetchall()
    rows = [dict(r) for r in rows]
    return (rows[0] if rows else None) if one else rows


def hash_token(t):
    return hashlib.sha256(t.encode()).hexdigest()


_PALABRAS_ERROR = ("FALLO", "falló", "error", "no se pudo", "perdido", "colgado", "CORRIENTE",
                   "caliente", "no revive", "dañad")
_PALABRAS_AVISO = ("sin internet", "SIN WiFi", "pendiente", "reintent", "reconect", "llena", "reinici",
                   "no responde", "WiFi caída")


def nivel_de(texto):
    """error / aviso / info según el contenido de la línea (para colorear y filtrar)."""
    valores = diagnostico.estado(texto)
    if valores:  # línea de estado de cada minuto: aviso si algún valor está mal
        return "aviso" if any(v["mal"] for v in valores) else "info"
    regla = diagnostico.explicar(texto)  # líneas conocidas: el nivel de su explicación
    if regla["que"] != "Mensaje informativo.":
        return regla["gravedad"]
    if any(p.lower() in texto.lower() for p in _PALABRAS_ERROR):
        return "error"
    if "ARRANQUE" in texto and not any(r in texto for r in ("encendido normal", "reinicio por software")):
        return "error"  # arrancó por un fallo, un cuelgue o falta de corriente
    if any(p.lower() in texto.lower() for p in _PALABRAS_AVISO) or "ARRANQUE" in texto:
        return "aviso"
    return "info"


def evento(disp, texto, origen="servidor", nivel=None):
    """Anota un evento de una cámara: en la base (para el panel), en
    datos/logs/camaras/<id>.log (para revisar con un editor) y en servidor.log."""
    nivel = nivel or nivel_de(texto)
    ahora = time.time()
    db("INSERT INTO eventos (dispositivo, recibido, origen, nivel, texto) VALUES (?, ?, ?, ?, ?)",
       (disp, ahora, origen, nivel, texto[:500]))
    with open(LOGS_CAMARAS / f"{disp}.log", "a", encoding="utf-8") as f:
        f.write(f"{datetime.fromtimestamp(ahora):%Y-%m-%d %H:%M:%S} [{origen}] [{nivel}] {texto}\n")
    getattr(log, {"error": "error", "aviso": "warning"}.get(nivel, "info"))(f"{disp} [{origen}] {texto}")

# ---------------------------------------------------------------- detector

_modelo = None
_modelo_lock = threading.Lock()


def detectar(ruta):
    """Personas en la foto: [[x1, y1, x2, y2, confianza], ...] normalizado 0-1."""
    global _modelo
    with _modelo_lock:
        if _modelo is None:
            from ultralytics import YOLO
            _modelo = YOLO(str(MODELO))
        r = _modelo.predict(str(ruta), imgsz=416, conf=CONF_MIN, device="cpu", verbose=False)[0]
    cajas = r.boxes.xyxyn.tolist()
    confs = r.boxes.conf.tolist()
    return [[round(v, 4) for v in c] + [round(p, 3)] for c, p in zip(cajas, confs)]


def dentro_de_jaula(x, y, jaula):
    """Ray casting: ¿el punto (x, y) cae dentro del polígono? Sin jaula, todo cuenta."""
    if len(jaula) < 3:
        return True
    dentro = False
    j = len(jaula) - 1
    for i in range(len(jaula)):
        xi, yi = jaula[i]
        xj, yj = jaula[j]
        if (yi > y) != (yj > y) and x < (xj - xi) * (y - yi) / (yj - yi) + xi:
            dentro = not dentro
        j = i
    return dentro

# ---------------------------------------------------------------- carreras


class Carrera:
    """Estado de carrera de un taxi: LIBRE -> CONFIRMANDO -> EN_CARRERA.

    Además de la duración y el máximo de pasajeros a la vez, reconstruye quién
    sube y quién baja: cada vez que el conteo cambia y se mantiene CAMBIO_S
    segundos, se anota una subida o bajada. Pasajeros distintos = los que
    estaban al empezar + todas las subidas posteriores (si 2 suben, 1 baja y
    sube otro, fueron 3)."""

    def __init__(self):
        self.estado = "LIBRE"
        self.ultimos = deque(maxlen=3)  # el conteo es la mediana de las 3 últimas fotos
        self.desde = self.inicio = self.cero_desde = None
        self.max = 0
        self.nivel = 0          # pasajeros a bordo (conteo estable)
        self.cand = self.cand_desde = None  # cambio de conteo esperando confirmarse
        self.distintos = 0
        self.eventos = []       # [hora, "sube" | "baja", cuántos, a bordo después]
        self.fotos = []
        self.ultima_ts = 0
        self.ultima_con_gente = 0
        self.con_wifi = False   # alguna foto de esta carrera se tomó con WiFi (¿en casa del dueño?)
        self.recibida = time.time()  # hora real (no la de la foto) en que llegó la última

    def actualizar(self, ts, n, foto, con_wifi=False):
        """Procesa una foto, en el orden en que se tomaron. Devuelve la carrera
        cerrada (dict) si terminó una."""
        self.recibida = time.time()
        if ts < self.ultima_ts - 1:
            return None  # más vieja que la anterior: se guarda pero no se mezcla en la carrera
        cerrada = None
        if self.ultima_ts and ts - self.ultima_ts > HUECO_S:
            # La cámara estuvo apagada un rato: lo que había se cierra donde se vio
            # gente por última vez, en vez de estirar la carrera por todo el hueco.
            if self.estado == "EN_CARRERA":
                cerrada = self.cerrar(self.ultima_con_gente or self.ultima_ts)
            else:
                self.__init__()
        self.ultimos.append(n)
        c = int(statistics.median(self.ultimos))
        self.ultima_ts = ts
        if con_wifi and (c >= 1 or self.estado != "LIBRE"):
            self.con_wifi = True
        if self.estado == "LIBRE":
            if c >= 1:
                self.estado, self.desde = "CONFIRMANDO", ts
        elif self.estado == "CONFIRMANDO":
            if c == 0:
                self.estado, self.con_wifi = "LIBRE", False
            elif ts - self.desde >= CONFIRMAR_S:
                self.estado, self.inicio, self.max = "EN_CARRERA", self.desde, c
                self.cero_desde, self.fotos = None, [foto]
                self.nivel = self.distintos = c
                self.eventos = [[self.desde, "sube", c, c]]
        else:
            if c > self.max:
                self.max = c
                self.fotos.append(foto)  # evidencia: cuando sube el máximo
            self._seguir_conteo(ts, c, foto)
            if c == 0:
                self.cero_desde = self.cero_desde or ts
                if ts - self.cero_desde >= GRACIA_S:
                    cerrada = self.cerrar(self.cero_desde)
            else:
                self.cero_desde = None
                self.ultima_con_gente = ts
                if not self.fotos or ts - self.fotos[-1][0] >= 30:
                    self.fotos.append(foto)  # y una cada 30 s
        if c >= 1:
            self.ultima_con_gente = ts
        return cerrada

    def _seguir_conteo(self, ts, c, foto):
        """Anota subidas y bajadas cuando un cambio de conteo se mantiene."""
        if c == self.nivel or c == 0:  # la bajada a 0 la registra el cierre
            self.cand = None
            return
        if self.cand != c:
            self.cand, self.cand_desde = c, ts
            return
        if ts - self.cand_desde >= CAMBIO_S:
            delta = c - self.nivel
            if delta > 0:
                self.distintos += delta
            self.eventos.append([self.cand_desde, "sube" if delta > 0 else "baja", abs(delta), c])
            self.nivel, self.cand = c, None
            self.fotos.append(foto)  # evidencia: cada subida o bajada

    def cerrar(self, fin):
        dur = fin - self.inicio
        eventos = self.eventos + ([[fin, "baja", self.nivel, 0]] if self.nivel else [])
        r = {"inicio": self.inicio, "fin": fin, "duracion": dur, "max_pax": self.max,
             "pasajeros": max(self.distintos, self.max), "eventos": eventos,
             "valida": int(dur >= MINIMO_S), "fotos": [p for _, p in self.fotos[:30]],
             "con_wifi": int(self.con_wifi)}
        self.__init__()
        return r

    # El estado se guarda en la base después de cada foto: si el servidor se
    # reinicia, la carrera en curso sigue donde iba.
    _CAMPOS = ("estado", "desde", "inicio", "cero_desde", "max", "nivel", "cand", "cand_desde",
               "distintos", "eventos", "fotos", "ultima_ts", "ultima_con_gente", "con_wifi")

    def a_json(self):
        d = {k: getattr(self, k) for k in self._CAMPOS}
        d["ultimos"] = list(self.ultimos)
        return json.dumps(d)

    @classmethod
    def de_json(cls, texto):
        c = cls()
        try:
            d = json.loads(texto)
            for k in cls._CAMPOS:
                if k in d:
                    setattr(c, k, d[k])
            c.ultimos.extend(d.get("ultimos", []))
            c.fotos = [tuple(f) for f in c.fotos]
        except (ValueError, TypeError):
            return cls()
        return c


_carreras = {}
_carreras_lock = threading.Lock()


def carrera_de(disp):
    """Estado de carrera de una cámara: en memoria, o el guardado en la base
    (después de un reinicio del servidor). Llamar con _carreras_lock tomado."""
    if disp not in _carreras:
        fila = db("SELECT datos FROM estado_carreras WHERE dispositivo = ?", (disp,), one=True)
        _carreras[disp] = Carrera.de_json(fila["datos"]) if fila else Carrera()
    return _carreras[disp]


def guardar_estado(disp, car):
    db("INSERT INTO estado_carreras (dispositivo, datos) VALUES (?, ?) "
       "ON CONFLICT(dispositivo) DO UPDATE SET datos = excluded.datos", (disp, car.a_json()))


def a_revisar(disp, c):
    """Una carrera hecha con fotos tomadas con WiFi no se cuenta sola: con
    internet la cámara suele estar en la casa del dueño subiendo lo grabado, y
    ahí la gente de la casa parecería una carrera. Queda "por revisar" para que
    alguien del panel decida. Salvo que el taxi use internet en el auto
    (hotspot del conductor): ajuste "contar_con_wifi" del taxi."""
    if not (c.get("con_wifi") and c["valida"]) or c.get("decidida"):
        return c
    d = db("SELECT contar_con_wifi FROM dispositivos WHERE id = ?", (disp,), one=True)
    if d and d["contar_con_wifi"]:
        return c
    return {**c, "valida": 0, "revisar": 1}


def guardar_carrera(disp, c, anotar=True):
    c = a_revisar(disp, c)
    if anotar:
        tipo = "por revisar (fotos tomadas con WiFi: ¿en casa?)" if c.get("revisar") else \
            "válida" if c["valida"] else "descartada"
        evento(disp, f"carrera {tipo}: "
                     f"{datetime.fromtimestamp(c['inicio']):%d/%m %H:%M:%S} → {datetime.fromtimestamp(c['fin']):%H:%M:%S}, "
                     f"{int(c['duracion'])} s, {c.get('pasajeros', c['max_pax'])} pasajero(s)",
                     nivel="aviso" if c.get("revisar") else "info")
    _guardar_carrera(disp, c)
    if not c["valida"] and not c.get("revisar"):
        _vigilar_cortadas(disp, c["inicio"])


CORTADAS_N = 5  # carreras descartadas (menos de MINIMO_S) en una hora: alguien tapa y destapa la cámara


def _vigilar_cortadas(disp, ts):
    n = db("SELECT COUNT(*) AS n FROM carreras WHERE dispositivo = ? AND valida = 0 AND revisar = 0 "
           "AND inicio > ? AND inicio <= ?", (disp, ts - 3600, ts), one=True)["n"]
    if n >= CORTADAS_N:
        alerta(disp, "cortadas", "Muchas carreras cortadas",
               f"En una hora hubo {n} carreras de menos de {MINIMO_S} s (hasta las {datetime.fromtimestamp(ts):%H:%M} "
               f"del {datetime.fromtimestamp(ts):%d/%m}). Puede ser que alguien tape y destape la cámara, "
               "o que algo en la cabina confunda al detector.", ts=ts, cada_s=3 * 3600)


def _guardar_carrera(disp, c):
    db("INSERT INTO carreras (dispositivo, inicio, fin, duracion, max_pax, pasajeros, eventos, valida, fotos, "
       "revisar, con_wifi) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
       (disp, c["inicio"], c["fin"], c["duracion"], c["max_pax"], c.get("pasajeros", c["max_pax"]),
        json.dumps(c.get("eventos", [])), c["valida"], json.dumps(c["fotos"]),
        int(c.get("revisar", 0)), int(c.get("con_wifi", 0))))

# ---------------------------------------------------------------- app

app = FastAPI(title="Taxiff")
app.mount("/web", StaticFiles(directory=WEB), name="web")  # estilos y scripts del panel (sin datos)


@app.exception_handler(Exception)
async def error_inesperado(request: Request, exc: Exception):
    """Cualquier error no previsto queda en servidor.log con todo el detalle."""
    log.exception(f"error en {request.method} {request.url.path}")
    return JSONResponse({"detail": "Error interno del servidor (ver datos/logs/servidor.log)"}, 500)


log.info(f"servidor iniciado · datos en {DATOS} · modelo {MODELO.name}")

# ---------------------------------------------------------------- cuentas y sesiones
#
# Dos roles:
# - administrador (usuario "admin" + TAXIFF_CLAVE_PANEL): ve todo.
# - dueño de un taxi (cuenta creada desde el panel): solo las carreras de sus
#   taxis, con el cobro y los km estimados. Nunca las fotos ni la cámara.
# Se entra por /entrar (cookie firmada, 30 días). La clave del panel por HTTP
# Basic sigue sirviendo para scripts y pruebas.

COOKIE = "taxiff_sesion"
SESION_S = 30 * 86400
_archivo_secreto = DATOS / "secreto_sesion"
if not _archivo_secreto.exists():
    _archivo_secreto.write_text(secrets.token_hex(32))
SECRETO = bytes.fromhex(_archivo_secreto.read_text().strip())
ADMIN = {"rol": "admin", "id": 0, "usuario": "admin", "nombre": "Administrador"}


def hash_clave(clave, sal=None):
    sal = sal or secrets.token_hex(16)
    return sal + "$" + hashlib.pbkdf2_hmac("sha256", clave.encode(), bytes.fromhex(sal), 200_000).hex()


def clave_correcta(clave, guardada):
    sal = (guardada or "").split("$")[0]
    if not sal:
        hash_clave(clave)  # tarda lo mismo aunque el usuario no exista
        return False
    return secrets.compare_digest(hash_clave(clave, sal), guardada)


def _sello(cuenta):
    """Cambia si cambia la clave: así cambiarla cierra las sesiones abiertas."""
    base = CLAVE_PANEL if cuenta["rol"] == "admin" else cuenta["clave"]
    return hashlib.sha256(base.encode()).hexdigest()[:12]


def _firma(texto):
    return hmac.new(SECRETO, texto.encode(), hashlib.sha256).hexdigest()


def token_sesion(cuenta):
    texto = f"{cuenta['id']}.{int(time.time()) + SESION_S}.{_sello(cuenta)}"
    return texto + "." + _firma(texto)


def _cuenta(uid):
    if uid == 0:
        return ADMIN
    d = db("SELECT * FROM duenos WHERE id = ? AND activo = 1", (uid,), one=True)
    return d and {**d, "rol": "dueno"}


def quien(request):
    """La cuenta de quien hace el pedido, o None."""
    auth = request.headers.get("authorization", "")
    if auth[:6].lower() == "basic ":
        try:
            clave = base64.b64decode(auth[6:]).decode().partition(":")[2]
        except (ValueError, UnicodeDecodeError):
            return None
        return ADMIN if secrets.compare_digest(clave.encode(), CLAVE_PANEL.encode()) else None
    partes = (request.cookies.get(COOKIE) or "").split(".")
    if len(partes) != 4 or not secrets.compare_digest(partes[3], _firma(".".join(partes[:3]))):
        return None
    try:
        uid, vence = int(partes[0]), int(partes[1])
    except ValueError:
        return None
    cuenta = _cuenta(uid) if vence > time.time() else None
    if not cuenta or not secrets.compare_digest(partes[2], _sello(cuenta)):
        return None
    return cuenta


def panel_auth(request: Request):
    cuenta = quien(request)
    if not cuenta:
        raise HTTPException(401, "Hay que entrar con usuario y clave")
    if cuenta["rol"] != "admin":
        raise HTTPException(403, "Solo el administrador")
    return cuenta


def cuenta_auth(request: Request):
    cuenta = quien(request)
    if not cuenta:
        raise HTTPException(401, "Hay que entrar con usuario y clave")
    return cuenta


_fallos = {}  # ip -> horas de los intentos de entrada fallidos


def _ip(request):
    # Por el túnel de Cloudflare, la IP real viene en esta cabecera.
    return request.headers.get("cf-connecting-ip") or (request.client.host if request.client else "")


@app.post("/api/entrar")
async def entrar(request: Request):
    """{"usuario", "clave"}: abre la sesión (cookie). Más de 8 fallos en 10 min
    desde la misma IP la bloquean un rato."""
    body = await request.json()
    usuario = str(body.get("usuario", "")).strip().lower()
    clave = str(body.get("clave", ""))
    ip, ahora = _ip(request), time.time()
    recientes = [t for t in _fallos.get(ip, []) if ahora - t < 600]
    if len(recientes) >= 8:
        raise HTTPException(429, "Demasiados intentos. Espera unos minutos.")
    cuenta = None
    if usuario == "admin":
        if secrets.compare_digest(clave.encode(), CLAVE_PANEL.encode()):
            cuenta = ADMIN
    else:
        d = db("SELECT * FROM duenos WHERE usuario = ? AND activo = 1", (usuario,), one=True)
        if await run_in_threadpool(clave_correcta, clave, d["clave"] if d else ""):
            cuenta = {**d, "rol": "dueno"}
    if not cuenta:
        _fallos[ip] = recientes + [ahora]
        log.warning(f"entrada fallida: usuario {usuario!r} desde {ip}")
        raise HTTPException(401, "Usuario o clave incorrectos")
    _fallos.pop(ip, None)
    if cuenta["rol"] == "dueno":
        db("UPDATE duenos SET entro = ? WHERE id = ?", (ahora, cuenta["id"]))
    log.info(f"entró {usuario} ({cuenta['rol']}) desde {ip}")
    r = JSONResponse({"ok": True, "rol": cuenta["rol"], "ir": "/" if cuenta["rol"] == "admin" else "/dueno"})
    r.set_cookie(COOKIE, token_sesion(cuenta), max_age=SESION_S, httponly=True, samesite="lax",
                 secure=request.headers.get("x-forwarded-proto") == "https" or request.url.scheme == "https")
    return r


@app.get("/salir")
def salir():
    r = RedirectResponse("/entrar", 303)
    r.delete_cookie(COOKIE)
    return r


def _pagina(request, archivo, solo_admin=False):
    cuenta = quien(request)
    if not cuenta:
        return RedirectResponse("/entrar?volver=" + quote(request.url.path), 303)
    if solo_admin and cuenta["rol"] != "admin":
        return RedirectResponse("/dueno", 303)
    return FileResponse(WEB / archivo)


def dispositivo_auth(id, authorization):
    d = db("SELECT * FROM dispositivos WHERE id = ?", (id,), one=True)
    tok = (authorization or "").removeprefix("Bearer ").strip()
    if not d or not d["token_hash"] or not secrets.compare_digest(d["token_hash"], hash_token(tok)):
        raise HTTPException(401, "Dispositivo o token inválido")
    # Cualquier contacto cuenta (fotos, registro, buscar firmware): así el panel
    # distingue "conectada pero sin enviar fotos" de "sin conexión".
    db("UPDATE dispositivos SET contacto = ? WHERE id = ?", (time.time(), id))
    return d


# Llegada de fotos en el último minuto, por cámara (para "recibiendo N fotos/min").
_llegadas = {}


def _anotar_llegadas(disp, n):
    ahora = time.time()
    q = _llegadas.setdefault(disp, deque())
    q.extend([ahora] * n)
    while q and ahora - q[0] > 60:
        q.popleft()


def _por_minuto(disp):
    q = _llegadas.get(disp)
    return sum(1 for t in q if time.time() - t <= 60) if q else 0


def _cola_informada(disp, cola):
    """Fotos que la cámara dice tener guardadas; el máximo de la tanda sirve para la barra de avance."""
    if cola is None:
        return
    db("UPDATE dispositivos SET cola = ?, cola_max = CASE WHEN ? = 0 THEN 0 ELSE MAX(COALESCE(cola_max, 0), ?) END "
       "WHERE id = ?", (cola, cola, cola, disp))


@app.post("/api/v1/registro")
async def registro(request: Request):
    """La cámara se presenta con su ID de fábrica y recibe su token (una sola vez)."""
    body = await request.json()
    disp = str(body.get("id", ""))[:32]
    if not disp.startswith("TX-"):
        raise HTTPException(400, "ID inválido")
    d = db("SELECT * FROM dispositivos WHERE id = ?", (disp,), one=True)
    if d and d["token_hash"]:
        # Ya tiene token: solo se entrega otro si el admin lo reinicia en el panel.
        raise HTTPException(409, "Ya registrado")
    token = secrets.token_urlsafe(24)
    if d:
        db("UPDATE dispositivos SET token_hash = ?, fw = ? WHERE id = ?", (hash_token(token), body.get("fw"), disp))
    else:
        db("INSERT INTO dispositivos (id, token_hash, aprobado, creado, fw) VALUES (?, ?, ?, ?, ?)",
           (disp, hash_token(token), int(AUTO_APROBAR), time.time(), body.get("fw")))
    evento(disp, f"cámara registrada (firmware {body.get('fw')})" + (" de nuevo" if d else ""), nivel="aviso")
    return {"token": token, "aprobado": bool(d["aprobado"]) if d else AUTO_APROBAR}


FOTO_CON_WIFI = 0x40000000  # bit en el conteo de la cámara: la foto se tomó con WiFi


def separar_conteo(conteo):
    """(pasajeros que contó la cámara, ¿se tomó con WiFi?)."""
    conteo = int(conteo or 0)
    if conteo < 0:
        return conteo, False
    return conteo & ~FOTO_CON_WIFI, bool(conteo & FOTO_CON_WIFI)


def config(clave, defecto=None):
    fila = db("SELECT valor FROM config WHERE clave = ?", (clave,), one=True)
    return json.loads(fila["valor"]) if fila else defecto


def brillo_y_privacidad(ruta, dets, difuminar):
    """Brillo medio de la foto (0 negro – 255 blanco) y, si `difuminar`, borra
    las caras: desenfoca cada persona detectada y vuelve a guardar el JPG. Los
    datos de dónde estaba cada una (dets) quedan, así el conteo, la jaula y el
    reanálisis siguen funcionando."""
    from PIL import Image, ImageFilter, ImageStat
    with Image.open(ruta) as im:
        im = im.convert("RGB")
        brillo = round(ImageStat.Stat(im.convert("L")).mean[0], 1)
        if difuminar and dets:
            W, H = im.size
            for x1, y1, x2, y2, *_ in dets:
                caja = (max(0, int(x1 * W)), max(0, int(y1 * H)), min(W, math.ceil(x2 * W)), min(H, math.ceil(y2 * H)))
                if caja[2] - caja[0] > 1 and caja[3] - caja[1] > 1:
                    zona = im.crop(caja).filter(ImageFilter.GaussianBlur(max(4, (caja[2] - caja[0]) // 5)))
                    im.paste(zona, caja)
            im.save(ruta, quality=85)
    return brillo


# Cámara tapada: fotos casi negras de día (con luz no hay motivo) durante 10 min
# seguidos. De noche, sin luz infrarroja, lo oscuro es normal y no se mira.
OSCURA_BRILLO = 18
OSCURA_S = 10 * 60
DE_DIA = (7, 17)  # de 7:00 a 17:59 (Loja, cerca del ecuador: amanece ~6:15 y anochece ~18:30 todo el año)
_oscuras = {}     # cámara -> hora de la primera foto oscura seguida (None = ya avisado)


def alerta(disp, tipo, titulo, texto, ts=None, cada_s=6 * 3600):
    """Guarda una alerta para el dueño (y en el registro), salvo que haya otra del
    mismo tipo hace menos de `cada_s` (no repetir la misma cada minuto)."""
    ts = ts or time.time()
    if db("SELECT id FROM alertas WHERE dispositivo = ? AND tipo = ? AND ts > ?", (disp, tipo, ts - cada_s), one=True):
        return False
    db("INSERT INTO alertas (dispositivo, ts, tipo, titulo, texto) VALUES (?, ?, ?, ?, ?)", (disp, ts, tipo, titulo, texto))
    evento(disp, f"ALERTA {titulo}: {texto}", nivel="aviso")
    return True


def _vigilar_oscuridad(disp, ts, brillo, n):
    """Llamar con _carreras_lock tomado, con las fotos en orden."""
    de_dia = DE_DIA[0] <= datetime.fromtimestamp(ts).hour <= DE_DIA[1]
    if not de_dia or brillo >= OSCURA_BRILLO or n:
        _oscuras[disp] = 0  # 0 = sin racha
        return
    desde = _oscuras.get(disp, 0)
    if desde is None:
        return  # esta racha ya se avisó
    if not desde:
        _oscuras[disp] = ts
    elif ts - desde >= OSCURA_S:
        _oscuras[disp] = None
        alerta(disp, "oscura", "Cámara tapada u oscura de día",
               f"Desde las {datetime.fromtimestamp(desde):%H:%M} del {datetime.fromtimestamp(desde):%d/%m} la cámara "
               f"ve todo negro por más de {OSCURA_S // 60} min, con luz de día. Puede estar tapada (cinta, un trapo) o mal apuntada.",
               ts=ts)


def procesar_foto(d, datos, ts_camara, conteo, estimada=False):
    """Guarda una foto, cuenta pasajeros con YOLO y avanza la carrera del taxi.
    Devuelve (ruta relativa, pasajeros, estado de la carrera)."""
    ahora = time.time()
    conteo, con_wifi = separar_conteo(conteo)
    # Las fotos guardadas sin internet llegan con la hora en que se tomaron.
    # Si la cámara arrancó sin internet la estima a partir de sus arranques
    # (`estimada`): se respeta, para que queden en orden, pero se marca como
    # "hora aproximada". Si no sabe ninguna hora, la foto queda aparte ("sin
    # hora"): no se pone en la línea del tiempo (antes se le daba la hora de
    # llegada y quedaba mezclada con las fotos de ese momento) ni cuenta para carreras.
    valida = bool(ts_camara) and abs(ahora - ts_camara) <= MAX_ATRASO_S
    aprox = estimada or not valida
    sin_hora = not valida
    ts = ts_camara if valida else ahora
    carpeta = FOTOS / d["id"] / datetime.fromtimestamp(ts).strftime("%Y-%m-%d")
    carpeta.mkdir(parents=True, exist_ok=True)
    ruta = carpeta / f"{ts:.3f}.jpg"
    while ruta.exists():  # dos fotos en el mismo milisegundo
        ts += 0.001
        ruta = carpeta / f"{ts:.3f}.jpg"
    ruta.write_bytes(datos)
    rel = ruta.relative_to(FOTOS).as_posix()

    dets = detectar(ruta)
    jaula = json.loads(d["jaula"] or "[]")
    for b in dets:
        b.append(int(dentro_de_jaula((b[0] + b[2]) / 2, (b[1] + b[3]) / 2, jaula)))
    n = sum(b[5] for b in dets)
    try:
        brillo = brillo_y_privacidad(ruta, dets, config("difuminar", False))
    except OSError:
        brillo = None  # JPEG cortado: se guarda igual, sin brillo
    info = {"ts": ts, "dets": dets, "n": n, "n_esp": conteo, "aprox": aprox, "brillo": brillo}
    if sin_hora:
        info["sin_hora"] = True
    if con_wifi:
        info["con_wifi"] = True
    ruta.with_suffix(".json").write_text(json.dumps(info))

    with _carreras_lock:
        car = carrera_de(d["id"])
        cerrada = None if sin_hora else car.actualizar(ts, n, (ts, rel), con_wifi)
        estado = car.estado
        guardar_estado(d["id"], car)
        if brillo is not None and not sin_hora:
            _vigilar_oscuridad(d["id"], ts, brillo, n)
    if cerrada:
        guardar_carrera(d["id"], cerrada)
    return rel, n, estado


def _actualizar_dispositivo(d, rel, n, conteo, estado, recibidas, cola, fw, rssi, temp,
                            cfg=None, ajustes_ver=None, ip=None):
    conteo = separar_conteo(conteo)[0]
    db("UPDATE dispositivos SET visto = ?, fw = COALESCE(?, fw), rssi = COALESCE(?, rssi), "
       "temp = COALESCE(?, temp), ultima_foto = ?, pax = ?, pax_esp = ?, estado = ?, cola = ?, "
       "fotos_recibidas = fotos_recibidas + ?, cfg_camara = COALESCE(?, cfg_camara), "
       "ajustes_aplicados = COALESCE(?, ajustes_aplicados), ip_local = COALESCE(?, ip_local) WHERE id = ?",
       (time.time(), fw, rssi, temp, rel, n, conteo, estado, cola, recibidas, cfg, ajustes_ver, ip, d["id"]))
    _cola_informada(d["id"], cola)
    _anotar_llegadas(d["id"], recibidas)


# Ajustes de la cámara que se pueden cambiar desde el panel, con sus valores válidos.
AJUSTES_CAMARA = {
    "fs": ("qvga", "vga"),               # resolución (cambiarla reinicia la cámara)
    "q": (40, 60, 80),                   # calidad JPEG
    "model": ("personas", "caras"),      # personas = modelo propio de cabezas
    "pthr": (0.3, 0.4, 0.5, 0.65),       # sensibilidad del modelo propio
    "mrg": (0.0, 1.5, 2.5, 4.0),         # unir detecciones cercanas
    "night": (0, 1),                     # modo noche
    "rot": (0, 1),                       # cámara girada 180°
    "det": (0, 1),                       # detección en la cámara
    "cap": (0, 2, 5, 10),                # foto de entrenamiento cada N s (0 = no)
}


# Ritmo de fotos que se le pide a la cámara (ms). La cámara además hace una
# ráfaga de 1 por segundo unos segundos cada vez que su propio conteo cambia.
RITMO_CAMBIO_MS = 1000    # confirmando una subida o con gente fuera de carrera
RITMO_CARRERA_MS = 4000   # carrera estable
RITMO_VACIO_MS = 15000    # cabina vacía (para poder comprobar que de verdad no había nadie)


def _respuesta(d, estado, n, conteo, ajustes_ver_camara=-1, **extra):
    conteo = separar_conteo(conteo)[0]
    if estado == "CONFIRMANDO" or (estado == "LIBRE" and (n > 0 or conteo > 0)):
        intervalo = RITMO_CAMBIO_MS
    elif estado == "EN_CARRERA":
        intervalo = RITMO_CARRERA_MS
    else:
        intervalo = RITMO_VACIO_MS
    r = {"modo": "lento" if intervalo == RITMO_VACIO_MS else "rapido", "intervalo_ms": intervalo,
         "pasajeros": n, "estado": estado,
         "firmware": firmware_mas_nuevo()[0] or "", **extra}  # la cámara se actualiza si no es la suya
    # Ajustes elegidos en el panel que la cámara todavía no tiene (-1 = firmware viejo).
    ajustes = json.loads(d.get("ajustes") or "{}")
    if ajustes and ajustes_ver_camara >= 0 and ajustes_ver_camara != (d.get("ajustes_ver") or 0):
        r["ajustes_ver"] = d["ajustes_ver"]
        r["ajustes_q"] = "&".join(f"{k}={v}" for k, v in ajustes.items())
    return r


def _ordenes_wifi(d, redes, red, orden_camara=None):
    """Anota las redes que la cámara tiene guardadas (cabecera X-Redes, firmware
    4.3+: nombres en formato URL separados por tab) y le devuelve lo que pidió el
    panel: redes a quitar y abrir Taxiff-Cam (una sola vez).
    Quitar se repite hasta que la cámara la cumple: con firmware 4.4+ informa el
    número de la última orden cumplida (X-Wifi-Orden), así se sabe aunque quitar
    la red en uso la haya dejado sin internet; si no, cuando deja de informar la red."""
    if redes is None:
        return {}  # firmware viejo: no informa sus redes
    guardadas = [s for s in unquote(redes).split("\t") if s]
    pendientes = json.loads(d.get("wifi_olvidar") or "[]")
    if orden_camara is not None and orden_camara >= (d.get("wifi_orden") or 0):
        pendientes = []  # ya cumplió la última orden: si la red está, la volvieron a agregar
    olvidar = [s for s in pendientes if s in guardadas]
    db("UPDATE dispositivos SET redes = ?, red_actual = ?, wifi_olvidar = ?, abrir_portal = 0 WHERE id = ?",
       (json.dumps(guardadas), unquote(red or ""), json.dumps(olvidar), d["id"]))
    out = {}
    if olvidar:
        out["wifi_olvidar"] = quote("\t".join(olvidar), safe="")
        out["wifi_orden"] = d.get("wifi_orden") or 0
    if d.get("abrir_portal"):
        out["abrir_portal"] = True
    return out


@app.post("/api/v1/foto")
async def foto(request: Request,
               x_dispositivo: str = Header(...), authorization: str = Header(None),
               x_ts: float = Header(0), x_conteo: int = Header(0), x_cola: int = Header(0),
               x_temp: float = Header(None), x_rssi: int = Header(None), x_fw: str = Header(None),
               x_cfg: str = Header(None), x_ajustes_ver: int = Header(-1), x_ip: str = Header(None),
               x_redes: str = Header(None), x_red: str = Header(None), x_wifi_orden: int = Header(None)):
    d = dispositivo_auth(x_dispositivo, authorization)
    if not d["aprobado"]:
        return JSONResponse({"error": "pendiente de aprobación", "intervalo_ms": 30000}, 403)
    datos = await request.body()
    if not datos or len(datos) > 400_000 or datos[:2] != b"\xff\xd8":
        raise HTTPException(400, "Se espera una foto JPEG")
    # YOLO tarda ~0,1–0,3 s: en otro hilo, para no frenar al resto de cámaras.
    rel, n, estado = await run_in_threadpool(procesar_foto, d, datos, x_ts, x_conteo)
    _actualizar_dispositivo(d, rel, n, x_conteo, estado, 1, x_cola, x_fw, x_rssi, x_temp,
                            x_cfg, x_ajustes_ver if x_ajustes_ver >= 0 else None, x_ip)
    return _respuesta(d, estado, n, x_conteo, x_ajustes_ver, **_ordenes_wifi(d, x_redes, x_red, x_wifi_orden))


@app.post("/api/v1/lote")
async def lote(request: Request,
               x_dispositivo: str = Header(...), authorization: str = Header(None),
               x_cola: int = Header(0), x_temp: float = Header(None), x_rssi: int = Header(None),
               x_fw: str = Header(None), x_cfg: str = Header(None), x_ajustes_ver: int = Header(-1),
               x_ip: str = Header(None), x_redes: str = Header(None), x_red: str = Header(None),
               x_wifi_orden: int = Header(None)):
    """Varias fotos guardadas sin internet en un solo envío, de la más vieja a la
    más nueva. Cada una: hora en ms (uint64), conteo de la cámara (int32), largo
    (uint32), todo little-endian, y luego el JPEG. El bit más alto de la hora
    indica que la cámara la estimó (arrancó sin internet)."""
    d = dispositivo_auth(x_dispositivo, authorization)
    if not d["aprobado"]:
        return JSONResponse({"error": "pendiente de aprobación", "intervalo_ms": 30000}, 403)
    datos = await request.body()
    if len(datos) > 4_000_000:
        raise HTTPException(413, "Lote demasiado grande")
    fotos, i = [], 0
    while i + 16 <= len(datos):
        ts_ms, conteo, largo = struct.unpack_from("<QiI", datos, i)
        i += 16
        jpg = datos[i:i + largo]
        i += largo
        if len(jpg) != largo or jpg[:2] != b"\xff\xd8":
            raise HTTPException(400, "Lote dañado")
        estimada = bool(ts_ms >> 63)
        fotos.append(((ts_ms & ~(1 << 63)) / 1000, conteo, jpg, estimada))
    if not fotos or i != len(datos):
        raise HTTPException(400, "Lote vacío o dañado")
    for ts, conteo, jpg, estimada in fotos:
        rel, n, estado = await run_in_threadpool(procesar_foto, d, jpg, ts, conteo, estimada)
    _actualizar_dispositivo(d, rel, n, conteo, estado, len(fotos), x_cola, x_fw, x_rssi, x_temp,
                            x_cfg, x_ajustes_ver if x_ajustes_ver >= 0 else None, x_ip)
    log.info(f"{d['id']} lote de {len(fotos)} fotos guardadas sin internet (quedan {x_cola} en la cámara)")
    return _respuesta(d, estado, n, conteo, x_ajustes_ver, recibidas=len(fotos),
                      **_ordenes_wifi(d, x_redes, x_red, x_wifi_orden))

@app.post("/api/v1/eventos")
async def eventos_camara(request: Request, x_dispositivo: str = Header(...), authorization: str = Header(None),
                         x_cola: int = Header(None)):
    """La cámara manda las líneas nuevas de su registro (texto, una por línea).
    Las que escribió sin internet llegan cuando vuelve a conectarse."""
    d = dispositivo_auth(x_dispositivo, authorization)
    _cola_informada(d["id"], x_cola)
    datos = await request.body()
    if len(datos) > 256_000:
        raise HTTPException(413, "Registro demasiado grande")
    lineas = [l.strip() for l in datos.decode("utf-8", "replace").splitlines() if l.strip()]
    for l in lineas[:2000]:
        evento(d["id"], l, origen="cámara")
    return {"recibidas": len(lineas)}


def _version(v):
    """'1.10' > '1.9': compara versiones número por número."""
    try:
        return tuple(int(x) for x in v.split("."))
    except (AttributeError, ValueError):
        return (0,)


def firmware_mas_nuevo():
    """(versión, archivo) del firmware más nuevo en datos/firmware, o (None, None)."""
    bins = [(f.stem.removeprefix("taxiff_cam-"), f) for f in FIRMWARE.glob("taxiff_cam-*.bin")]
    return max(bins, key=lambda b: _version(b[0]), default=(None, None))


@app.get("/api/v1/firmware")
def firmware(id: str, token: str, actual: str = ""):
    """La cámara pregunta si hay firmware nuevo. Si lo hay, responde la URL de descarga.
    (Token en la URL porque el actualizador del ESP32 no envía cabeceras propias; va por HTTPS.)"""
    dispositivo_auth(id, "Bearer " + token)
    version, archivo = firmware_mas_nuevo()
    if not version or _version(version) <= _version(actual):
        return {"actualizar": False}
    return {"actualizar": True, "version": version,
            "url": f"/api/v1/firmware/descargar?id={id}&token={token}&version={version}"}


@app.get("/api/v1/firmware/descargar")
def firmware_descargar(id: str, token: str, version: str):
    dispositivo_auth(id, "Bearer " + token)
    archivo = FIRMWARE / f"taxiff_cam-{version}.bin"
    if not archivo.exists():
        raise HTTPException(404)
    return FileResponse(archivo, media_type="application/octet-stream")


@app.get("/api/salud")
def salud():
    """Para el monitoreo del servidor (sin datos privados)."""
    return {"ok": True, "camaras": db("SELECT COUNT(*) AS n FROM dispositivos", one=True)["n"],
            "firmware": firmware_mas_nuevo()[0]}

# ---------------------------------------------------------------- panel


def _hace(s):
    s = int(s)
    if s < 90:
        return f"{s} s"
    if s < 5400:
        return f"{round(s / 60)} min"
    if s < 172800:
        return f"{round(s / 3600)} h"
    return f"{round(s / 86400)} días"


def _conexion(d, ahora):
    """Qué está pasando con la cámara, para mostrarlo en el panel:
    recibiendo / subiendo (fotos guardadas) / sin_fotos (conectada pero no envía) / sin_conexion."""
    foto = ahora - d["visto"] if d["visto"] else None
    contacto = ahora - (d.get("contacto") or d["visto"] or 0) if (d.get("contacto") or d["visto"]) else None
    cola, cola_max, por_min = d.get("cola") or 0, max(d.get("cola_max") or 0, d.get("cola") or 0), _por_minuto(d["id"])
    base = {"cola": cola, "cola_max": cola_max, "por_min": por_min,
            "foto_hace_s": None if foto is None else int(foto), "contacto_hace_s": None if contacto is None else int(contacto)}
    # Subiendo lo guardado, con WiFi floja un envío a veces se corta y la cámara
    # reintenta sola: una pausa de unos minutos es normal y no es un error.
    if cola > 0 and foto is not None and foto < 180 and contacto is not None and contacto < 150:
        pausa = foto >= 45
        return {**base, "estado": "subiendo",
                "titulo": f"Subiendo fotos guardadas · quedan {cola}" + (" · reintentando" if pausa else ""),
                "detalle": (f"La conexión está lenta: el último envío se cortó hace {_hace(foto)} y la cámara reintenta sola."
                            if pausa else f"Llegaron {por_min} en el último minuto. Son las que tomó sin internet.")}
    if foto is not None and foto < 45:
        return {**base, "estado": "recibiendo", "titulo": "Recibiendo fotos",
                "detalle": f"{por_min} en el último minuto · la última hace {_hace(foto)}"}
    if contacto is not None and contacto < 150:
        return {**base, "estado": "sin_fotos", "titulo": "Conectada, pero no está enviando fotos",
                "detalle": (f"La cámara habla con el servidor (hace {_hace(contacto)}) y tiene {cola} fotos guardadas, "
                            "pero no las sube. Mira la pestaña Registro; si sigue así, reiníciala o conéctala por cable.")
                if cola else f"La cámara habla con el servidor (hace {_hace(contacto)}) pero no manda fotos. "
                             "Puede estar arrancando: espera un minuto."}
    if contacto is None:
        return {**base, "estado": "sin_conexion", "titulo": "Nunca se conectó", "detalle": ""}
    return {**base, "estado": "sin_conexion", "titulo": f"Sin conexión desde hace {_hace(contacto)}",
            "detalle": "Sin internet o apagada. Lo que grabe se subirá cuando vuelva a conectarse."}


def _info_taxi(d):
    ahora = time.time()
    hoy = datetime.now().replace(hour=0, minute=0, second=0, microsecond=0).timestamp()
    d = dict(d)
    d.pop("token_hash", None)
    d["en_linea"] = bool(d["visto"] and ahora - d["visto"] < 30)
    d["conexion"] = _conexion(d, ahora)
    d["jaula"] = json.loads(d["jaula"] or "[]")
    d["ajustes"] = json.loads(d.get("ajustes") or "{}")
    d["tarifa"] = tarifa_de(d)
    d["redes"] = json.loads(d["redes"]) if d.get("redes") is not None else None  # None = firmware sin este dato
    d["wifi_olvidar"] = json.loads(d.get("wifi_olvidar") or "[]")
    try:
        d["cfg_camara"] = json.loads(d.get("cfg_camara") or "{}")
    except ValueError:
        d["cfg_camara"] = {}
    # ¿La cámara ya aplicó los últimos ajustes elegidos en el panel?
    d["ajustes_pendientes"] = bool(d["ajustes"]) and (d.get("ajustes_aplicados") or 0) != (d.get("ajustes_ver") or 0)
    d["carreras_hoy"] = db("SELECT COUNT(*) AS n FROM carreras WHERE dispositivo = ? AND inicio >= ? AND valida = 1",
                           (d["id"], hoy), one=True)["n"]
    d["por_revisar"] = db("SELECT COUNT(*) AS n FROM carreras WHERE dispositivo = ? AND revisar = 1",
                          (d["id"],), one=True)["n"]
    with _carreras_lock:
        c = carrera_de(d["id"])
        d["carrera_s"] = int(c.ultima_ts - c.inicio) if c and c.estado == "EN_CARRERA" else 0
        d["carrera_max"] = c.max if c and c.estado == "EN_CARRERA" else 0
    return d


@app.get("/api/panel/taxis", dependencies=[Depends(panel_auth)])
def taxis():
    return [_info_taxi(d) for d in db("SELECT * FROM dispositivos ORDER BY creado")]


@app.get("/api/panel/taxi/{disp}", dependencies=[Depends(panel_auth)])
def taxi(disp: str):
    d = db("SELECT * FROM dispositivos WHERE id = ?", (disp,), one=True)
    if not d:
        raise HTTPException(404)
    info = _info_taxi(d)
    ult = FOTOS / (d["ultima_foto"] or "_")
    info["ultima"] = json.loads(ult.with_suffix(".json").read_text()) if ult.with_suffix(".json").exists() else None
    info["carreras"] = db("SELECT * FROM carreras WHERE dispositivo = ? ORDER BY inicio DESC LIMIT 100", (disp,))
    for c in info["carreras"]:
        c["fotos"] = json.loads(c["fotos"] or "[]")
        c["eventos"] = json.loads(c.get("eventos") or "[]")
    return info


def _carpeta_taxi(disp):
    p = (FOTOS / disp).resolve()
    if FOTOS.resolve() not in p.parents:
        raise HTTPException(404)
    return p


@app.get("/api/panel/taxi/{disp}/dias", dependencies=[Depends(panel_auth)])
def dias_con_fotos(disp: str):
    """Días que tienen fotos de este taxi, el más reciente primero."""
    p = _carpeta_taxi(disp)
    return sorted((c.name for c in p.iterdir() if c.is_dir()), reverse=True) if p.exists() else []


@app.get("/api/panel/taxi/{disp}/fotos", dependencies=[Depends(panel_auth)])
def fotos_del_dia(disp: str, dia: str, solo_pasajeros: bool = False, limite: int = 400,
                  desde: float = 0, hasta: float = 0, filtro: str = "", cada: int = 0, orden: str = "asc"):
    """Fotos de un día en orden de hora, con lo que contó el servidor y la cámara.
    - `orden`: "asc" de temprano a tarde · "desc" de tarde a temprano (para ver
      más, pedir con `hasta` = la hora de la última recibida).
    - `desde`/`hasta` (hora en segundos): un rango, p. ej. una carrera.
    - `filtro`: "" todas · "pasajeros" con alguien · "vacias" sin nadie (para
      comprobar que de verdad no había nadie) · "importantes" solo donde cambió
      el número de pasajeros (subió o bajó alguien), más la primera y la última ·
      "sin_hora" las que la cámara no supo cuándo tomó (los demás filtros no las incluyen).
    - `cada` (segundos): como mucho una foto cada tanto (p. ej. 60 = una por minuto)."""
    if solo_pasajeros:
        filtro = "pasajeros"
    try:
        datetime.strptime(dia, "%Y-%m-%d")
    except ValueError:
        raise HTTPException(400, "Día inválido (AAAA-MM-DD)")
    carpeta = _carpeta_taxi(disp) / dia
    if not carpeta.exists():
        return []
    limite = min(limite, 2000)
    if orden == "desc":
        # Los filtros se calculan siempre de temprano a tarde (el "cambio" depende
        # de las fotos anteriores); después se da vuelta y se toman las últimas.
        todas = _fotos_en_orden(carpeta, disp, dia, desde, hasta, filtro, cada, 10 ** 9)
        return todas[::-1][:limite]
    return _fotos_en_orden(carpeta, disp, dia, desde, hasta, filtro, cada, limite)


def _fotos_en_orden(carpeta, disp, dia, desde, hasta, filtro, cada, limite):
    # "Cambio" con el mismo suavizado que las carreras (mediana de las 3 últimas
    # fotos): un parpadeo del detector en una sola foto no cuenta.
    out, anterior, ultima_incluida, ultima_vista, ultimos = [], None, -1e12, None, deque(maxlen=3)
    for j in sorted(carpeta.glob("*.json"), key=lambda f: float(f.stem)):
        if float(j.stem) < desde:
            continue
        if hasta and float(j.stem) > hasta:
            break
        try:
            info = json.loads(j.read_text())
        except (OSError, ValueError):
            continue
        if not j.with_suffix(".jpg").exists():
            continue
        # Las fotos "sin hora" (la cámara no supo cuándo las tomó) van aparte:
        # su hora es la de llegada y, en la línea del tiempo, se mezclarían.
        if bool(info.get("sin_hora")) != (filtro == "sin_hora"):
            continue
        f = {"foto": f"{disp}/{dia}/{j.stem}.jpg", "ts": info["ts"], "n": info.get("n", 0),
             "n_esp": info.get("n_esp", 0), "aprox": info.get("aprox", False),
             "sin_hora": info.get("sin_hora", False), "con_wifi": info.get("con_wifi", False)}
        ultimos.append(f["n"])
        suavizado = int(statistics.median(ultimos))
        cambio = anterior is None or suavizado != anterior
        anterior = suavizado
        ultima_vista = f
        if filtro == "pasajeros" and not f["n"]:
            continue
        if filtro == "vacias" and f["n"]:
            continue
        if filtro == "importantes" and not cambio:
            continue
        if cada and f["ts"] - ultima_incluida < cada and not (filtro == "importantes"):
            continue
        f["cambio"] = cambio
        out.append(f)
        ultima_incluida = f["ts"]
        if len(out) >= limite:
            return out
    # "importantes" termina con la última foto del rango (cómo quedó la cabina).
    if filtro == "importantes" and ultima_vista and (not out or out[-1]["ts"] != ultima_vista["ts"]):
        out.append({**ultima_vista, "cambio": False})
    return out


@app.get("/api/panel/taxi/{disp}/carreras", dependencies=[Depends(panel_auth)])
def carreras_del_dia(disp: str, dia: str):
    """Carreras que empezaron ese día (hora local), de la primera a la última,
    con un resumen del día."""
    try:
        ini = datetime.strptime(dia, "%Y-%m-%d").timestamp()
    except ValueError:
        raise HTTPException(400, "Día inválido (AAAA-MM-DD)")
    rows = db("SELECT * FROM carreras WHERE dispositivo = ? AND inicio >= ? AND inicio < ? ORDER BY inicio",
              (disp, ini, ini + 86400))
    for c in rows:
        c["fotos"] = json.loads(c["fotos"] or "[]")
        c["eventos"] = json.loads(c.get("eventos") or "[]")
        c["pasajeros"] = c.get("pasajeros") or c["max_pax"]
    validas = [c for c in rows if c["valida"]]
    por_revisar = sum(1 for c in rows if c.get("revisar"))
    return {"carreras": rows, "resumen": {
        "carreras": len(validas),
        "descartadas": len(rows) - len(validas) - por_revisar,
        "por_revisar": por_revisar,
        "tiempo_s": sum(c["duracion"] for c in validas),
        "pasajeros": sum(c["pasajeros"] for c in validas),
        "mas_larga_s": max((c["duracion"] for c in validas), default=0)}}


@app.get("/api/panel/taxi/{disp}/por_revisar", dependencies=[Depends(panel_auth)])
def carreras_por_revisar(disp: str):
    """Carreras hechas con fotos tomadas con WiFi (¿en casa del dueño?) que
    esperan que alguien decida si fueron carreras de verdad. Todas, de cualquier día."""
    rows = db("SELECT * FROM carreras WHERE dispositivo = ? AND revisar = 1 ORDER BY inicio DESC LIMIT 200", (disp,))
    for c in rows:
        c["fotos"] = json.loads(c["fotos"] or "[]")
        c["eventos"] = json.loads(c.get("eventos") or "[]")
        c["pasajeros"] = c.get("pasajeros") or c["max_pax"]
    return rows


@app.post("/api/panel/taxi/{disp}/carrera/{cid}", dependencies=[Depends(panel_auth)])
async def decidir_carrera(disp: str, cid: int, request: Request):
    """{"valida": true | false}: alguien del panel decide una carrera por revisar
    (o corrige cualquier otra)."""
    body = await request.json()
    c = db("SELECT * FROM carreras WHERE dispositivo = ? AND id = ?", (disp, cid), one=True)
    if not c:
        raise HTTPException(404)
    valida = int(bool(body.get("valida")))
    db("UPDATE carreras SET valida = ?, revisar = 0 WHERE id = ?", (valida, cid))
    evento(disp, f"carrera del {datetime.fromtimestamp(c['inicio']):%d/%m %H:%M:%S} marcada como "
                 f"{'VÁLIDA' if valida else 'NO válida'} desde el panel", nivel="info")
    return {"ok": True, "valida": valida}


def _resumen_carreras(carreras):
    validas = [c for c in carreras if c["valida"]]
    por_revisar = sum(1 for c in carreras if c.get("revisar"))
    return {"carreras": len(validas), "descartadas": len(carreras) - len(validas) - por_revisar,
            "por_revisar": por_revisar, "tiempo_s": sum(c["duracion"] for c in validas),
            "pasajeros": sum(c.get("pasajeros") or c["max_pax"] for c in validas)}


def reconstruir_dia(disp, dia, jaula):
    """Vuelve a contar las fotos guardadas de un día con otra jaula (sin volver a
    pasar YOLO: cada foto guarda dónde vio a cada persona) y rearma las carreras.
    Devuelve (carreras, cambios, fotos con su conteo nuevo, estado final)."""
    carpeta = _carpeta_taxi(disp) / dia
    car = Carrera()
    carreras, cambios, fotos = [], [], []
    for j in sorted(carpeta.glob("*.json"), key=lambda f: float(f.stem)) if carpeta.exists() else []:
        try:
            info = json.loads(j.read_text())
        except (OSError, ValueError):
            continue
        dets = [d[:5] + [int(dentro_de_jaula((d[0] + d[2]) / 2, (d[1] + d[3]) / 2, jaula))]
                for d in info.get("dets", [])]
        n = sum(d[5] for d in dets)
        rel = f"{disp}/{dia}/{j.stem}.jpg"
        if n != info.get("n", 0):
            cambios.append({"foto": rel, "ts": info["ts"], "antes": info.get("n", 0), "despues": n, "dets": dets})
        fotos.append((j, info, dets, n))
        if info.get("sin_hora"):
            continue  # no se sabe cuándo se tomó: no entra en las carreras
        cerrada = car.actualizar(info["ts"], n, (info["ts"], rel), info.get("con_wifi", False))
        if cerrada:
            carreras.append(cerrada)
    return carreras, cambios, fotos, car


@app.post("/api/panel/taxi/{disp}/reanalizar", dependencies=[Depends(panel_auth)])
async def reanalizar(disp: str, request: Request):
    """{"dia": "AAAA-MM-DD", "jaula": [[x, y], ...] (opcional: la guardada), "aplicar": false}
    Sin aplicar, solo muestra qué cambiaría. Con aplicar=true reemplaza el conteo
    de las fotos y las carreras de ese día."""
    body = await request.json()
    d = db("SELECT * FROM dispositivos WHERE id = ?", (disp,), one=True)
    if not d:
        raise HTTPException(404)
    dia = str(body.get("dia", ""))
    try:
        ini = datetime.strptime(dia, "%Y-%m-%d").timestamp()
    except ValueError:
        raise HTTPException(400, "Día inválido (AAAA-MM-DD)")
    jaula = body.get("jaula")
    jaula = json.loads(d["jaula"] or "[]") if jaula is None else [[float(x), float(y)] for x, y in jaula]

    carreras, cambios, fotos, car = await run_in_threadpool(reconstruir_dia, disp, dia, jaula)
    antes = db("SELECT * FROM carreras WHERE dispositivo = ? AND inicio >= ? AND inicio < ?", (disp, ini, ini + 86400))
    # Las carreras con WiFi que alguien ya revisó conservan esa decisión (si la
    # carrera nueva empieza casi a la misma hora); las demás quedan por revisar.
    decididas = [c for c in antes if c.get("con_wifi") and not c.get("revisar")]
    for i, c in enumerate(carreras):
        c = a_revisar(disp, c)
        previa = next((p for p in decididas if abs(p["inicio"] - c["inicio"]) < 15), None)
        if previa and c.get("revisar"):
            c = {**c, "valida": previa["valida"], "revisar": 0, "decidida": True}
        carreras[i] = c
    if body.get("aplicar"):
        def aplicar():
            for j, info, dets, n in fotos:
                if n != info.get("n") or dets != info.get("dets"):
                    info["dets"], info["n"] = dets, n
                    j.write_text(json.dumps(info))
            db("DELETE FROM carreras WHERE dispositivo = ? AND inicio >= ? AND inicio < ?", (disp, ini, ini + 86400))
            for c in carreras:
                guardar_carrera(disp, c, anotar=False)
            evento(disp, f"día {dia} reanalizado con jaula de {len(jaula)} esquinas: {len(carreras)} carreras, "
                         f"{len(cambios)} fotos cambiaron de conteo", nivel="aviso")
            if dia == datetime.now().strftime("%Y-%m-%d"):
                with _carreras_lock:
                    _carreras[disp] = car  # la carrera en curso sigue con el conteo nuevo
                    guardar_estado(disp, car)
        await run_in_threadpool(aplicar)
    return {"antes": _resumen_carreras(antes), "despues": _resumen_carreras(carreras),
            "fotos": len(fotos), "cambios": len(cambios),
            "quitadas": sum(1 for c in cambios if c["despues"] < c["antes"]),
            "agregadas": sum(1 for c in cambios if c["despues"] > c["antes"]),
            "ejemplos": cambios[:60], "aplicado": bool(body.get("aplicar")),
            "carreras": [{**{k: c[k] for k in ("inicio", "fin", "duracion", "max_pax", "pasajeros", "valida")},
                          "revisar": c.get("revisar", 0)} for c in carreras]}


@app.get("/api/panel/taxi/{disp}/registro", dependencies=[Depends(panel_auth)])
def registro_taxi(disp: str, limite: int = 500, nivel: str = "", buscar: str = "", antes_de: int = 0):
    """Eventos de una cámara (lo que anotó ella y lo que anotó el servidor),
    del más nuevo al más viejo. `antes_de` = id para pedir más viejos."""
    sql, args = "SELECT * FROM eventos WHERE dispositivo = ?", [disp]
    if nivel in ("error", "aviso", "info"):
        sql += " AND nivel = ?"
        args.append(nivel)
    if buscar:
        sql += " AND texto LIKE ?"
        args.append(f"%{buscar}%")
    if antes_de:
        sql += " AND id < ?"
        args.append(antes_de)
    sql += " ORDER BY id DESC LIMIT ?"
    args.append(min(limite, 2000))
    filas = db(sql, args)
    resumen = {r["nivel"]: r["n"] for r in db(
        "SELECT nivel, COUNT(*) AS n FROM eventos WHERE dispositivo = ? AND recibido > ? GROUP BY nivel",
        (disp, time.time() - 86400))}
    return {"eventos": filas, "ultimas_24h": resumen}


@app.get("/api/panel/taxi/{disp}/registro/diagnostico", dependencies=[Depends(panel_auth)])
def registro_diagnostico(disp: str, horas: int = 24):
    """Problemas encontrados en el registro de las últimas `horas`."""
    filas = db("SELECT recibido, texto FROM eventos WHERE dispositivo = ? AND recibido > ?",
               (disp, time.time() - min(horas, 24 * 30) * 3600))
    return {"problemas": diagnostico.problemas(filas), "lineas": len(filas)}


def _fotos_cerca(disp, t, cuantas=6):
    """Las fotos del taxi más cercanas al momento `t` (en orden), para ver qué
    mostraba la cámara cuando se anotó una línea del registro."""
    candidatas = []
    for dia in {datetime.fromtimestamp(t + d).strftime("%Y-%m-%d") for d in (-3600, 0, 3600)}:
        carpeta = _carpeta_taxi(disp) / dia
        if carpeta.exists():
            candidatas += [j for j in carpeta.glob("*.json") if abs(float(j.stem) - t) < 30 * 60]
    out = []
    for j in sorted(candidatas, key=lambda j: abs(float(j.stem) - t))[:cuantas]:
        try:
            info = json.loads(j.read_text())
        except (OSError, ValueError):
            continue
        if j.with_suffix(".jpg").exists():
            out.append({"foto": f"{disp}/{j.parent.name}/{j.stem}.jpg", "ts": info["ts"], "n": info.get("n", 0),
                        "aprox": info.get("aprox", False), "dif_s": round(info["ts"] - t)})
    return sorted(out, key=lambda f: f["ts"])


@app.get("/api/panel/taxi/{disp}/registro/{eid}", dependencies=[Depends(panel_auth)])
def registro_detalle(disp: str, eid: int):
    """Una línea del registro explicada: qué significa, qué hacer, sus valores,
    las fotos de ese momento y las líneas de alrededor."""
    e = db("SELECT * FROM eventos WHERE dispositivo = ? AND id = ?", (disp, eid), one=True)
    if not e:
        raise HTTPException(404)
    momento, exacta = diagnostico.hora_camara(e["texto"], e["recibido"])
    alrededor = db("SELECT * FROM eventos WHERE dispositivo = ? AND id BETWEEN ? AND ? ORDER BY id",
                   (disp, eid - 6, eid + 6))
    return {"evento": e, "explicacion": diagnostico.explicar(e["texto"]), "valores": diagnostico.estado(e["texto"]),
            "momento": momento, "hora_exacta": exacta, "fotos": _fotos_cerca(disp, momento),
            "alrededor": alrededor}


@app.get("/api/panel/taxi/{disp}/registro.txt", dependencies=[Depends(panel_auth)])
def registro_taxi_txt(disp: str):
    """Registro completo de la cámara, para descargarlo."""
    p = LOGS_CAMARAS / f"{disp}.log"
    if not p.exists() or ".." in disp:
        raise HTTPException(404)
    return FileResponse(p, media_type="text/plain; charset=utf-8", filename=f"registro_{disp}.log")


@app.get("/api/panel/servidor.log", dependencies=[Depends(panel_auth)])
def registro_servidor():
    """Registro del servidor (el archivo actual), para descargarlo."""
    return FileResponse(LOGS / "servidor.log", media_type="text/plain; charset=utf-8", filename="servidor.log")


@app.get("/api/panel/taxi/{disp}/foto_info", dependencies=[Depends(panel_auth)])
def foto_info(disp: str, foto: str):
    """Dónde vio a cada persona el servidor en una foto (para dibujar la jaula encima)."""
    p = (FOTOS / foto).with_suffix(".json")
    if not foto.startswith(disp + "/") or ".." in foto or not p.exists():
        raise HTTPException(404)
    return json.loads(p.read_text())


@app.post("/api/panel/taxi/{disp}", dependencies=[Depends(panel_auth)])
async def editar_taxi(disp: str, request: Request):
    body = await request.json()
    if not db("SELECT id FROM dispositivos WHERE id = ?", (disp,), one=True):
        raise HTTPException(404)
    if "nombre" in body:
        db("UPDATE dispositivos SET nombre = ? WHERE id = ?", (str(body["nombre"])[:60], disp))
    if "aprobado" in body:
        db("UPDATE dispositivos SET aprobado = ? WHERE id = ?", (int(bool(body["aprobado"])), disp))
    if "ajustes" in body:
        # Solo valores conocidos: se mandan tal cual a la cámara.
        nuevos = {}
        for k, v in dict(body["ajustes"]).items():
            validos = AJUSTES_CAMARA.get(k)
            if validos is None:
                raise HTTPException(400, f"Ajuste desconocido: {k}")
            v = type(validos[0])(v)
            if v not in validos:
                raise HTTPException(400, f"Valor inválido para {k}: {v}")
            nuevos[k] = v
        actual = json.loads(db("SELECT ajustes FROM dispositivos WHERE id = ?", (disp,), one=True)["ajustes"] or "{}")
        actual.update(nuevos)
        db("UPDATE dispositivos SET ajustes = ?, ajustes_ver = ajustes_ver + 1 WHERE id = ?", (json.dumps(actual), disp))
        evento(disp, f"ajustes enviados desde el panel: {nuevos}", nivel="info")
    if "contar_con_wifi" in body:
        # El conductor usa internet (hotspot) en el taxi: las carreras con WiFi cuentan solas.
        v = int(bool(body["contar_con_wifi"]))
        db("UPDATE dispositivos SET contar_con_wifi = ? WHERE id = ?", (v, disp))
        evento(disp, "las carreras con WiFi " + ("cuentan solas (hay internet en el taxi)" if v
                     else "quedan por revisar (con WiFi suele estar en casa)"), nivel="info")
    if "dueno" in body:
        uid = body["dueno"]
        dueno = db("SELECT * FROM duenos WHERE id = ?", (int(uid),), one=True) if uid is not None else None
        if uid is not None and not dueno:
            raise HTTPException(400, "Ese dueño no existe")
        db("UPDATE dispositivos SET dueno = ? WHERE id = ?", (dueno and dueno["id"], disp))
        evento(disp, f"dueño del taxi: {dueno['nombre'] or dueno['usuario']}" if dueno else "taxi sin dueño asignado",
               nivel="info")
    if "olvidar_red" in body or "no_olvidar" in body:
        # Quitar una red guardada de la cámara: se le pide con la respuesta a su
        # próximo envío (necesita internet), hasta que deje de informarla.
        fila = db("SELECT redes, wifi_olvidar FROM dispositivos WHERE id = ?", (disp,), one=True)
        pendientes = json.loads(fila["wifi_olvidar"] or "[]")
        if "olvidar_red" in body:
            ssid = str(body["olvidar_red"])
            if ssid not in json.loads(fila["redes"] or "[]"):
                raise HTTPException(400, "La cámara no tiene guardada esa red")
            pendientes = pendientes + [ssid] if ssid not in pendientes else pendientes
            db("UPDATE dispositivos SET wifi_orden = COALESCE(wifi_orden, 0) + 1 WHERE id = ?", (disp,))  # orden nueva
            evento(disp, f"pedido desde el panel: quitar la red WiFi '{ssid}' (en el próximo envío de la cámara)", nivel="info")
        else:
            pendientes = [s for s in pendientes if s != str(body["no_olvidar"])]
        db("UPDATE dispositivos SET wifi_olvidar = ? WHERE id = ?", (json.dumps(pendientes), disp))
    if "abrir_portal" in body:
        db("UPDATE dispositivos SET abrir_portal = ? WHERE id = ?", (int(bool(body["abrir_portal"])), disp))
        if body["abrir_portal"]:
            evento(disp, "pedido desde el panel: abrir la red Taxiff-Cam 10 min (en el próximo envío de la cámara)", nivel="info")
    if "jaula" in body:
        jaula = [[min(1, max(0, float(x))), min(1, max(0, float(y)))] for x, y in body["jaula"]][:20]
        db("UPDATE dispositivos SET jaula = ? WHERE id = ?", (json.dumps(jaula), disp))
        evento(disp, f"jaula guardada: {len(jaula)} esquinas" if jaula else "jaula quitada (cuenta a todos)", nivel="info")
    if body.get("reiniciar_token"):
        # La cámara podrá registrarse de nuevo (p. ej. si se borró su memoria).
        db("UPDATE dispositivos SET token_hash = NULL WHERE id = ?", (disp,))
        evento(disp, "se permitió que la cámara se registre de nuevo", nivel="aviso")
    return {"ok": True}


@app.get("/api/panel/carreras", dependencies=[Depends(panel_auth)])
def carreras(limite: int = 200):
    rows = db("SELECT c.*, d.nombre FROM carreras c LEFT JOIN dispositivos d ON d.id = c.dispositivo "
              "ORDER BY c.inicio DESC LIMIT ?", (min(limite, 1000),))
    for c in rows:
        c["fotos"] = json.loads(c["fotos"] or "[]")
        c["eventos"] = json.loads(c.get("eventos") or "[]")
    return rows


@app.get("/api/panel/carreras.csv", dependencies=[Depends(panel_auth)])
def carreras_csv(desde: str = "", hasta: str = ""):
    """Carreras para Excel. Fechas opcionales AAAA-MM-DD (hasta = inclusive)."""
    ini, fin = _rango_fechas(desde, hasta)
    rows = db("SELECT c.*, d.nombre FROM carreras c LEFT JOIN dispositivos d ON d.id = c.dispositivo "
              "WHERE c.inicio >= ? AND c.inicio < ? ORDER BY c.inicio", (ini, fin))
    tarifas = {d["id"]: tarifa_de(d) for d in db("SELECT id, tarifa FROM dispositivos")}
    for c in rows:
        c.update(estimar(c, tarifas.get(c["dispositivo"], TARIFA), recorrido_de(c["dispositivo"], c["inicio"], c["fin"])))
    return _csv(rows, "carreras.csv", con_camara=True)


def _rango_fechas(desde, hasta):
    try:
        ini = datetime.fromisoformat(desde).timestamp() if desde else 0
        fin = datetime.fromisoformat(hasta).timestamp() + 86400 if hasta else 1e12
    except ValueError:
        raise HTTPException(400, "Fecha inválida (AAAA-MM-DD)")
    return ini, fin


def _csv(carreras, nombre, con_camara=False):
    import csv
    import io
    out = io.StringIO()
    w = csv.writer(out, delimiter=";")
    num = lambda v, f="{:.1f}": f.format(v).replace(".", ",")  # coma decimal para Excel en español
    w.writerow((["camara", "taxi"] if con_camara else ["chofer"]) +
               ["inicio", "fin", "duracion_min", "pasajeros_distintos", "pasajeros_max_a_la_vez",
                "km_estimados", "cobro_estimado_usd", "tarifa"] + (["valida"] if con_camara else []))
    for c in carreras:
        w.writerow(([c["dispositivo"], c.get("nombre") or ""] if con_camara else [c.get("chofer", "")]) +
                   [datetime.fromtimestamp(c["inicio"]).strftime("%Y-%m-%d %H:%M:%S"),
                    datetime.fromtimestamp(c["fin"]).strftime("%Y-%m-%d %H:%M:%S"),
                    num(c["duracion"] / 60), c["pasajeros"] or c["max_pax"], c["max_pax"],
                    num(c["km"]), num(c["cobro"], "{:.2f}"), "nocturna" if c["noche"] else "diurna"] +
                   (["si" if c["valida"] else "no"] if con_camara else []))
    # BOM para que Excel abra bien las tildes.
    return Response("﻿" + out.getvalue(), media_type="text/csv; charset=utf-8",
                    headers={"Content-Disposition": f"attachment; filename={nombre}"})


@app.get("/api/panel/config", dependencies=[Depends(panel_auth)])
def ver_config():
    return {"difuminar": config("difuminar", False)}


@app.post("/api/panel/config", dependencies=[Depends(panel_auth)])
async def cambiar_config(request: Request):
    """{"difuminar": true}: desde ahora, las personas se desenfocan en las fotos
    que se guardan (las ya guardadas no cambian)."""
    body = await request.json()
    if "difuminar" in body:
        v = bool(body["difuminar"])
        db("INSERT INTO config (clave, valor) VALUES ('difuminar', ?) ON CONFLICT(clave) DO UPDATE SET valor = excluded.valor",
           (json.dumps(v),))
        log.warning(f"difuminar caras: {'activado' if v else 'desactivado'} desde el panel")
    return ver_config()


@app.post("/api/panel/firmware", dependencies=[Depends(panel_auth)])
async def subir_firmware(request: Request, version: str):
    """Sube un firmware nuevo (el .bin que genera arduino-cli). Las cámaras lo instalan solas."""
    if not all(p.isdigit() for p in version.split(".")):
        raise HTTPException(400, "Versión inválida (ej. 1.5)")
    datos = await request.body()
    if len(datos) < 100_000 or datos[0] != 0xE9:  # 0xE9 = cabecera de imagen ESP32
        raise HTTPException(400, "No parece un firmware de ESP32")
    (FIRMWARE / f"taxiff_cam-{version}.bin").write_bytes(datos)
    log.warning(f"firmware {version} publicado ({len(datos) // 1024} KB): las cámaras se actualizarán")
    return {"ok": True, "version": version}


@app.get("/fotos/{ruta:path}", dependencies=[Depends(panel_auth)])
def ver_foto(ruta: str):
    p = (FOTOS / ruta).resolve()
    if FOTOS.resolve() not in p.parents or not p.exists():
        raise HTTPException(404)
    return FileResponse(p)


@app.get("/")
def inicio(request: Request):
    return _pagina(request, "index.html", solo_admin=True)


@app.get("/taxi/{disp}")
def pagina_taxi(disp: str, request: Request):
    return _pagina(request, "taxi.html", solo_admin=True)

# ---------------------------------------------------------------- dueños: carreras con cobro y km estimados
#
# El ESP32 no tiene GPS: los km de una carrera salen de su duración y una
# velocidad media en ciudad, y el cobro, de la tarifa del taxímetro. Si algún
# día llegan posiciones (tabla "posiciones": módulo GPS en la cámara o el
# celular del conductor, por /api/v1/posiciones), los km salen del recorrido
# real y el mapa de la carrera se dibuja solo.

# Tarifa de referencia del taxímetro en Loja (arranque y mínima conocidas; el
# valor por km es aproximado). Cada dueño la ajusta en su página.
TARIFA = {"arranque": 0.40, "km": 0.30, "minima": 1.25,
          "arranque_noche": 0.50, "km_noche": 0.35, "minima_noche": 1.40,
          "noche_desde": 19, "noche_hasta": 6, "vel_kmh": 18, "ajustar": 0,
          "cuenta": 0}  # cuenta diaria pactada con el chofer, si el taxi no tiene turnos (0 = no hay)
LIMITES_TARIFA = {"arranque": (0, 20), "km": (0, 10), "minima": (0, 50), "arranque_noche": (0, 20),
                  "km_noche": (0, 10), "minima_noche": (0, 50), "noche_desde": (0, 23), "noche_hasta": (0, 23),
                  "vel_kmh": (5, 80), "ajustar": (0, 1), "cuenta": (0, 1000)}
ENTEROS_TARIFA = ("noche_desde", "noche_hasta", "ajustar")
# Sin dos lecturas del odómetro, se supone que por cada km con pasajeros el taxi
# anda medio km vacío (buscando clientes o volviendo). Con lecturas se calcula.
FACTOR_VACIO = 1.5


def tarifa_de(d):
    try:
        propia = json.loads(d.get("tarifa") or "{}")
    except ValueError:
        propia = {}
    return {**TARIFA, **{k: v for k, v in propia.items() if k in TARIFA}}


def es_noche(ts, t):
    h = datetime.fromtimestamp(ts).hour
    a, b = t["noche_desde"], t["noche_hasta"]
    return (h >= a or h < b) if a > b else a <= h < b


def km_recorrido(puntos):
    """Km de un recorrido GPS [[ts, lat, lon], ...]. Los saltos imposibles (más
    de 150 km/h, un GPS que se confunde) no se suman."""
    total = 0
    for (t1, la1, lo1), (t2, la2, lo2) in zip(puntos, puntos[1:]):
        p1, p2 = math.radians(la1), math.radians(la2)
        a = math.sin((p2 - p1) / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(math.radians(lo2 - lo1) / 2) ** 2
        tramo = 2 * 6371 * math.asin(math.sqrt(a))
        if tramo <= max(t2 - t1, 1) * 150 / 3600 + 0.05:
            total += tramo
    return total


def recorrido_de(disp, inicio, fin):
    return [[r["ts"], r["lat"], r["lon"]] for r in db(
        "SELECT ts, lat, lon FROM posiciones WHERE dispositivo = ? AND ts BETWEEN ? AND ? ORDER BY ts",
        (disp, inicio, fin))]


def estimar(c, t, puntos):
    """Km y cobro estimados de una carrera con la tarifa `t` (diurna o nocturna
    según la hora de inicio): arranque + km × valor por km, nunca menos que la mínima."""
    noche = es_noche(c["inicio"], t)
    s = "_noche" if noche else ""
    gps = len(puntos) >= 2
    km = km_recorrido(puntos) if gps else c["duracion"] / 3600 * t["vel_kmh"]
    cobro = max(t["minima" + s], t["arranque" + s] + km * t["km" + s])
    return {"km": round(km, 1), "cobro": round(cobro, 2), "noche": noche, "km_de": "gps" if gps else "tiempo",
            "calculo": {"arranque": t["arranque" + s], "por_km": t["km" + s], "minima": t["minima" + s]}}


def turnos_de(disp):
    return db("SELECT id, nombre, desde, hasta, cuenta FROM turnos WHERE dispositivo = ? ORDER BY desde", (disp,))


def _horas_turno(t):
    return {h % 24 for h in range(t["desde"], t["hasta"] + (24 if t["hasta"] <= t["desde"] else 0))}


def jornada(ts, turnos):
    """(turno, día de la jornada) de una carrera que empezó en `ts`. Un turno que
    pasa la medianoche (18:00 → 06:00) cuenta para el día en que empezó, que es
    el que se liquida. Fuera de todo turno: (0, el día del calendario)."""
    dt = datetime.fromtimestamp(ts)
    for t in turnos:
        if dt.hour in _horas_turno(t):
            if t["hasta"] <= t["desde"] and dt.hour < t["hasta"]:
                dt -= timedelta(days=1)
            return t["id"], dt.strftime("%Y-%m-%d")
    return 0, dt.strftime("%Y-%m-%d")


def _umbral_larga(disp):
    """Una carrera es atípica por larga si dura más de 40 min y más de 2,5 veces
    lo normal de ese taxi (mediana de los últimos 30 días)."""
    durs = [r["duracion"] for r in db("SELECT duracion FROM carreras WHERE dispositivo = ? AND valida = 1 AND inicio > ?",
                                      (disp, time.time() - 30 * 86400))]
    return max(40 * 60, 2.5 * statistics.median(durs)) if durs else 40 * 60


def carreras_dueno(d, desde, hasta, con_recorrido=False, ajuste=1.0):
    """Carreras válidas de un taxi para su dueño: sin fotos, con el cobro y los km
    estimados, su turno (chofer) y jornada, y si es atípica. `ajuste` multiplica
    el cobro (la calibración con el taxímetro, ver ajuste_cobro)."""
    t, turnos, larga = tarifa_de(d), turnos_de(d["id"]), _umbral_larga(d["id"])
    nombres = {x["id"]: x["nombre"] for x in turnos}
    out = []
    for c in db("SELECT id, inicio, fin, duracion, max_pax, pasajeros, eventos FROM carreras "
                "WHERE dispositivo = ? AND valida = 1 AND inicio >= ? AND inicio < ? ORDER BY inicio",
                (d["id"], desde, hasta)):
        puntos = recorrido_de(d["id"], c["inicio"], c["fin"])
        c["pasajeros"] = c["pasajeros"] or c["max_pax"]
        c["eventos"] = json.loads(c["eventos"] or "[]")
        c.update(estimar(c, t, puntos))
        c["cobro_tarifa"], c["ajuste"] = c["cobro"], ajuste
        c["cobro"] = round(c["cobro"] * ajuste, 2)
        c["turno"], c["jornada"] = jornada(c["inicio"], turnos)
        c["chofer"] = nombres.get(c["turno"], "")
        c["atipica"] = f"muy larga: lo normal es menos de {round(larga / 60)} min" if c["duracion"] >= larga else None
        if con_recorrido:
            c["recorrido"] = puntos
        out.append(c)
    return out


def _sumar(carreras):
    return {"carreras": len(carreras), "pasajeros": sum(c["pasajeros"] for c in carreras),
            "tiempo_s": sum(c["duracion"] for c in carreras), "km": round(sum(c["km"] for c in carreras), 1),
            "cobro": round(sum(c["cobro"] for c in carreras), 2)}


def _dia_de(ts):
    return datetime.fromtimestamp(ts).strftime("%Y-%m-%d")


def _por_dia(carreras):
    """Carreras agrupadas por jornada (la de su turno; sin turnos, el día)."""
    dias = {}
    for c in carreras:
        dias.setdefault(c["jornada"], []).append(c)
    return dias


def _estimado(por_dia, dia, turno):
    """≈ cobro de una liquidación: la jornada entera (turno 0) o solo ese turno."""
    return sum(c["cobro"] for c in por_dia.get(dia, []) if not turno or c["turno"] == turno)


def ajuste_cobro(d):
    """Calibración con el taxímetro. Mediana de liquidado / estimado en los últimos
    60 días (al menos 3 liquidaciones con algo de trabajo; un día raro no la mueve):
    - "medido": solo con lecturas del TAXÍMETRO. Corrige lo que la tarifa y la
      velocidad promedio no aciertan (tráfico, recorridos de la ciudad). Si el
      dueño la activa ("ajustar"), multiplica los estimados.
    - "chofer": lo mismo con lo que DIJO el chofer. Solo se muestra: nunca
      corrige nada, porque si reportara siempre de menos lo escondería."""
    desde = _medianoche(datetime.now() - timedelta(days=60))
    reps = db("SELECT dia, turno, monto, fuente FROM reportes WHERE dispositivo = ? AND dia >= ? AND monto IS NOT NULL",
              (d["id"], desde.strftime("%Y-%m-%d")))
    razones = {"taximetro": [], "chofer": []}
    if reps:
        por_dia = _por_dia(carreras_dueno(d, (desde - timedelta(days=1)).timestamp(), 1e12))
        for r in reps:
            est = _estimado(por_dia, r["dia"], r["turno"])
            if est >= 3:
                razones[r["fuente"]].append(r["monto"] / est)
    mediana = lambda xs: round(statistics.median(xs), 2) if len(xs) >= 3 else None
    medido = mediana(razones["taximetro"])
    return {"medido": medido, "dias": len(razones["taximetro"]),
            "chofer": mediana(razones["chofer"]), "dias_chofer": len(razones["chofer"]),
            "factor": min(2.0, max(0.5, medido)) if medido and tarifa_de(d)["ajustar"] else 1.0}


def mantenimientos(d, odo):
    """Cada tarea de mantenimiento con cuántos km le faltan según el kilometraje estimado."""
    est = odo["estimado"]
    out = []
    for m in db("SELECT id, nombre, cada_km, ultimo_km FROM mantenimiento WHERE dispositivo = ? ORDER BY id", (d["id"],)):
        proximo = m["ultimo_km"] + m["cada_km"]
        faltan = None if est is None else round(proximo - est)
        estado = "sin_km" if faltan is None else "vencido" if faltan <= 0 else \
            "pronto" if faltan <= max(300, m["cada_km"] * 0.1) else "ok"
        out.append({**m, "proximo_km": proximo, "faltan_km": faltan, "estado": estado})
    return out


def _usd(v):
    return f"${v:.2f}".replace(".", ",")


def _fecha_corta(dia):
    d = datetime.strptime(dia, "%Y-%m-%d")
    return f"{('lun', 'mar', 'mié', 'jue', 'vie', 'sáb', 'dom')[d.weekday()]} {d.day}"


def avisos_dueno(taxi, odo, mants, todas, reportes, hoy):
    """Lo que el dueño debería mirar, del más importante al menos. Cada aviso:
    nivel (mal / aviso / info), título, texto y a qué pestaña lleva."""
    out = []
    # Posible sabotaje (cámara tapada, carreras cortadas): las de los últimos 3 días.
    for a in db("SELECT ts, titulo, texto FROM alertas WHERE dispositivo = ? AND ts > ? ORDER BY ts DESC LIMIT 5",
                (taxi["id"], time.time() - 3 * 86400)):
        out.append({"nivel": "mal", "ir": "carreras:" + _dia_de(a["ts"]), "titulo": a["titulo"], "texto": a["texto"]})
    hace = taxi["camara"]["hace_s"]
    if taxi["camara"]["estado"] == "sin_conexion" and hace is None:
        out.append({"nivel": "aviso", "titulo": "La cámara todavía no se conecta", "ir": None,
                    "texto": "Cuando se conecte a una WiFi por primera vez, aquí aparecerán las carreras."})
    elif taxi["camara"]["estado"] == "sin_conexion" and hace > 36 * 3600:
        out.append({"nivel": "aviso", "titulo": "La cámara no sube datos hace más de un día",
                    "texto": "Graba igual sin internet. Las carreras aparecen cuando se conecte a una WiFi. "
                             "Si el taxi está trabajando, revisa que la cámara esté encendida.", "ir": None})
    for m in mants:
        if m["estado"] in ("vencido", "pronto"):
            vencido = m["estado"] == "vencido"
            out.append({"nivel": "mal" if vencido else "aviso", "ir": "km",
                        "titulo": f"{m['nombre']}: {'ya toca' if vencido else 'falta poco'}",
                        "texto": (f"Se pasó por ≈ {-m['faltan_km']:,} km." if vencido else
                                  f"Faltan ≈ {m['faltan_km']:,} km.").replace(",", ".") +
                        " Cuando lo hagas, márcalo como hecho en la pestaña Taxi (o anota el gasto en Dinero)."})
    dias = _por_dia(todas)
    # Solo lo que DIJO el chofer: una lectura del taxímetro baja no es plata que falta.
    choferes = {c["turno"]: c["chofer"] for c in todas}
    for r in sorted((r for r in reportes if r["fuente"] == "chofer" and r["monto"] is not None),
                    key=lambda r: r["dia"], reverse=True)[:7]:
        est = _estimado(dias, r["dia"], r["turno"])
        if est >= 3 and r["monto"] < est * 0.8:
            quien = f" ({choferes[r['turno']]})" if choferes.get(r["turno"]) else ""
            out.append({"nivel": "aviso", "ir": "carreras:" + r["dia"],
                        "titulo": f"El {_fecha_corta(r['dia'])}{quien} dijo que cobró {round(100 * (1 - r['monto'] / est))} % menos",
                        "texto": f"Dijo {_usd(r['monto'])}; Taxiff estimó ≈ {_usd(est)}. Revisa las carreras de ese día."})
    tramo = (odo.get("tramos") or [None])[0]
    if tramo and tramo["km"] >= 30 and tramo["ocupacion"] is not None and tramo["ocupacion"] < 0.35:
        sin_nada = tramo["con_pax"] == 0
        out.append({"nivel": "mal" if sin_nada else "aviso", "ir": "km",
                    "titulo": (f"El taxi anduvo {tramo['km']:,} km sin ninguna carrera" if sin_nada else
                               f"Muchos km vacíos: solo {round(100 * tramo['ocupacion'])} % con pasajeros").replace(",", "."),
                    "texto": f"Entre el {_fecha_corta(_dia_de(tramo['desde']))} y el {_fecha_corta(_dia_de(tramo['hasta']))} "
                             f"marcó {tramo['km']:,} km en el odómetro y Taxiff vio ≈ {round(tramo['con_pax']):,} km con pasajeros. ".replace(",", ".") +
                             "Puede ser uso personal, carreras con la cámara tapada o apagada, o mucho tiempo buscando clientes."})
    ayer = (hoy - timedelta(days=1)).strftime("%Y-%m-%d")
    previos = [len(dias[x]) for x in dias if x < ayer and x >= (hoy - timedelta(days=15)).strftime("%Y-%m-%d")]
    if len(previos) >= 7 and dias.get(ayer):
        normal = statistics.mean(previos)
        if normal >= 4 and len(dias[ayer]) < normal * 0.5:
            out.append({"nivel": "info", "ir": "carreras:" + ayer,
                        "titulo": f"Ayer hubo pocas carreras: {len(dias[ayer])}",
                        "texto": f"Lo normal en las últimas 2 semanas es {round(normal)} por día."})
    if odo["estimado"] is not None and time.time() - odo["ultima"]["fecha"] > 30 * 86400:
        out.append({"nivel": "info", "ir": "km", "titulo": "Anota el odómetro",
                    "texto": "La última lectura tiene más de un mes. Con una nueva, el kilometraje es más exacto."})
    orden = {"mal": 0, "aviso": 1, "info": 2}
    return sorted(out, key=lambda a: orden[a["nivel"]])


def odometro(d):
    """Lecturas del odómetro que anotó el dueño y el kilometraje estimado de hoy:
    la última lectura + los km con pasajeros desde entonces × cuánto anda el taxi
    en total por cada km con pasajeros (de sus lecturas, o FACTOR_VACIO)."""
    lecturas = db("SELECT id, fecha, km, nota FROM odometro WHERE dispositivo = ? ORDER BY fecha, id", (d["id"],))
    base = {"lecturas": lecturas[::-1], "factor": FACTOR_VACIO, "factor_de": "referencia", "tramos": []}
    if not lecturas:
        return {**base, "estimado": None}
    primera, ultima = lecturas[0], lecturas[-1]
    km_con = lambda a, b: sum(c["km"] for c in carreras_dueno(d, a, b))
    # Entre cada par de lecturas: km que marcó el odómetro y cuántos de esos fueron
    # con pasajeros. Los "km vacíos" altos delatan uso personal o carreras sin cámara.
    tramos = []
    for a, b in zip(lecturas, lecturas[1:]):
        recorridos, con = b["km"] - a["km"], km_con(a["fecha"], b["fecha"])
        tramos.append({"desde": a["fecha"], "hasta": b["fecha"], "km": round(recorridos), "con_pax": round(con, 1),
                       "ocupacion": round(min(1.0, con / recorridos), 2) if recorridos > 0 else None})
    base["tramos"] = tramos[::-1]
    con_entre = km_con(primera["fecha"], ultima["fecha"])
    if ultima["fecha"] - primera["fecha"] >= 3 * 86400 and con_entre >= 10 and ultima["km"] > primera["km"]:
        base["factor"] = round(min(4.0, max(1.0, (ultima["km"] - primera["km"]) / con_entre)), 2)
        base["factor_de"] = "lecturas"
    con_pax = km_con(ultima["fecha"], time.time() + 1)
    estimado = ultima["km"] + con_pax * base["factor"]
    return {**base, "estimado": round(estimado), "inicio": primera, "ultima": ultima,
            "desde_ultima": round(estimado - ultima["km"]), "desde_ultima_con_pax": round(con_pax, 1),
            "desde_inicio": round(estimado - primera["km"])}


_CAMARA_DUENO = {
    "recibiendo": ("Cámara funcionando", "Las carreras aparecen al momento."),
    "subiendo": ("Poniéndose al día", "Está subiendo lo que grabó sin internet. Las carreras de esas horas aparecen al terminar."),
    "sin_fotos": ("Conectada, esperando datos", "Si sigue así más de una hora, avisa a Taxiff."),
}


def taxi_para_dueno(d):
    """Lo que el dueño ve de su taxi: nada de fotos, IP ni ajustes de la cámara."""
    con = _conexion(d, time.time())
    titulo, detalle = _CAMARA_DUENO.get(con["estado"], (con["titulo"],
        "La cámara graba igual y sube todo al volver a tener internet. Si el taxi trabajó y sigue así más de un día, avisa a Taxiff."))
    with _carreras_lock:
        c = carrera_de(d["id"])
        en_carrera = c.estado == "EN_CARRERA"
        carrera_s = int(c.ultima_ts - c.inicio) if en_carrera else 0
    return {"id": d["id"], "nombre": d["nombre"] or d["id"], "en_carrera": en_carrera, "carrera_s": carrera_s,
            "pasajeros_ahora": d["pax"] if en_carrera else 0, "tarifa": tarifa_de(d),
            "camara": {"estado": con["estado"], "titulo": titulo, "detalle": detalle, "hace_s": con["contacto_hace_s"]}}


def taxi_de(cuenta, disp):
    """El taxi, si la cuenta puede verlo (el admin, todos; un dueño, los suyos)."""
    d = db("SELECT * FROM dispositivos WHERE id = ?", (disp,), one=True)
    if not d or (cuenta["rol"] != "admin" and d["dueno"] != cuenta["id"]):
        raise HTTPException(404)
    return d


def _medianoche(dt):
    return dt.replace(hour=0, minute=0, second=0, microsecond=0)


@app.get("/api/dueno/yo")
def yo(como: int = 0, cuenta=Depends(cuenta_auth)):
    """La cuenta y sus taxis. El admin puede ver la página como un dueño (`como`
    = id del dueño) o, sin `como`, con todos los taxis."""
    dueno = cuenta
    if cuenta["rol"] == "admin" and como:
        dueno = db("SELECT * FROM duenos WHERE id = ?", (como,), one=True)
        if not dueno:
            raise HTTPException(404)
    taxis = db("SELECT * FROM dispositivos ORDER BY creado") if dueno is ADMIN else \
        db("SELECT * FROM dispositivos WHERE dueno = ? ORDER BY creado", (dueno["id"],))
    return {"nombre": dueno["nombre"] or dueno["usuario"], "usuario": dueno["usuario"], "rol": cuenta["rol"],
            "viendo_como": dueno is not cuenta, "taxis": [taxi_para_dueno(d) for d in taxis]}


@app.get("/api/dueno/taxi/{disp}/resumen")
def resumen_dueno(disp: str, cuenta=Depends(cuenta_auth)):
    """Hoy, esta semana (desde el lunes), este mes y desde el inicio (la primera
    lectura del odómetro), más los últimos 7 días uno por uno."""
    d = taxi_de(cuenta, disp)
    ahora = datetime.now()
    hoy = _medianoche(ahora)
    semana, mes = hoy - timedelta(days=hoy.weekday()), hoy.replace(day=1)
    odo = odometro(d)
    inicio = odo["inicio"]["fecha"] if odo["estimado"] is not None else 0
    ajuste = ajuste_cobro(d)
    todas = carreras_dueno(d, min(inicio, mes.timestamp(), semana.timestamp(), (hoy - timedelta(days=15)).timestamp()),
                           1e12, ajuste=ajuste["factor"])
    desde = lambda dt: [c for c in todas if c["inicio"] >= dt.timestamp()]
    reportes = db("SELECT dia, turno, monto, fuente, entregado FROM reportes WHERE dispositivo = ? AND dia >= ?",
                  (disp, (hoy - timedelta(days=15)).strftime("%Y-%m-%d")))
    reportado, entregado = {}, {}
    for r in reportes:
        if r["monto"] is not None:
            reportado[r["dia"]] = round(reportado.get(r["dia"], 0) + r["monto"], 2)
        if r["entregado"] is not None:
            entregado[r["dia"]] = round(entregado.get(r["dia"], 0) + r["entregado"], 2)
    por_dia = _por_dia(todas)
    dias = [{"dia": x, **_sumar(por_dia.get(x, [])), "reportado": reportado.get(x), "entregado": entregado.get(x)}
            for x in ((hoy - timedelta(days=i)).strftime("%Y-%m-%d") for i in range(7))]
    taxi = taxi_para_dueno(d)
    mants = mantenimientos(d, odo)
    pagos = recordatorios_de(disp)
    periodos = {"hoy": desde(hoy), "semana": desde(semana), "mes": desde(mes),
                "total": [c for c in todas if c["inicio"] >= inicio]}
    turnos = turnos_de(disp)
    return {"taxi": taxi, "odometro": odo, "dias": dias, "ajuste": ajuste, "mantenimiento": mants, "turnos": turnos,
            "recordatorios": pagos,
            "avisos": avisos_pagos(pagos) + avisos_dueno(taxi, odo, mants, todas, reportes, hoy),
            "en_revision": db("SELECT COUNT(*) AS n FROM carreras WHERE dispositivo = ? AND revisar = 1",
                              (disp,), one=True)["n"],
            "periodos": {k: _sumar(v) for k, v in periodos.items()},
            "por_turno": {k: _por_turno(v, turnos) for k, v in periodos.items()} if turnos else None,
            "desde": inicio or (todas[0]["inicio"] if todas else None)}


def _por_turno(carreras, turnos):
    """Totales por turno (chofer); las carreras fuera de todo turno van aparte."""
    grupos = [{"turno": t["id"], "nombre": t["nombre"], "desde": t["desde"], "hasta": t["hasta"],
               **_sumar([c for c in carreras if c["turno"] == t["id"]])} for t in turnos]
    fuera = [c for c in carreras if c["turno"] == 0]
    if fuera:
        grupos.append({"turno": 0, "nombre": "Fuera de turno", "desde": None, "hasta": None, **_sumar(fuera)})
    return grupos


@app.get("/api/dueno/taxi/{disp}/dias")
def dias_dueno(disp: str, cuenta=Depends(cuenta_auth)):
    """Días con carreras, el más reciente primero (siempre incluye hoy)."""
    taxi_de(cuenta, disp)
    dias = [r["dia"] for r in db("SELECT DISTINCT date(inicio, 'unixepoch', 'localtime') AS dia FROM carreras "
                                 "WHERE dispositivo = ? AND valida = 1 ORDER BY dia DESC LIMIT 400", (disp,))]
    hoy = datetime.now().strftime("%Y-%m-%d")
    return ([hoy] if hoy not in dias else []) + dias


@app.get("/api/dueno/taxi/{disp}/carreras")
def carreras_dueno_dia(disp: str, dia: str, cuenta=Depends(cuenta_auth)):
    d = taxi_de(cuenta, disp)
    try:
        ini = datetime.strptime(dia, "%Y-%m-%d").timestamp()
    except ValueError:
        raise HTTPException(400, "Día inválido (AAAA-MM-DD)")
    ajuste = ajuste_cobro(d)
    # La jornada de un turno de noche termina al día siguiente: se piden dos días
    # y quedan las carreras de esta jornada.
    cs = [c for c in carreras_dueno(d, ini, ini + 2 * 86400, ajuste=ajuste["factor"]) if c["jornada"] == dia]
    turnos = turnos_de(disp)
    reportes = {r["turno"]: r for r in db("SELECT turno, monto, fuente, entregado, nota, anotado, por FROM reportes "
                                          "WHERE dispositivo = ? AND dia = ?", (disp, dia))}
    # Una liquidación por turno (o una por día si no hay turnos), con la cuenta pactada.
    grupos = _por_turno(cs, turnos) if turnos else [{"turno": 0, "nombre": "", "desde": None, "hasta": None, **_sumar(cs)}]
    cuentas = _cuentas(d, turnos)
    for g in grupos:
        g["reporte"] = reportes.get(g["turno"])
        g["cuenta"] = cuentas.get(g["turno"])
    return {"carreras": cs, "resumen": _sumar(cs), "ajuste": ajuste, "grupos": grupos,
            "atipicas": sum(1 for c in cs if c["atipica"]),
            "en_revision": db("SELECT COUNT(*) AS n FROM carreras WHERE dispositivo = ? AND revisar = 1 "
                              "AND inicio >= ? AND inicio < ?", (disp, ini, ini + 86400), one=True)["n"]}


@app.post("/api/dueno/taxi/{disp}/reporte")
async def guardar_reporte(disp: str, request: Request, cuenta=Depends(cuenta_auth)):
    """{"dia": "AAAA-MM-DD", "turno": id (0 = todo el día), "monto": 18.5,
    "fuente": "chofer" | "taximetro", "nota": ""}: la liquidación de esa jornada.
    Sin monto, se borra. Solo las del taxímetro calibran los estimados."""
    d = taxi_de(cuenta, disp)
    body = await request.json()
    dia = str(body.get("dia", ""))
    try:
        if datetime.strptime(dia, "%Y-%m-%d") > datetime.now():
            raise ValueError
        turno = int(body.get("turno") or 0)
    except (TypeError, ValueError):
        raise HTTPException(400, "Día o turno inválido")
    if turno and not db("SELECT id FROM turnos WHERE dispositivo = ? AND id = ?", (disp, turno), one=True):
        raise HTTPException(400, "Ese turno no existe")
    # Dos montos, los dos opcionales: lo que el chofer ENTREGÓ al dueño (el ingreso
    # del dueño, p. ej. la cuenta diaria) y lo que COBRÓ en total (el chofer o el taxímetro).
    monto, entregado = _monto(body.get("monto")), _monto(body.get("entregado"))
    if monto is None and entregado is None:
        db("DELETE FROM reportes WHERE dispositivo = ? AND dia = ? AND turno = ?", (disp, dia, turno))
        return {"ok": True, "reporte": None}
    fuente = body.get("fuente") or "chofer"
    if fuente not in ("chofer", "taximetro"):
        raise HTTPException(400, "Fuente: chofer o taximetro")
    db("INSERT INTO reportes (dispositivo, dia, turno, monto, fuente, entregado, nota, anotado, por) "
       "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(dispositivo, dia, turno) DO UPDATE SET monto = excluded.monto, "
       "fuente = excluded.fuente, entregado = excluded.entregado, nota = excluded.nota, anotado = excluded.anotado, por = excluded.por",
       (disp, dia, turno, monto, fuente, entregado, str(body.get("nota") or "")[:120], time.time(), cuenta["usuario"]))
    partes = ([f"entregó {_usd(entregado)}"] if entregado is not None else []) + \
             ([f"cobró {_usd(monto)} ({'taxímetro' if fuente == 'taximetro' else 'dicho por el chofer'})"] if monto is not None else [])
    evento(d["id"], f"liquidación del {dia}{f' (turno {turno})' if turno else ''} anotada por {cuenta['usuario']}: "
                    + ", ".join(partes), nivel="info")
    return {"ok": True, "reporte": {"monto": monto, "fuente": fuente, "entregado": entregado}}


def _monto(v, maximo=2000):
    """Dólares de un formulario: None si está vacío; 400 si no es un número válido."""
    if v in (None, ""):
        return None
    try:
        m = round(float(str(v).replace(",", ".")), 2)
    except ValueError:
        raise HTTPException(400, "Escribe el monto en dólares (solo números)")
    if not 0 <= m <= maximo:
        raise HTTPException(400, "Monto fuera de rango")
    return m


def _cuentas(d, turnos):
    """Cuenta pactada por jornada: la de cada turno o, sin turnos, la del taxi (Ajustes)."""
    if turnos:
        return {t["id"]: t.get("cuenta") for t in turnos}
    return {0: tarifa_de(d)["cuenta"] or None}


@app.get("/api/dueno/taxi/{disp}/turnos")
def turnos_dueno(disp: str, cuenta=Depends(cuenta_auth)):
    return turnos_de(taxi_de(cuenta, disp)["id"])


@app.post("/api/dueno/taxi/{disp}/turnos")
async def guardar_turno(disp: str, request: Request, cuenta=Depends(cuenta_auth)):
    """{"id"?: para editar, "nombre": "Juan", "desde": 6, "hasta": 18} o {"id", "borrar": true}.
    Turnos de un mismo taxi no se pisan. Uno de noche puede pasar la medianoche (18 → 6)."""
    taxi_de(cuenta, disp)
    body = await request.json()
    tid = int(body.get("id") or 0)
    if tid and not db("SELECT id FROM turnos WHERE dispositivo = ? AND id = ?", (disp, tid), one=True):
        raise HTTPException(404)
    if body.get("borrar"):
        db("DELETE FROM turnos WHERE id = ?", (tid,))
        return turnos_de(disp)
    nombre = str(body.get("nombre", "")).strip()[:40]
    try:
        t = {"desde": int(body.get("desde")), "hasta": int(body.get("hasta"))}
    except (TypeError, ValueError):
        raise HTTPException(400, "Las horas van de 0 a 23")
    if not nombre:
        raise HTTPException(400, "Escribe el nombre del chofer (o del turno)")
    if not (0 <= t["desde"] <= 23 and 0 <= t["hasta"] <= 23) or t["desde"] == t["hasta"]:
        raise HTTPException(400, "Las horas van de 0 a 23, y el turno empieza y termina a horas distintas")
    for otro in turnos_de(disp):
        if otro["id"] != tid and _horas_turno(otro) & _horas_turno(t):
            raise HTTPException(400, f"Se pisa con el turno de {otro['nombre']} ({otro['desde']}:00–{otro['hasta']}:00)")
    cuenta_pactada = _monto(body.get("cuenta"), 1000)  # lo que el chofer entrega por jornada
    if tid:
        db("UPDATE turnos SET nombre = ?, desde = ?, hasta = ?, cuenta = ? WHERE id = ?",
           (nombre, t["desde"], t["hasta"], cuenta_pactada, tid))
    else:
        db("INSERT INTO turnos (dispositivo, nombre, desde, hasta, cuenta) VALUES (?, ?, ?, ?, ?)",
           (disp, nombre, t["desde"], t["hasta"], cuenta_pactada))
    return turnos_de(disp)


@app.get("/api/dueno/taxi/{disp}/horas")
def horas_dueno(disp: str, dias: int = 30, turno: int = 0, cuenta=Depends(cuenta_auth)):
    """Cuándo trabaja más el taxi en los últimos `dias`: carreras y ≈ cobro por
    hora del día (total) y por día de la semana (promedio por cada lunes, martes…).
    Con `turno`, solo las carreras de ese turno (chofer)."""
    d = taxi_de(cuenta, disp)
    dias = max(7, min(dias, 120))
    hoy = _medianoche(datetime.now())
    ini = hoy - timedelta(days=dias - 1)
    cs = [c for c in carreras_dueno(d, ini.timestamp(), 1e12, ajuste=ajuste_cobro(d)["factor"])
          if not turno or c["turno"] == turno]
    por_hora = [{"hora": h, "carreras": 0, "cobro": 0.0} for h in range(24)]
    por_dia = [{"dia": i, "carreras": 0, "cobro": 0.0, "veces": 0} for i in range(7)]
    for i in range(dias):
        por_dia[(ini + timedelta(days=i)).weekday()]["veces"] += 1
    for c in cs:
        t = datetime.fromtimestamp(c["inicio"])
        for fila in (por_hora[t.hour], por_dia[t.weekday()]):
            fila["carreras"] += 1
            fila["cobro"] += c["cobro"]
    for fila in por_hora + por_dia:
        fila["cobro"] = round(fila["cobro"], 2)
    return {"dias": dias, "carreras": len(cs), "por_hora": por_hora, "por_dia": por_dia}


@app.get("/api/dueno/taxi/{disp}/mantenimiento")
def mantenimiento_dueno(disp: str, cuenta=Depends(cuenta_auth)):
    d = taxi_de(cuenta, disp)
    return mantenimientos(d, odometro(d))


@app.post("/api/dueno/taxi/{disp}/mantenimiento")
async def crear_mantenimiento(disp: str, request: Request, cuenta=Depends(cuenta_auth)):
    """{"nombre": "Cambio de aceite", "cada_km": 5000, "ultimo_km": 184000 (opcional: el kilometraje estimado de hoy)}."""
    d = taxi_de(cuenta, disp)
    body = await request.json()
    odo = odometro(d)
    nombre = str(body.get("nombre", "")).strip()[:40]
    try:
        cada = float(body.get("cada_km"))
        ultimo = float(body["ultimo_km"]) if body.get("ultimo_km") not in (None, "") else odo["estimado"]
    except (TypeError, ValueError):
        raise HTTPException(400, "Escribe los km con números")
    if not nombre:
        raise HTTPException(400, "Ponle un nombre (ej. cambio de aceite)")
    if not 100 <= cada <= 200_000:
        raise HTTPException(400, "Cada cuántos km: entre 100 y 200.000")
    if ultimo is None:
        raise HTTPException(400, "Escribe a qué kilometraje se hizo la última vez (o anota primero el odómetro)")
    if not 0 <= ultimo < 3_000_000:
        raise HTTPException(400, "Kilometraje fuera de rango")
    db("INSERT INTO mantenimiento (dispositivo, nombre, cada_km, ultimo_km, creado) VALUES (?, ?, ?, ?, ?)",
       (disp, nombre, cada, ultimo, time.time()))
    return mantenimientos(d, odo)


@app.post("/api/dueno/taxi/{disp}/mantenimiento/{mid}")
async def editar_mantenimiento(disp: str, mid: int, request: Request, cuenta=Depends(cuenta_auth)):
    """{"hecho": true, "km": opcional (si no, el kilometraje estimado de hoy)} o {"borrar": true}."""
    d = taxi_de(cuenta, disp)
    body = await request.json()
    m = db("SELECT * FROM mantenimiento WHERE dispositivo = ? AND id = ?", (disp, mid), one=True)
    if not m:
        raise HTTPException(404)
    odo = odometro(d)
    if body.get("borrar"):
        db("DELETE FROM mantenimiento WHERE id = ?", (mid,))
    elif body.get("hecho"):
        try:
            km = float(body["km"]) if body.get("km") not in (None, "") else odo["estimado"]
        except (TypeError, ValueError):
            raise HTTPException(400, "Escribe los km con números")
        if km is None:
            raise HTTPException(400, "Escribe a qué kilometraje se hizo")
        db("UPDATE mantenimiento SET ultimo_km = ? WHERE id = ?", (km, mid))
        evento(disp, f"mantenimiento hecho ({m['nombre']}) a {km:,.0f} km, anotado por {cuenta['usuario']}".replace(",", "."),
               nivel="info")
    return mantenimientos(d, odo)

# ---------------------------------------------------------------- dinero: gastos, pagos y lo que entregan los choferes
#
# Como lo lleva un dueño en su cuaderno o su Excel: lo que entrega cada chofer
# (su cuenta pactada por jornada), los gastos (gasolina, aceite, repuestos,
# cooperativa, seguro…) y lo que queda. Más los pagos que vencen por fecha
# (cooperativa, seguro, matrícula…), que avisan antes y al pagarse quedan como gasto.

CATEGORIAS_GASTO = ("Combustible", "Cambio de aceite", "Filtros", "Llantas", "Frenos", "Batería", "Repuestos",
                    "Reparación mecánica", "Reparación eléctrica", "Lavado", "Matrícula / revisión", "Seguro",
                    "Impuestos / tasas", "Cooperativa", "Otros")
_GRUPOS = {"Combustible": ("Combustible",),
           "Mantenimiento y repuestos": ("Cambio de aceite", "Filtros", "Llantas", "Frenos", "Batería", "Repuestos",
                                         "Reparación mecánica", "Reparación eléctrica"),
           "Pagos fijos y trámites": ("Matrícula / revisión", "Seguro", "Impuestos / tasas", "Cooperativa"),
           "Otros": ("Lavado", "Otros")}
GRUPO_GASTO = {c: g for g, cs in _GRUPOS.items() for c in cs}
FORMAS_PAGO = ("Efectivo", "Transferencia", "Tarjeta", "Otro")
FRECUENCIAS = ("mensual", "anual", "una_vez")


def _fecha(texto, futura=False):
    try:
        f = datetime.strptime(str(texto), "%Y-%m-%d")
    except ValueError:
        raise HTTPException(400, "Fecha inválida (AAAA-MM-DD)")
    if not futura and f > datetime.now() + timedelta(days=1):
        raise HTTPException(400, "La fecha no puede ser futura")
    return f.strftime("%Y-%m-%d")


def _mes(mes):
    """(primer día del mes, primer día del siguiente) de 'AAAA-MM'."""
    try:
        ini = datetime.strptime(mes, "%Y-%m")
    except ValueError:
        raise HTTPException(400, "Mes inválido (AAAA-MM)")
    return ini, (ini.replace(day=28) + timedelta(days=4)).replace(day=1)


def _sumar_meses(fecha, n):
    """La misma fecha n meses después (el 31 pasa al último día de un mes más corto)."""
    import calendar
    d = datetime.strptime(fecha, "%Y-%m-%d")
    m = d.month - 1 + n
    a, m = d.year + m // 12, m % 12 + 1
    return f"{a:04d}-{m:02d}-{min(d.day, calendar.monthrange(a, m)[1]):02d}"


def gastos_de(disp, desde, hasta):
    return db("SELECT id, fecha, categoria, descripcion, monto, km, pago, lugar FROM gastos "
              "WHERE dispositivo = ? AND fecha >= ? AND fecha < ? ORDER BY fecha DESC, id DESC", (disp, desde, hasta))


def recordatorios_de(disp):
    hoy = datetime.now().date()
    out = []
    for r in db("SELECT id, nombre, categoria, monto, frecuencia, proxima FROM recordatorios WHERE dispositivo = ? "
                "ORDER BY proxima, id", (disp,)):
        dias = (datetime.strptime(r["proxima"], "%Y-%m-%d").date() - hoy).days
        out.append({**r, "dias": dias, "estado": "vencido" if dias < 0 else "pronto" if dias <= 5 else "ok"})
    return out


def avisos_pagos(pagos):
    out = []
    for p in pagos:
        if p["estado"] == "ok":
            continue
        n = p["dias"]
        cuando = (f"venció hace {-n} día{'s' if n < -1 else ''}" if n < 0 else "vence hoy" if n == 0
                  else "vence mañana" if n == 1 else f"vence en {n} días")
        out.append({"nivel": "mal" if n < 0 else "aviso", "ir": "dinero", "titulo": f"{p['nombre']}: {cuando}",
                    "texto": (f"{_usd(p['monto'])}. " if p["monto"] else "") + "Cuando lo pagues, márcalo como pagado en Dinero."})
    return out


def dinero_del_mes(d, mes):
    """Ingresos (lo que entregaron los choferes), gastos, lo que queda, y por chofer
    lo que debía entregar (cuenta pactada × jornadas trabajadas) contra lo que entregó."""
    ini, fin = _mes(mes)
    a, b = ini.strftime("%Y-%m-%d"), fin.strftime("%Y-%m-%d")
    disp, turnos = d["id"], turnos_de(d["id"])
    ajuste = ajuste_cobro(d)
    # Las jornadas de noche del último día terminan al mes siguiente: se pide un día más.
    cs = [c for c in carreras_dueno(d, ini.timestamp(), (fin + timedelta(days=1)).timestamp(), ajuste=ajuste["factor"])
          if a <= c["jornada"] < b]
    reps = db("SELECT dia, turno, monto, entregado FROM reportes WHERE dispositivo = ? AND dia >= ? AND dia < ?", (disp, a, b))
    cuentas = _cuentas(d, turnos)
    choferes = []
    for t in turnos + [{"id": 0, "nombre": "Fuera de turno" if turnos else "", "desde": None, "hasta": None}]:
        jornadas = {c["jornada"] for c in cs if c["turno"] == t["id"]} | \
                   {r["dia"] for r in reps if r["turno"] == t["id"] and r["entregado"] is not None}
        if t["id"] == 0 and turnos and not jornadas:
            continue  # "fuera de turno" sin nada: no se muestra
        entregado = round(sum(r["entregado"] or 0 for r in reps if r["turno"] == t["id"]), 2)
        cuenta_t = cuentas.get(t["id"])
        esperado = round(cuenta_t * len(jornadas), 2) if cuenta_t else None
        choferes.append({"turno": t["id"], "nombre": t["nombre"], "desde": t["desde"], "hasta": t["hasta"],
                         "cuenta": cuenta_t, "jornadas": len(jornadas), "esperado": esperado, "entregado": entregado,
                         "pendiente": round(esperado - entregado, 2) if esperado is not None else None,
                         **{k: v for k, v in _sumar([c for c in cs if c["turno"] == t["id"]]).items() if k != "pasajeros"}})
    gastos = gastos_de(disp, a, b)
    por_categoria = {}
    for g in gastos:
        por_categoria[g["categoria"]] = round(por_categoria.get(g["categoria"], 0) + g["monto"], 2)
    por_grupo = {}
    for c, m in por_categoria.items():
        grupo = GRUPO_GASTO.get(c, "Otros")
        por_grupo[grupo] = round(por_grupo.get(grupo, 0) + m, 2)
    total_gastos = round(sum(por_categoria.values()), 2)
    ingresos = round(sum(r["entregado"] or 0 for r in reps), 2)
    odo = odometro(d)
    km_con = round(sum(c["km"] for c in cs), 1)
    km_total = round(km_con * odo["factor"])
    por_dia = _por_dia(cs)
    dias = []
    for dia in sorted(set(por_dia) | {r["dia"] for r in reps}):
        ent = [r["entregado"] for r in reps if r["dia"] == dia and r["entregado"] is not None]
        dias.append({"dia": dia, **_sumar(por_dia.get(dia, [])), "entregado": round(sum(ent), 2) if ent else None})
    return {"mes": mes, "ingresos": ingresos, "gastos": total_gastos, "utilidad": round(ingresos - total_gastos, 2),
            "choferes": choferes, "lista_gastos": gastos,
            "por_categoria": sorted(({"categoria": c, "monto": m, "grupo": GRUPO_GASTO.get(c, "Otros")}
                                     for c, m in por_categoria.items()), key=lambda x: -x["monto"]),
            "por_grupo": sorted(({"grupo": g, "monto": m} for g, m in por_grupo.items()), key=lambda x: -x["monto"]),
            "carreras": _sumar(cs), "dias": dias, "km_con_pax": km_con, "km_total": km_total, "factor_km": odo["factor"],
            "costo_km": round(total_gastos / km_total, 3) if km_total else None,
            "utilidad_km": round((ingresos - total_gastos) / km_total, 3) if km_total else None,
            "categorias": CATEGORIAS_GASTO, "formas_pago": FORMAS_PAGO}


@app.get("/api/dueno/taxi/{disp}/dinero")
def dinero_dueno(disp: str, mes: str = "", cuenta=Depends(cuenta_auth)):
    d = taxi_de(cuenta, disp)
    return dinero_del_mes(d, mes or datetime.now().strftime("%Y-%m"))


@app.post("/api/dueno/taxi/{disp}/gastos")
async def guardar_gasto(disp: str, request: Request, cuenta=Depends(cuenta_auth)):
    """{"id"?: para editar, "fecha", "categoria", "monto", "descripcion"?, "km"? (odómetro),
    "pago"?, "lugar"?, "mantenimiento"?: id de un mantenimiento que este gasto deja hecho}
    o {"id", "borrar": true}."""
    d = taxi_de(cuenta, disp)
    body = await request.json()
    gid = int(body.get("id") or 0)
    if gid and not db("SELECT id FROM gastos WHERE dispositivo = ? AND id = ?", (disp, gid), one=True):
        raise HTTPException(404)
    if body.get("borrar"):
        db("DELETE FROM gastos WHERE id = ?", (gid,))
        return {"ok": True}
    categoria = str(body.get("categoria") or "")
    if categoria not in CATEGORIAS_GASTO:
        raise HTTPException(400, "Elige una categoría")
    monto = _monto(body.get("monto"), 10_000)
    if monto is None:
        raise HTTPException(400, "Escribe cuánto costó")
    pago = str(body.get("pago") or "")
    if pago and pago not in FORMAS_PAGO:
        raise HTTPException(400, "Forma de pago inválida")
    try:
        km = float(body["km"]) if body.get("km") not in (None, "") else None
    except (TypeError, ValueError):
        raise HTTPException(400, "El kilometraje va en números")
    if km is not None and not 0 <= km < 3_000_000:
        raise HTTPException(400, "Kilometraje fuera de rango")
    fila = (_fecha(body.get("fecha") or datetime.now().strftime("%Y-%m-%d")), categoria,
            str(body.get("descripcion") or "").strip()[:120], monto, km, pago, str(body.get("lugar") or "").strip()[:80])
    if gid:
        db("UPDATE gastos SET fecha = ?, categoria = ?, descripcion = ?, monto = ?, km = ?, pago = ?, lugar = ? WHERE id = ?",
           (*fila, gid))
    else:
        db("INSERT INTO gastos (dispositivo, fecha, categoria, descripcion, monto, km, pago, lugar, creado, por) "
           "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", (disp, *fila, time.time(), cuenta["usuario"]))
    # Un cambio de aceite (o lo que sea) pagado también deja hecho su mantenimiento.
    if body.get("mantenimiento"):
        m = db("SELECT id FROM mantenimiento WHERE dispositivo = ? AND id = ?", (disp, int(body["mantenimiento"])), one=True)
        hecho_km = km if km is not None else odometro(d)["estimado"]
        if m and hecho_km is not None:
            db("UPDATE mantenimiento SET ultimo_km = ? WHERE id = ?", (hecho_km, m["id"]))
    return {"ok": True}


@app.get("/api/dueno/taxi/{disp}/recordatorios")
def recordatorios_dueno(disp: str, cuenta=Depends(cuenta_auth)):
    return recordatorios_de(taxi_de(cuenta, disp)["id"])


@app.post("/api/dueno/taxi/{disp}/recordatorios")
async def guardar_recordatorio(disp: str, request: Request, cuenta=Depends(cuenta_auth)):
    """Pagos que vencen por fecha (cooperativa, seguro, matrícula, revisión…):
    {"nombre", "categoria", "monto"?, "frecuencia": mensual|anual|una_vez, "proxima": "AAAA-MM-DD"};
    {"id", "pagado": true, "monto"?}: lo anota como gasto de hoy y pasa al próximo vencimiento;
    {"id", "borrar": true}."""
    taxi_de(cuenta, disp)
    body = await request.json()
    rid = int(body.get("id") or 0)
    r = db("SELECT * FROM recordatorios WHERE dispositivo = ? AND id = ?", (disp, rid), one=True) if rid else None
    if rid and not r:
        raise HTTPException(404)
    if body.get("borrar"):
        db("DELETE FROM recordatorios WHERE id = ?", (rid,))
    elif body.get("pagado"):
        monto = _monto(body.get("monto"), 10_000)
        monto = monto if monto is not None else r["monto"]
        if monto:
            db("INSERT INTO gastos (dispositivo, fecha, categoria, descripcion, monto, creado, por) VALUES (?, ?, ?, ?, ?, ?, ?)",
               (disp, datetime.now().strftime("%Y-%m-%d"), r["categoria"], r["nombre"], monto, time.time(), cuenta["usuario"]))
        if r["frecuencia"] == "una_vez":
            db("DELETE FROM recordatorios WHERE id = ?", (rid,))
        else:
            db("UPDATE recordatorios SET proxima = ? WHERE id = ?",
               (_sumar_meses(r["proxima"], 1 if r["frecuencia"] == "mensual" else 12), rid))
    else:
        nombre = str(body.get("nombre") or "").strip()[:60]
        categoria = str(body.get("categoria") or "Otros")
        frecuencia = str(body.get("frecuencia") or "mensual")
        if not nombre:
            raise HTTPException(400, "Escribe qué hay que pagar")
        if categoria not in CATEGORIAS_GASTO or frecuencia not in FRECUENCIAS:
            raise HTTPException(400, "Categoría o frecuencia inválida")
        fila = (nombre, categoria, _monto(body.get("monto"), 10_000), frecuencia,
                _fecha(body.get("proxima") or "", futura=True))
        if rid:
            db("UPDATE recordatorios SET nombre = ?, categoria = ?, monto = ?, frecuencia = ?, proxima = ? WHERE id = ?", (*fila, rid))
        else:
            db("INSERT INTO recordatorios (dispositivo, nombre, categoria, monto, frecuencia, proxima, creado) "
               "VALUES (?, ?, ?, ?, ?, ?, ?)", (disp, *fila, time.time()))
    return recordatorios_de(disp)


@app.get("/api/dueno/taxi/{disp}/informe.docx")
def informe_dueno(disp: str, mes: str = "", cuenta=Depends(cuenta_auth)):
    """Informe del mes en Word: dinero, choferes, gastos, carreras, mantenimiento y próximos pagos."""
    import informe
    d = taxi_de(cuenta, disp)
    mes = mes or datetime.now().strftime("%Y-%m")
    odo = odometro(d)
    dueno = db("SELECT nombre, usuario FROM duenos WHERE id = ?", (d["dueno"],), one=True) if d["dueno"] else None
    datos = {"taxi": d["nombre"] or d["id"], "dueno": (dueno["nombre"] or dueno["usuario"]) if dueno else "",
             "dinero": dinero_del_mes(d, mes), "mantenimiento": mantenimientos(d, odo), "odometro": odo,
             "recordatorios": recordatorios_de(disp), "tarifa": tarifa_de(d)}
    contenido = informe.informe_docx(datos)
    nombre = f"Taxiff_{re.sub(r'[^A-Za-z0-9-]+', '_', datos['taxi'])}_{mes}.docx"
    return Response(contenido, media_type="application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                    headers={"Content-Disposition": f'attachment; filename="{nombre}"'})


@app.get("/api/dueno/taxi/{disp}/carrera/{cid}")
def carrera_dueno(disp: str, cid: int, cuenta=Depends(cuenta_auth)):
    """Una carrera con su recorrido (vacío mientras no haya GPS)."""
    d = taxi_de(cuenta, disp)
    c = db("SELECT inicio FROM carreras WHERE dispositivo = ? AND id = ? AND valida = 1", (disp, cid), one=True)
    if not c:
        raise HTTPException(404)
    return next(x for x in carreras_dueno(d, c["inicio"], c["inicio"] + 0.001, con_recorrido=True,
                                          ajuste=ajuste_cobro(d)["factor"]) if x["id"] == cid)


@app.get("/api/dueno/taxi/{disp}/carreras.csv")
def carreras_dueno_csv(disp: str, desde: str = "", hasta: str = "", cuenta=Depends(cuenta_auth)):
    d = taxi_de(cuenta, disp)
    ini, fin = _rango_fechas(desde, hasta)
    return _csv(carreras_dueno(d, ini, fin, ajuste=ajuste_cobro(d)["factor"]), f"carreras_{disp}.csv")


@app.get("/api/dueno/taxi/{disp}/odometro")
def odometro_dueno(disp: str, cuenta=Depends(cuenta_auth)):
    return odometro(taxi_de(cuenta, disp))


@app.post("/api/dueno/taxi/{disp}/odometro")
async def anotar_odometro(disp: str, request: Request, cuenta=Depends(cuenta_auth)):
    """{"km": 123456, "fecha": hora en segundos (opcional: ahora), "nota": ""}.
    El odómetro no retrocede: una lectura no puede ser menor que una anterior
    ni mayor que una posterior."""
    d = taxi_de(cuenta, disp)
    body = await request.json()
    ahora = time.time()
    try:
        km = float(body.get("km"))
        fecha = float(body.get("fecha") or ahora)
    except (TypeError, ValueError):
        raise HTTPException(400, "Escribe los km del odómetro (solo números)")
    if not 0 <= km < 3_000_000:
        raise HTTPException(400, "Kilometraje fuera de rango")
    if fecha > ahora + 300 or fecha < ahora - 5 * 365 * 86400:
        raise HTTPException(400, "La fecha no puede ser futura ni de hace más de 5 años")
    antes = db("SELECT fecha, km FROM odometro WHERE dispositivo = ? AND fecha <= ? ORDER BY fecha DESC LIMIT 1",
               (disp, fecha), one=True)
    despues = db("SELECT fecha, km FROM odometro WHERE dispositivo = ? AND fecha > ? ORDER BY fecha LIMIT 1",
                 (disp, fecha), one=True)
    if antes and km < antes["km"]:
        raise HTTPException(400, f"El odómetro no baja: el {datetime.fromtimestamp(antes['fecha']):%d/%m/%Y} "
                                 f"marcaba {antes['km']:,.0f} km".replace(",", "."))
    if despues and km > despues["km"]:
        raise HTTPException(400, f"El {datetime.fromtimestamp(despues['fecha']):%d/%m/%Y} (después) "
                                 f"marcaba {despues['km']:,.0f} km: esta lectura no puede ser mayor".replace(",", "."))
    db("INSERT INTO odometro (dispositivo, fecha, km, nota, anotado, por) VALUES (?, ?, ?, ?, ?, ?)",
       (disp, fecha, km, str(body.get("nota") or "")[:120], ahora, cuenta["usuario"]))
    evento(d["id"], f"odómetro anotado por {cuenta['usuario']}: {km:,.0f} km".replace(",", "."), nivel="info")
    return odometro(d)


@app.post("/api/dueno/taxi/{disp}/odometro/{oid}/borrar")
def borrar_odometro(disp: str, oid: int, cuenta=Depends(cuenta_auth)):
    d = taxi_de(cuenta, disp)
    if not db("SELECT id FROM odometro WHERE dispositivo = ? AND id = ?", (disp, oid), one=True):
        raise HTTPException(404)
    db("DELETE FROM odometro WHERE id = ?", (oid,))
    return odometro(d)


@app.post("/api/dueno/taxi/{disp}/tarifa")
async def guardar_tarifa(disp: str, request: Request, cuenta=Depends(cuenta_auth)):
    """Valores de la tarifa (ver TARIFA), o {"restablecer": true} para volver a la de referencia."""
    d = taxi_de(cuenta, disp)
    body = await request.json()
    propia = {} if body.get("restablecer") else json.loads(d.get("tarifa") or "{}")
    for k, (lo, hi) in LIMITES_TARIFA.items():
        if k not in body:
            continue
        try:
            v = float(body[k])
        except (TypeError, ValueError):
            raise HTTPException(400, f"Valor inválido: {k}")
        if not lo <= v <= hi:
            raise HTTPException(400, f"{k} debe estar entre {lo} y {hi}")
        propia[k] = int(v) if k in ENTEROS_TARIFA else round(v, 2)
    db("UPDATE dispositivos SET tarifa = ? WHERE id = ?", (json.dumps(propia), disp))
    evento(disp, f"tarifa {'restablecida' if body.get('restablecer') else 'cambiada'} por {cuenta['usuario']}", nivel="info")
    return tarifa_de({"tarifa": json.dumps(propia)})


@app.post("/api/v1/posiciones")
async def posiciones(request: Request, x_dispositivo: str = Header(...), authorization: str = Header(None)):
    """Hueco para el recorrido de las carreras: [[ts, lat, lon], ...] de un GPS
    (un módulo en la cámara o el celular del conductor). Hoy nadie lo envía;
    cuando llegue algo, el mapa y los km de las carreras salen de aquí."""
    dispositivo_auth(x_dispositivo, authorization)
    puntos = await request.json()
    if not isinstance(puntos, list) or len(puntos) > 5000:
        raise HTTPException(400, "Se espera una lista de [ts, lat, lon] (5000 como mucho)")
    filas = []
    for p in puntos:
        try:
            ts, lat, lon = (float(v) for v in p)
        except (TypeError, ValueError):
            raise HTTPException(400, "Cada punto es [ts, lat, lon]")
        if -90 <= lat <= 90 and -180 <= lon <= 180:
            filas.append((x_dispositivo, ts, lat, lon))
    with _db_lock:
        _db.executemany("INSERT OR IGNORE INTO posiciones (dispositivo, ts, lat, lon) VALUES (?, ?, ?, ?)", filas)
        _db.commit()
    return {"ok": True, "guardados": len(filas)}

# ---------------------------------------------------------------- cuentas de dueños (las crea el admin)

_USUARIO = re.compile(r"[a-z0-9._-]{3,32}")


def _validar_clave(clave):
    if len(clave) < 8:
        raise HTTPException(400, "La clave necesita al menos 8 caracteres")
    if clave == CLAVE_PANEL:
        raise HTTPException(400, "No uses la clave del administrador")


@app.get("/api/panel/duenos", dependencies=[Depends(panel_auth)])
def duenos():
    rows = db("SELECT id, usuario, nombre, activo, creado, entro FROM duenos ORDER BY nombre, usuario")
    for r in rows:
        r["taxis"] = [x["id"] for x in db("SELECT id FROM dispositivos WHERE dueno = ?", (r["id"],))]
    return rows


@app.post("/api/panel/duenos", dependencies=[Depends(panel_auth)])
async def crear_dueno(request: Request):
    """{"usuario", "nombre", "clave"}: cuenta nueva de dueño (después se le asignan taxis)."""
    body = await request.json()
    usuario = str(body.get("usuario", "")).strip().lower()
    if not _USUARIO.fullmatch(usuario) or usuario == "admin":
        raise HTTPException(400, "Usuario: de 3 a 32 letras minúsculas, números, punto, guion o guion bajo (no 'admin')")
    if db("SELECT id FROM duenos WHERE usuario = ?", (usuario,), one=True):
        raise HTTPException(409, "Ese usuario ya existe")
    clave = str(body.get("clave", ""))
    _validar_clave(clave)
    clave = await run_in_threadpool(hash_clave, clave)
    db("INSERT INTO duenos (usuario, nombre, clave, creado) VALUES (?, ?, ?, ?)",
       (usuario, str(body.get("nombre", "")).strip()[:60], clave, time.time()))
    log.info(f"cuenta de dueño creada: {usuario}")
    return {"ok": True, "id": db("SELECT id FROM duenos WHERE usuario = ?", (usuario,), one=True)["id"]}


@app.post("/api/panel/duenos/{uid}", dependencies=[Depends(panel_auth)])
async def editar_dueno(uid: int, request: Request):
    """{"nombre"?, "clave"?, "activo"?}. Cambiar la clave o desactivar la cuenta
    cierra sus sesiones abiertas."""
    body = await request.json()
    d = db("SELECT * FROM duenos WHERE id = ?", (uid,), one=True)
    if not d:
        raise HTTPException(404)
    if "nombre" in body:
        db("UPDATE duenos SET nombre = ? WHERE id = ?", (str(body["nombre"]).strip()[:60], uid))
    if body.get("clave"):
        _validar_clave(str(body["clave"]))
        db("UPDATE duenos SET clave = ? WHERE id = ?", (await run_in_threadpool(hash_clave, str(body["clave"])), uid))
        log.info(f"clave cambiada: dueño {d['usuario']}")
    if "activo" in body:
        db("UPDATE duenos SET activo = ? WHERE id = ?", (int(bool(body["activo"])), uid))
        log.info(f"dueño {d['usuario']} {'activado' if body['activo'] else 'desactivado'}")
    return {"ok": True}


@app.get("/dueno")
def pagina_dueno(request: Request):
    return _pagina(request, "dueno.html")


@app.get("/entrar")
def pagina_entrar(request: Request):
    cuenta = quien(request)
    if cuenta:
        return RedirectResponse("/" if cuenta["rol"] == "admin" else "/dueno", 303)
    return FileResponse(WEB / "entrar.html")

# ---------------------------------------------------------------- mantenimiento


def _renivelar_eventos():
    """Las líneas de las cámaras ya guardadas se vuelven a clasificar con las reglas
    actuales (si cambian, el panel no muestra errores que ya no lo son)."""
    cambios = [(nivel, r["id"]) for r in db("SELECT id, texto, nivel FROM eventos WHERE origen = 'cámara'")
               if (nivel := nivel_de(r["texto"])) != r["nivel"]]
    with _db_lock:
        _db.executemany("UPDATE eventos SET nivel = ? WHERE id = ?", cambios)
        _db.commit()
    if cambios:
        log.info(f"registro: {len(cambios)} líneas reclasificadas con las reglas actuales")


def _mantenimiento():
    """Cada minuto cierra carreras de cámaras calladas; cada hora borra fotos viejas
    que no son evidencia de ninguna carrera."""
    _renivelar_eventos()
    ultima_limpieza = 0
    while True:
        time.sleep(60)
        ahora = time.time()
        # Si la cámara avisó que tiene fotos guardadas sin enviar, la carrera
        # sigue abierta: esas fotos dirán cómo terminó.
        con_cola = {r["id"] for r in db("SELECT id FROM dispositivos WHERE cola > 0")}
        with _carreras_lock:
            cerradas = []
            for disp, c in _carreras.items():
                if c.estado == "EN_CARRERA" and ahora - c.recibida > SIN_FOTOS_S and disp not in con_cola:
                    cerradas.append((disp, c.cerrar(c.ultima_con_gente or c.ultima_ts)))
                    guardar_estado(disp, c)
        for disp, c in cerradas:
            evento(disp, f"la cámara dejó de enviar {SIN_FOTOS_S // 60} min en plena carrera: se cerró sola", nivel="aviso")
            guardar_carrera(disp, c)
        if ahora - ultima_limpieza > 3600:
            ultima_limpieza = ahora
            evidencia = set()
            for r in db("SELECT fotos FROM carreras"):
                evidencia.update(json.loads(r["fotos"] or "[]"))
            limite = ahora - GUARDAR_FOTOS_H * 3600
            borradas = 0
            for f in FOTOS.rglob("*.jpg"):
                rel = f.relative_to(FOTOS).as_posix()
                if rel not in evidencia and f.stat().st_mtime < limite:
                    f.unlink(missing_ok=True)
                    f.with_suffix(".json").unlink(missing_ok=True)
                    borradas += 1
            if borradas:
                log.info(f"limpieza: {borradas} fotos de más de {GUARDAR_FOTOS_H} h que no eran evidencia")
            # Los eventos en la base se guardan 90 días (los archivos .log quedan completos).
            db("DELETE FROM eventos WHERE recibido < ?", (ahora - 90 * 86400,))


threading.Thread(target=_mantenimiento, daemon=True).start()
