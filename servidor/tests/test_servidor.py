"""Pruebas del servidor Taxiff sin cámara ni modelo: el detector se reemplaza
por uno falso que devuelve las personas que cada prueba indica.

Correr:  .venv\\Scripts\\python -m pytest -q
"""

import base64
import importlib
import os
import sys
import tempfile
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

JPEG = b"\xff\xd8\xff\xe0" + b"0" * 2000  # basta con que empiece como JPEG
PANEL = {"Authorization": "Basic " + base64.b64encode(b"admin:clave-prueba").decode()}


@pytest.fixture()
def srv(monkeypatch):
    """App nueva con datos en una carpeta temporal y detector falso."""
    tmp = tempfile.mkdtemp()
    monkeypatch.setenv("TAXIFF_DATOS", tmp)
    monkeypatch.setenv("TAXIFF_CLAVE_PANEL", "clave-prueba")
    monkeypatch.setenv("TAXIFF_AUTO_APROBAR", "1")
    import app as modulo
    modulo = importlib.reload(modulo)
    personas = []  # lo que "ve" el detector en la próxima foto
    monkeypatch.setattr(modulo, "detectar", lambda ruta: [list(p) for p in personas])
    from fastapi.testclient import TestClient
    return modulo, TestClient(modulo.app), personas


def registrar(cliente, id="TX-000001"):
    r = cliente.post("/api/v1/registro", json={"id": id, "fw": "1.0"})
    assert r.status_code == 200
    return r.json()["token"]


def enviar(cliente, token, ts, id="TX-000001", conteo=0):
    h = {"X-Dispositivo": id, "Authorization": f"Bearer {token}", "X-Ts": str(ts), "X-Conteo": str(conteo)}
    return cliente.post("/api/v1/foto", content=JPEG, headers=h)


PERSONA = [0.4, 0.3, 0.6, 0.7, 0.9]  # caja centrada en (0.5, 0.5)


# ------------------------------------------------------------------ jaula

def test_jaula_vacia_cuenta_todo(srv):
    m, _, _ = srv
    assert m.dentro_de_jaula(0.9, 0.9, [])


def test_jaula_poligono(srv):
    m, _, _ = srv
    jaula = [[0.2, 0.2], [0.8, 0.2], [0.8, 0.8], [0.2, 0.8]]
    assert m.dentro_de_jaula(0.5, 0.5, jaula)
    assert not m.dentro_de_jaula(0.95, 0.5, jaula)


# ------------------------------------------------------------------ carreras

def test_carrera_completa_y_valida(srv):
    m, _, _ = srv
    c = m.Carrera()
    t, cerradas = 1000, []
    for i in range(5):
        cerradas.append(c.actualizar(t + i, 0, (t + i, "f")))
    for i in range(5, 65):
        cerradas.append(c.actualizar(t + i, 1, (t + i, "f")))
    assert c.estado == "EN_CARRERA"
    for i in range(65, 80):
        cerradas.append(c.actualizar(t + i, 0, (t + i, "f")))
    hechas = [x for x in cerradas if x]
    assert len(hechas) == 1 and hechas[0]["valida"] == 1 and hechas[0]["max_pax"] == 1
    assert 55 <= hechas[0]["duracion"] <= 62
    assert c.estado == "LIBRE"


def test_carrera_corta_se_descarta(srv):
    m, _, _ = srv
    c = m.Carrera()
    cerradas = [c.actualizar(i, 1, (i, "f")) for i in range(15)]
    cerradas += [c.actualizar(i, 0, (i, "f")) for i in range(15, 30)]
    hechas = [x for x in cerradas if x]
    assert len(hechas) == 1 and hechas[0]["valida"] == 0


def test_un_falso_positivo_suelto_no_abre_carrera(srv):
    m, _, _ = srv
    c = m.Carrera()
    for i, n in enumerate([0, 0, 1, 0, 0, 0, 0]):
        c.actualizar(i, n, (i, "f"))
    assert c.estado == "LIBRE"


def test_bajada_breve_no_corta_la_carrera(srv):
    m, _, _ = srv
    c = m.Carrera()
    for i in range(20):
        c.actualizar(i, 2, (i, "f"))
    for i in range(20, 25):  # 5 s sin ver a nadie (menos que la gracia)
        assert c.actualizar(i, 0, (i, "f")) is None
    c.actualizar(25, 2, (25, "f"))
    assert c.estado == "EN_CARRERA" and c.max == 2


def test_pasajeros_distintos_y_linea_de_tiempo(srv):
    """Suben 2, baja 1, sube otro: fueron 3 pasajeros distintos (máx. 2 a la vez)."""
    m, _, _ = srv
    c = m.Carrera()
    t, conteos = 0, [2] * 60 + [1] * 60 + [2] * 60 + [0] * 15
    cerradas = []
    for n in conteos:
        cerradas.append(c.actualizar(t, n, (t, "f")))
        t += 1
    hecha = [x for x in cerradas if x][0]
    assert hecha["pasajeros"] == 3 and hecha["max_pax"] == 2
    assert [e[1] for e in hecha["eventos"]] == ["sube", "baja", "sube", "baja"]
    assert hecha["eventos"][-1][2] == 2  # al final bajan los 2 que quedaban


