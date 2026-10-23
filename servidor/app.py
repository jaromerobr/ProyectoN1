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
GRACIA_S = 10        # sin pasajeros este tiempo => termina
MINIMO_S = 30        # carreras más cortas se guardan como descartadas
CAMBIO_S = 3         # un cambio en el conteo dura esto => alguien subió o bajó
HUECO_S = 10 * 60    # sin fotos este tiempo DENTRO de una carrera (cámara apagada) => se cierra
SIN_FOTOS_S = 15 * 60  # cámara callada (y sin fotos pendientes) en carrera => se cierra
MAX_ATRASO_S = 30 * 86400  # fotos guardadas sin internet hasta 30 días se aceptan con su hora
GUARDAR_FOTOS_H = int(os.environ.get("TAXIFF_GUARDAR_FOTOS_H", "72"))  # las que no son evidencia

FOTOS.mkdir(parents=True, exist_ok=True)
FIRMWARE.mkdir(parents=True, exist_ok=True)

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
    """)
    # Columnas agregadas después (bases de datos ya creadas).
    for tabla, col in (("dispositivos", "cola INTEGER DEFAULT 0"),
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


_carreras = {}
_carreras_lock = threading.Lock()


def guardar_carrera(disp, c):
    db("INSERT INTO carreras (dispositivo, inicio, fin, duracion, max_pax, pasajeros, eventos, valida, fotos) "
       "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
       (disp, c["inicio"], c["fin"], c["duracion"], c["max_pax"], c.get("pasajeros", c["max_pax"]),
        json.dumps(c.get("eventos", [])), c["valida"], json.dumps(c["fotos"])))

# ---------------------------------------------------------------- app

app = FastAPI(title="Taxiff")
app.mount("/web", StaticFiles(directory=WEB), name="web")  # estilos y scripts del panel (sin datos)
_basic = HTTPBasic()


def panel_auth(cred: HTTPBasicCredentials = Depends(_basic)):
    if not secrets.compare_digest(cred.password.encode(), CLAVE_PANEL.encode()):
        raise HTTPException(401, "Clave incorrecta", headers={"WWW-Authenticate": "Basic"})


def dispositivo_auth(id, authorization):
    d = db("SELECT * FROM dispositivos WHERE id = ?", (id,), one=True)
    tok = (authorization or "").removeprefix("Bearer ").strip()
    if not d or not d["token_hash"] or not secrets.compare_digest(d["token_hash"], hash_token(tok)):
        raise HTTPException(401, "Dispositivo o token inválido")
    return d


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
    return {"token": token, "aprobado": bool(d["aprobado"]) if d else AUTO_APROBAR}


def procesar_foto(d, datos, ts_camara, conteo):
    """Guarda una foto, cuenta pasajeros con YOLO y avanza la carrera del taxi.
    Devuelve (ruta relativa, pasajeros, estado de la carrera)."""
    ahora = time.time()
    # Las fotos guardadas sin internet llegan con la hora en que se tomaron.
    # Si la cámara no sabía la hora (arrancó sin internet), se usa la de llegada
    # y la foto queda marcada como "hora aproximada".
    aprox = not ts_camara or abs(ahora - ts_camara) > MAX_ATRASO_S
    ts = ahora if aprox else ts_camara
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
        car = _carreras.setdefault(d["id"], Carrera())
        cerrada = car.actualizar(ts, n, (ts, rel))
        estado = car.estado
    if cerrada:
        guardar_carrera(d["id"], cerrada)
    return rel, n, estado


def _actualizar_dispositivo(d, rel, n, conteo, estado, recibidas, cola, fw, rssi, temp):
    db("UPDATE dispositivos SET visto = ?, fw = COALESCE(?, fw), rssi = COALESCE(?, rssi), "
       "temp = COALESCE(?, temp), ultima_foto = ?, pax = ?, pax_esp = ?, estado = ?, cola = ?, "
       "fotos_recibidas = fotos_recibidas + ? WHERE id = ?",
       (time.time(), fw, rssi, temp, rel, n, conteo, estado, cola, recibidas, d["id"]))


def _respuesta(estado, n, conteo, **extra):
    # Ritmo de envío: rápido mientras haya (o pueda haber) pasajeros.
    rapido = estado != "LIBRE" or n > 0 or conteo > 0
    return {"modo": "rapido" if rapido else "lento", "intervalo_ms": 1000 if rapido else 5000,
            "pasajeros": n, "estado": estado,
            "firmware": firmware_mas_nuevo()[0] or "", **extra}  # la cámara se actualiza si no es la suya


@app.post("/api/v1/foto")
async def foto(request: Request,
               x_dispositivo: str = Header(...), authorization: str = Header(None),
               x_ts: float = Header(0), x_conteo: int = Header(0), x_cola: int = Header(0),
               x_temp: float = Header(None), x_rssi: int = Header(None), x_fw: str = Header(None)):
    d = dispositivo_auth(x_dispositivo, authorization)
    if not d["aprobado"]:
        return JSONResponse({"error": "pendiente de aprobación", "intervalo_ms": 30000}, 403)
    datos = await request.body()
    if not datos or len(datos) > 400_000 or datos[:2] != b"\xff\xd8":
        raise HTTPException(400, "Se espera una foto JPEG")
    # YOLO tarda ~0,1–0,3 s: en otro hilo, para no frenar al resto de cámaras.
    rel, n, estado = await run_in_threadpool(procesar_foto, d, datos, x_ts, x_conteo)
    _actualizar_dispositivo(d, rel, n, x_conteo, estado, 1, x_cola, x_fw, x_rssi, x_temp)
    return _respuesta(estado, n, x_conteo)


@app.post("/api/v1/lote")
async def lote(request: Request,
               x_dispositivo: str = Header(...), authorization: str = Header(None),
               x_cola: int = Header(0), x_temp: float = Header(None), x_rssi: int = Header(None),
               x_fw: str = Header(None)):
    """Varias fotos guardadas sin internet en un solo envío, de la más vieja a la
    más nueva. Cada una: hora en ms (uint64), conteo de la cámara (int32), largo
    (uint32), todo little-endian, y luego el JPEG."""
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
        fotos.append((ts_ms / 1000, conteo, jpg))
    if not fotos or i != len(datos):
        raise HTTPException(400, "Lote vacío o dañado")
    for ts, conteo, jpg in fotos:
        rel, n, estado = await run_in_threadpool(procesar_foto, d, jpg, ts, conteo)
    _actualizar_dispositivo(d, rel, n, conteo, estado, len(fotos), x_cola, x_fw, x_rssi, x_temp)
    return _respuesta(estado, n, conteo, recibidas=len(fotos))

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


def _info_taxi(d):
    ahora = time.time()
    hoy = datetime.now().replace(hour=0, minute=0, second=0, microsecond=0).timestamp()
    d = dict(d)
    d.pop("token_hash", None)
    d["en_linea"] = bool(d["visto"] and ahora - d["visto"] < 30)
    d["jaula"] = json.loads(d["jaula"] or "[]")
    d["carreras_hoy"] = db("SELECT COUNT(*) AS n FROM carreras WHERE dispositivo = ? AND inicio >= ? AND valida = 1",
                           (d["id"], hoy), one=True)["n"]
    with _carreras_lock:
        c = _carreras.get(d["id"])
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
def fotos_del_dia(disp: str, dia: str, solo_pasajeros: bool = False, limite: int = 400, desde: float = 0):
    """Fotos de un día en orden de hora, con lo que contó el servidor y la cámara."""
    try:
        datetime.strptime(dia, "%Y-%m-%d")
    except ValueError:
        raise HTTPException(400, "Día inválido (AAAA-MM-DD)")
    carpeta = _carpeta_taxi(disp) / dia
    if not carpeta.exists():
        return []
    out = []
    for j in sorted(carpeta.glob("*.json"), key=lambda f: float(f.stem)):
        if float(j.stem) < desde:
            continue
        try:
            info = json.loads(j.read_text())
        except (OSError, ValueError):
            continue
        if solo_pasajeros and not info.get("n"):
            continue
        if not j.with_suffix(".jpg").exists():
            continue
        out.append({"foto": f"{disp}/{dia}/{j.stem}.jpg", "ts": info["ts"],
                    "n": info.get("n", 0), "n_esp": info.get("n_esp", 0), "aprox": info.get("aprox", False)})
        if len(out) >= min(limite, 2000):
            break
    return out


@app.post("/api/panel/taxi/{disp}", dependencies=[Depends(panel_auth)])
async def editar_taxi(disp: str, request: Request):
    body = await request.json()
    if not db("SELECT id FROM dispositivos WHERE id = ?", (disp,), one=True):
        raise HTTPException(404)
    if "nombre" in body:
        db("UPDATE dispositivos SET nombre = ? WHERE id = ?", (str(body["nombre"])[:60], disp))
    if "aprobado" in body:
        db("UPDATE dispositivos SET aprobado = ? WHERE id = ?", (int(bool(body["aprobado"])), disp))
    if "jaula" in body:
        jaula = [[min(1, max(0, float(x))), min(1, max(0, float(y)))] for x, y in body["jaula"]][:20]
        db("UPDATE dispositivos SET jaula = ? WHERE id = ?", (json.dumps(jaula), disp))
    if body.get("reiniciar_token"):
        # La cámara podrá registrarse de nuevo (p. ej. si se borró su memoria).
        db("UPDATE dispositivos SET token_hash = NULL WHERE id = ?", (disp,))
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


def _mantenimiento():
    """Cada minuto cierra carreras de cámaras calladas; cada hora borra fotos viejas
    que no son evidencia de ninguna carrera."""
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
        for disp, c in cerradas:
            guardar_carrera(disp, c)
        if ahora - ultima_limpieza > 3600:
            ultima_limpieza = ahora
            evidencia = set()
            for r in db("SELECT fotos FROM carreras"):
                evidencia.update(json.loads(r["fotos"] or "[]"))
            limite = ahora - GUARDAR_FOTOS_H * 3600
            for f in FOTOS.rglob("*.jpg"):
                rel = f.relative_to(FOTOS).as_posix()
                if rel not in evidencia and f.stat().st_mtime < limite:
                    f.unlink(missing_ok=True)
                    f.with_suffix(".json").unlink(missing_ok=True)


threading.Thread(target=_mantenimiento, daemon=True).start()
