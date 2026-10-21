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