def test_un_cuadro_raro_no_cuenta_como_subida(srv):
    m, _, _ = srv
    c = m.Carrera()
    conteos = [1] * 30 + [2, 1, 1] + [1] * 30 + [0] * 15  # un falso positivo de 1 foto
    cerradas = [c.actualizar(i, n, (i, "f")) for i, n in enumerate(conteos)]
    assert [x for x in cerradas if x][0]["pasajeros"] == 1


def test_foto_vieja_fuera_de_orden_no_cambia_la_carrera(srv):
    m, _, _ = srv
    c = m.Carrera()
    for i in range(100, 120):
        c.actualizar(i, 1, (i, "f"))
    assert c.estado == "EN_CARRERA"
    assert c.actualizar(50, 0, (50, "f")) is None  # foto de antes
    assert c.estado == "EN_CARRERA" and c.ultima_ts == 119


def test_hueco_largo_cierra_donde_se_vio_gente(srv):
    m, _, _ = srv
    c = m.Carrera()
    for i in range(0, 120):
        c.actualizar(i, 1, (i, "f"))
    # la cámara se apagó 2 horas con el pasajero: no se estira la carrera
    cerrada = c.actualizar(119 + 7200, 1, (119 + 7200, "f"))
    assert cerrada and cerrada["fin"] == 119 and cerrada["valida"] == 1
    assert c.estado == "CONFIRMANDO"  # y la foto nueva empieza otra posible carrera


# ------------------------------------------------------------------ API cámara

def test_registro_unico(srv):
    _, cli, _ = srv
    registrar(cli)
    assert cli.post("/api/v1/registro", json={"id": "TX-000001"}).status_code == 409
    assert cli.post("/api/v1/registro", json={"id": "malo"}).status_code == 400


def test_foto_requiere_token(srv):
    _, cli, _ = srv
    registrar(cli)
    assert enviar(cli, "token-falso", 0).status_code == 401


def test_foto_no_jpeg(srv):
    _, cli, _ = srv
    tok = registrar(cli)
    h = {"X-Dispositivo": "TX-000001", "Authorization": f"Bearer {tok}"}
    assert cli.post("/api/v1/foto", content=b"hola", headers=h).status_code == 400


def test_flujo_carrera_por_api(srv):
    _, cli, personas = srv
    tok = registrar(cli)
    t0 = __import__("time").time() - 100
    r = enviar(cli, tok, t0)
    assert r.json()["modo"] == "lento"
    personas.append(PERSONA)
    for i in range(1, 50):
        r = enviar(cli, tok, t0 + i)
    assert r.json()["estado"] == "EN_CARRERA" and r.json()["modo"] == "rapido"
    personas.clear()
    for i in range(50, 65):
        r = enviar(cli, tok, t0 + i)
    assert r.json()["estado"] == "LIBRE"
    carreras = cli.get("/api/panel/carreras", headers=PANEL).json()
    assert len(carreras) == 1 and carreras[0]["valida"] == 1 and carreras[0]["fotos"]


def test_jaula_filtra_personas_de_afuera(srv):
    _, cli, personas = srv
    tok = registrar(cli)
    cli.post("/api/panel/taxi/TX-000001", headers=PANEL,
             json={"jaula": [[0, 0], [0.3, 0], [0.3, 1], [0, 1]]})  # solo el tercio izquierdo
    personas.append(PERSONA)  # está en el centro: fuera de la jaula
    r = enviar(cli, tok, __import__("time").time())
    assert r.json()["pasajeros"] == 0


def test_camara_pendiente_si_no_se_aprueba(srv, monkeypatch):
    m, cli, _ = srv
    monkeypatch.setattr(m, "AUTO_APROBAR", False)
    tok = registrar(cli, "TX-000002")
    assert enviar(cli, tok, 0, id="TX-000002").status_code == 403
    cli.post("/api/panel/taxi/TX-000002", headers=PANEL, json={"aprobado": True})
    assert enviar(cli, tok, 0, id="TX-000002").status_code == 200


def test_reiniciar_token_permite_registrarse_otra_vez(srv):
    _, cli, _ = srv
    registrar(cli)
    cli.post("/api/panel/taxi/TX-000001", headers=PANEL, json={"reiniciar_token": True})
    registrar(cli)


def lote_bytes(fotos):
    import struct
    return b"".join(struct.pack("<QiI", int(ts * 1000), n, len(JPEG)) + JPEG for ts, n in fotos)


