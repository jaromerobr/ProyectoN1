"""Servidor Taxiff.

Recibe las fotos que envían las cámaras ESP32 de los taxis, cuenta pasajeros
con el modelo YOLO (modelos/best.pt), aplica la jaula de cada taxi, arma las
carreras y sirve el panel web.

Cada cámara se identifica por su ID de fábrica (TX-XXXXXX, sale de la MAC del
chip) y un token que recibe la primera vez que se registra.

Arranque:  .venv\\Scripts\\python -m uvicorn app:app --host 0.0.0.0 --port 8000
"""

import hashlib
import json
import logging
import logging.handlers
import os
import secrets
import sqlite3
import statistics
import struct
import threading
import time
from collections import deque
from datetime import datetime
from pathlib import Path

from fastapi import Depends, FastAPI, Header, HTTPException, Request
from fastapi.responses import FileResponse, JSONResponse, Response
from fastapi.security import HTTPBasic, HTTPBasicCredentials
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
    """)
    # Columnas agregadas después (bases de datos ya creadas).
    for tabla, col in (("dispositivos", "cola INTEGER DEFAULT 0"),
                       ("dispositivos", "ajustes TEXT DEFAULT '{}'"), ("dispositivos", "ajustes_ver INTEGER DEFAULT 0"),
                       ("dispositivos", "cfg_camara TEXT"), ("dispositivos", "ajustes_aplicados INTEGER DEFAULT 0"),
                       ("dispositivos", "ip_local TEXT"), ("dispositivos", "contacto REAL"),
                       ("dispositivos", "cola_max INTEGER DEFAULT 0"),
                       ("carreras", "pasajeros INTEGER"), ("carreras", "eventos TEXT")):
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
        self.recibida = time.time()  # hora real (no la de la foto) en que llegó la última

    def actualizar(self, ts, n, foto):
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
        if self.estado == "LIBRE":
            if c >= 1:
                self.estado, self.desde = "CONFIRMANDO", ts
        elif self.estado == "CONFIRMANDO":
            if c == 0:
                self.estado = "LIBRE"
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
             "valida": int(dur >= MINIMO_S), "fotos": [p for _, p in self.fotos[:30]]}
        self.__init__()
        return r

    # El estado se guarda en la base después de cada foto: si el servidor se
    # reinicia, la carrera en curso sigue donde iba.
    _CAMPOS = ("estado", "desde", "inicio", "cero_desde", "max", "nivel", "cand", "cand_desde",
               "distintos", "eventos", "fotos", "ultima_ts", "ultima_con_gente")

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


def guardar_carrera(disp, c, anotar=True):
    if anotar:
        evento(disp, f"carrera {'válida' if c['valida'] else 'descartada'}: "
                     f"{datetime.fromtimestamp(c['inicio']):%d/%m %H:%M:%S} → {datetime.fromtimestamp(c['fin']):%H:%M:%S}, "
                     f"{int(c['duracion'])} s, {c.get('pasajeros', c['max_pax'])} pasajero(s)", nivel="info")
    _guardar_carrera(disp, c)


def _guardar_carrera(disp, c):
    db("INSERT INTO carreras (dispositivo, inicio, fin, duracion, max_pax, pasajeros, eventos, valida, fotos) "
       "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
       (disp, c["inicio"], c["fin"], c["duracion"], c["max_pax"], c.get("pasajeros", c["max_pax"]),
        json.dumps(c.get("eventos", [])), c["valida"], json.dumps(c["fotos"])))

# ---------------------------------------------------------------- app

app = FastAPI(title="Taxiff")
app.mount("/web", StaticFiles(directory=WEB), name="web")  # estilos y scripts del panel (sin datos)


@app.exception_handler(Exception)
async def error_inesperado(request: Request, exc: Exception):
    """Cualquier error no previsto queda en servidor.log con todo el detalle."""
    log.exception(f"error en {request.method} {request.url.path}")
    return JSONResponse({"detail": "Error interno del servidor (ver datos/logs/servidor.log)"}, 500)


log.info(f"servidor iniciado · datos en {DATOS} · modelo {MODELO.name}")
_basic = HTTPBasic()


def panel_auth(cred: HTTPBasicCredentials = Depends(_basic)):
    if not secrets.compare_digest(cred.password.encode(), CLAVE_PANEL.encode()):
        raise HTTPException(401, "Clave incorrecta", headers={"WWW-Authenticate": "Basic"})


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


def procesar_foto(d, datos, ts_camara, conteo, estimada=False):
    """Guarda una foto, cuenta pasajeros con YOLO y avanza la carrera del taxi.
    Devuelve (ruta relativa, pasajeros, estado de la carrera)."""
    ahora = time.time()
    # Las fotos guardadas sin internet llegan con la hora en que se tomaron.
    # Si la cámara arrancó sin internet la estima a partir de sus arranques
    # (`estimada`): se respeta, para que queden en orden, pero se marca como
    # "hora aproximada". Sin ninguna hora se usa la de llegada.
    valida = bool(ts_camara) and abs(ahora - ts_camara) <= MAX_ATRASO_S
    aprox = estimada or not valida
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
    ruta.with_suffix(".json").write_text(json.dumps(
        {"ts": ts, "dets": dets, "n": n, "n_esp": conteo, "aprox": aprox}))

    with _carreras_lock:
        car = carrera_de(d["id"])
        cerrada = car.actualizar(ts, n, (ts, rel))
        estado = car.estado
        guardar_estado(d["id"], car)
    if cerrada:
        guardar_carrera(d["id"], cerrada)
    return rel, n, estado


def _actualizar_dispositivo(d, rel, n, conteo, estado, recibidas, cola, fw, rssi, temp,
                            cfg=None, ajustes_ver=None, ip=None):
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


@app.post("/api/v1/foto")
async def foto(request: Request,
               x_dispositivo: str = Header(...), authorization: str = Header(None),
               x_ts: float = Header(0), x_conteo: int = Header(0), x_cola: int = Header(0),
               x_temp: float = Header(None), x_rssi: int = Header(None), x_fw: str = Header(None),
               x_cfg: str = Header(None), x_ajustes_ver: int = Header(-1), x_ip: str = Header(None)):
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
    return _respuesta(d, estado, n, x_conteo, x_ajustes_ver)


@app.post("/api/v1/lote")
async def lote(request: Request,
               x_dispositivo: str = Header(...), authorization: str = Header(None),
               x_cola: int = Header(0), x_temp: float = Header(None), x_rssi: int = Header(None),
               x_fw: str = Header(None), x_cfg: str = Header(None), x_ajustes_ver: int = Header(-1),
               x_ip: str = Header(None)):
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
    return _respuesta(d, estado, n, conteo, x_ajustes_ver, recibidas=len(fotos))

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
    if foto is not None and foto < 45:
        if cola > 0:
            return {**base, "estado": "subiendo", "titulo": f"Subiendo fotos guardadas · quedan {cola}",
                    "detalle": f"Llegaron {por_min} en el último minuto. Son las que tomó sin internet."}
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
    try:
        d["cfg_camara"] = json.loads(d.get("cfg_camara") or "{}")
    except ValueError:
        d["cfg_camara"] = {}
    # ¿La cámara ya aplicó los últimos ajustes elegidos en el panel?
    d["ajustes_pendientes"] = bool(d["ajustes"]) and (d.get("ajustes_aplicados") or 0) != (d.get("ajustes_ver") or 0)
    d["carreras_hoy"] = db("SELECT COUNT(*) AS n FROM carreras WHERE dispositivo = ? AND inicio >= ? AND valida = 1",
                           (d["id"], hoy), one=True)["n"]
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
      el número de pasajeros (subió o bajó alguien), más la primera y la última.
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
        f = {"foto": f"{disp}/{dia}/{j.stem}.jpg", "ts": info["ts"], "n": info.get("n", 0),
             "n_esp": info.get("n_esp", 0), "aprox": info.get("aprox", False)}
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
    return {"carreras": rows, "resumen": {
        "carreras": len(validas),
        "descartadas": len(rows) - len(validas),
        "tiempo_s": sum(c["duracion"] for c in validas),
        "pasajeros": sum(c["pasajeros"] for c in validas),
        "mas_larga_s": max((c["duracion"] for c in validas), default=0)}}


def _resumen_carreras(carreras):
    validas = [c for c in carreras if c["valida"]]
    return {"carreras": len(validas), "descartadas": len(carreras) - len(validas),
            "tiempo_s": sum(c["duracion"] for c in validas),
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
        cerrada = car.actualizar(info["ts"], n, (info["ts"], rel))
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
            "carreras": [{k: c[k] for k in ("inicio", "fin", "duracion", "max_pax", "pasajeros", "valida")}
                         for c in carreras]}


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
    import csv
    import io
    ini = datetime.fromisoformat(desde).timestamp() if desde else 0
    fin = datetime.fromisoformat(hasta).timestamp() + 86400 if hasta else 1e12
    rows = db("SELECT c.*, d.nombre FROM carreras c LEFT JOIN dispositivos d ON d.id = c.dispositivo "
              "WHERE c.inicio >= ? AND c.inicio < ? ORDER BY c.inicio", (ini, fin))
    out = io.StringIO()
    w = csv.writer(out, delimiter=";")
    w.writerow(["camara", "taxi", "inicio", "fin", "duracion_min", "pasajeros_distintos", "pasajeros_max_a_la_vez", "valida"])
    for c in rows:
        w.writerow([c["dispositivo"], c["nombre"] or "",
                    datetime.fromtimestamp(c["inicio"]).strftime("%Y-%m-%d %H:%M:%S"),
                    datetime.fromtimestamp(c["fin"]).strftime("%Y-%m-%d %H:%M:%S"),
                    f"{c['duracion'] / 60:.1f}".replace(".", ","), c["pasajeros"] or c["max_pax"], c["max_pax"],
                    "si" if c["valida"] else "no"])
    # BOM para que Excel abra bien las tildes.
    return Response("﻿" + out.getvalue(), media_type="text/csv; charset=utf-8",
                    headers={"Content-Disposition": "attachment; filename=carreras.csv"})


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


@app.get("/", dependencies=[Depends(panel_auth)])
def inicio():
    return FileResponse(WEB / "index.html")


@app.get("/taxi/{disp}", dependencies=[Depends(panel_auth)])
def pagina_taxi(disp: str):
    return FileResponse(WEB / "taxi.html")

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