def test_lote_de_una_semana_sin_internet(srv):
    """Fotos guardadas hace días llegan juntas y la carrera queda con su hora real."""
    _, cli, personas = srv
    tok = registrar(cli)
    h = {"X-Dispositivo": "TX-000001", "Authorization": f"Bearer {tok}", "X-Cola": "0"}
    hace_5_dias = __import__("time").time() - 5 * 86400
    personas.append(PERSONA)
    r = cli.post("/api/v1/lote", headers=h, content=lote_bytes([(hace_5_dias + i, 1) for i in range(60)]))
    assert r.status_code == 200 and r.json()["recibidas"] == 60
    personas.clear()
    cli.post("/api/v1/lote", headers=h, content=lote_bytes([(hace_5_dias + i, 0) for i in range(60, 80)]))
    carreras = cli.get("/api/panel/carreras", headers=PANEL).json()
    assert len(carreras) == 1
    assert abs(carreras[0]["inicio"] - hace_5_dias) < 2 and 55 <= carreras[0]["duracion"] <= 62
    dia = __import__("datetime").datetime.fromtimestamp(hace_5_dias).strftime("%Y-%m-%d")
    assert dia in cli.get("/api/panel/taxi/TX-000001/dias", headers=PANEL).json()
    fotos = cli.get(f"/api/panel/taxi/TX-000001/fotos?dia={dia}&solo_pasajeros=true", headers=PANEL).json()
    assert len(fotos) == 60 and not fotos[0]["aprox"]


def test_carreras_del_dia_y_fotos_de_una_carrera(srv):
    _, cli, personas = srv
    tok = registrar(cli)
    h = {"X-Dispositivo": "TX-000001", "Authorization": f"Bearer {tok}"}
    t0 = __import__("time").time() - 3600
    personas.append(PERSONA)
    cli.post("/api/v1/lote", headers=h, content=lote_bytes([(t0 + i, 1) for i in range(90)]))
    personas.clear()
    cli.post("/api/v1/lote", headers=h, content=lote_bytes([(t0 + i, 0) for i in range(90, 110)]))
    dia = __import__("datetime").datetime.fromtimestamp(t0).strftime("%Y-%m-%d")
    r = cli.get(f"/api/panel/taxi/TX-000001/carreras?dia={dia}", headers=PANEL).json()
    assert r["resumen"]["carreras"] == 1 and r["resumen"]["pasajeros"] == 1
    c = r["carreras"][0]
    fotos = cli.get(f"/api/panel/taxi/TX-000001/fotos?dia={dia}&desde={c['inicio']}&hasta={c['fin']}",
                    headers=PANEL).json()
    assert 85 <= len(fotos) <= 92 and all(c["inicio"] <= f["ts"] <= c["fin"] + 0.01 for f in fotos)


def test_lote_danado_se_rechaza(srv):
    _, cli, _ = srv
    tok = registrar(cli)
    h = {"X-Dispositivo": "TX-000001", "Authorization": f"Bearer {tok}"}
    assert cli.post("/api/v1/lote", headers=h, content=lote_bytes([(1, 0)])[:-5]).status_code == 400


def test_foto_sin_hora_queda_aproximada(srv):
    _, cli, _ = srv
    tok = registrar(cli)
    enviar(cli, tok, 0)
    dia = __import__("datetime").datetime.now().strftime("%Y-%m-%d")
    fotos = cli.get(f"/api/panel/taxi/TX-000001/fotos?dia={dia}", headers=PANEL).json()
    assert fotos and fotos[0]["aprox"]


# ------------------------------------------------------------------ panel

def test_panel_pide_clave(srv):
    _, cli, _ = srv
    assert cli.get("/api/panel/taxis").status_code == 401
    assert cli.get("/api/panel/taxis", headers=PANEL).status_code == 200


def test_csv_de_carreras(srv):
    _, cli, _ = srv
    r = cli.get("/api/panel/carreras.csv", headers=PANEL)
    assert r.status_code == 200 and "pasajeros_max" in r.text


def test_fotos_no_permite_salir_de_la_carpeta(srv):
    _, cli, _ = srv
    assert cli.get("/fotos/../../app.py", headers=PANEL).status_code == 404


# ------------------------------------------------------------------ firmware

def test_firmware_nuevo(srv):
    m, cli, _ = srv
    tok = registrar(cli)
    bin_ = b"\xe9" + b"\x00" * 200_000
    assert cli.post("/api/panel/firmware?version=1.10", headers=PANEL, content=bin_).status_code == 200
    r = cli.get(f"/api/v1/firmware?id=TX-000001&token={tok}&actual=1.9").json()
    assert r["actualizar"] and r["version"] == "1.10"  # 1.10 es más nuevo que 1.9
    assert not cli.get(f"/api/v1/firmware?id=TX-000001&token={tok}&actual=1.10").json()["actualizar"]
    d = cli.get(r["url"])
    assert d.status_code == 200 and d.content == bin_
    assert enviar(cli, tok, 0).json()["firmware"] == "1.10"


def test_firmware_rechaza_archivos_raros(srv):
    _, cli, _ = srv
    assert cli.post("/api/panel/firmware?version=1.2", headers=PANEL, content=b"x" * 200_000).status_code == 400
    assert cli.post("/api/panel/firmware?version=../a", headers=PANEL, content=b"\xe9" * 200_000).status_code == 400
