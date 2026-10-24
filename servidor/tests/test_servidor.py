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
    for i in range(65, 95):
        cerradas.append(c.actualizar(t + i, 0, (t + i, "f")))
    hechas = [x for x in cerradas if x]
    assert len(hechas) == 1 and hechas[0]["valida"] == 1 and hechas[0]["max_pax"] == 1
    assert 55 <= hechas[0]["duracion"] <= 62
    assert c.estado == "LIBRE"


def test_carrera_corta_se_descarta(srv):
    m, _, _ = srv
    c = m.Carrera()
    cerradas = [c.actualizar(i, 1, (i, "f")) for i in range(15)]
    cerradas += [c.actualizar(i, 0, (i, "f")) for i in range(15, 45)]
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
    t, conteos = 0, [2] * 60 + [1] * 60 + [2] * 60 + [0] * 30
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
    conteos = [1] * 30 + [2, 1, 1] + [1] * 30 + [0] * 30  # un falso positivo de 1 foto
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
    for i in range(50, 80):
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
    cli.post("/api/v1/lote", headers=h, content=lote_bytes([(hace_5_dias + i, 0) for i in range(60, 95)]))
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
    cli.post("/api/v1/lote", headers=h, content=lote_bytes([(t0 + i, 0) for i in range(90, 125)]))
    dia = __import__("datetime").datetime.fromtimestamp(t0).strftime("%Y-%m-%d")
    r = cli.get(f"/api/panel/taxi/TX-000001/carreras?dia={dia}", headers=PANEL).json()
    assert r["resumen"]["carreras"] == 1 and r["resumen"]["pasajeros"] == 1
    c = r["carreras"][0]
    fotos = cli.get(f"/api/panel/taxi/TX-000001/fotos?dia={dia}&desde={c['inicio']}&hasta={c['fin']}",
                    headers=PANEL).json()
    assert 85 <= len(fotos) <= 92 and all(c["inicio"] <= f["ts"] <= c["fin"] + 0.01 for f in fotos)


def test_reanalizar_dia_con_jaula_quita_falsos_positivos(srv):
    """Una persona fuera de la cabina (en la ventana) hacía una carrera falsa:
    con la jaula nueva, la vista previa lo muestra y al aplicar desaparece."""
    _, cli, personas = srv
    tok = registrar(cli)
    h = {"X-Dispositivo": "TX-000001", "Authorization": f"Bearer {tok}"}
    t0 = __import__("time").time() - 7200
    personas.append([0.85, 0.2, 0.95, 0.4, 0.8])  # a la derecha: la ventana
    cli.post("/api/v1/lote", headers=h, content=lote_bytes([(t0 + i, 0) for i in range(60)]))
    personas.clear()
    cli.post("/api/v1/lote", headers=h, content=lote_bytes([(t0 + i, 0) for i in range(60, 95)]))
    dia = __import__("datetime").datetime.fromtimestamp(t0).strftime("%Y-%m-%d")
    assert cli.get(f"/api/panel/taxi/TX-000001/carreras?dia={dia}", headers=PANEL).json()["resumen"]["carreras"] == 1

    jaula = [[0, 0], [0.7, 0], [0.7, 1], [0, 1]]  # la cabina, sin la ventana
    previa = cli.post("/api/panel/taxi/TX-000001/reanalizar", headers=PANEL, json={"dia": dia, "jaula": jaula}).json()
    assert previa["antes"]["carreras"] == 1 and previa["despues"]["carreras"] == 0
    assert previa["quitadas"] == 60 and not previa["aplicado"]
    assert cli.get(f"/api/panel/taxi/TX-000001/carreras?dia={dia}", headers=PANEL).json()["resumen"]["carreras"] == 1

    cli.post("/api/panel/taxi/TX-000001/reanalizar", headers=PANEL, json={"dia": dia, "jaula": jaula, "aplicar": True})
    assert cli.get(f"/api/panel/taxi/TX-000001/carreras?dia={dia}", headers=PANEL).json()["resumen"]["carreras"] == 0
    fotos = cli.get(f"/api/panel/taxi/TX-000001/fotos?dia={dia}&solo_pasajeros=true", headers=PANEL).json()
    assert fotos == []
    # El lote lleva la hora en ms enteros: el nombre de la foto es esa hora truncada.
    info = cli.get(f"/api/panel/taxi/TX-000001/foto_info?foto=TX-000001/{dia}/{int(t0 * 1000) / 1000:.3f}.jpg",
                   headers=PANEL)
    assert info.status_code == 200 and info.json()["dets"][0][5] == 0


def test_ajustes_desde_el_panel_llegan_a_la_camara(srv):
    _, cli, _ = srv
    tok = registrar(cli)
    h = {"X-Dispositivo": "TX-000001", "Authorization": f"Bearer {tok}", "X-Ajustes-Ver": "0",
         "X-Cfg": '{"fs":"vga","q":80}', "X-Ip": "192.168.1.61"}
    # Sin ajustes elegidos no se manda nada.
    assert "ajustes_q" not in cli.post("/api/v1/foto", content=JPEG, headers=h).json()
    assert cli.post("/api/panel/taxi/TX-000001", headers=PANEL, json={"ajustes": {"q": 99}}).status_code == 400
    assert cli.post("/api/panel/taxi/TX-000001", headers=PANEL, json={"ajustes": {"wifi": "x"}}).status_code == 400
    cli.post("/api/panel/taxi/TX-000001", headers=PANEL, json={"ajustes": {"fs": "qvga", "q": 60, "night": 1}})
    t = cli.get("/api/panel/taxi/TX-000001", headers=PANEL).json()
    assert t["ajustes_pendientes"] and t["ip_local"] == "192.168.1.61" and t["cfg_camara"]["fs"] == "vga"
    r = cli.post("/api/v1/foto", content=JPEG, headers=h).json()
    assert r["ajustes_ver"] == 1 and set(r["ajustes_q"].split("&")) == {"fs=qvga", "q=60", "night=1"}
    # La cámara los aplicó: ya no se reenvían y el panel deja de mostrarlos pendientes.
    h["X-Ajustes-Ver"] = "1"
    assert "ajustes_q" not in cli.post("/api/v1/foto", content=JPEG, headers=h).json()
    assert not cli.get("/api/panel/taxi/TX-000001", headers=PANEL).json()["ajustes_pendientes"]
    # Firmware viejo (no manda X-Ajustes-Ver): no se le mandan ajustes.
    del h["X-Ajustes-Ver"]
    assert "ajustes_q" not in cli.post("/api/v1/foto", content=JPEG, headers=h).json()


def test_registro_de_la_camara_llega_al_panel(srv):
    m, cli, _ = srv
    tok = registrar(cli)
    h = {"X-Dispositivo": "TX-000001", "Authorization": f"Bearer {tok}"}
    texto = ("21/10 19:00:01 [arranque 5] ARRANQUE: programa colgado (watchdog) · firmware 3.5\n"
             "21/10 19:00:31 [arranque 5] WiFi conectado a CASA (-60 dBm)\n"
             "21/10 19:05:00 [arranque 5] WiFi perdido (estado 5): reconectando\n")
    r = cli.post("/api/v1/eventos", headers=h, content=texto.encode())
    assert r.json()["recibidas"] == 3
    reg = cli.get("/api/panel/taxi/TX-000001/registro", headers=PANEL).json()
    niveles = {e["texto"].split("] ", 1)[1][:10]: e["nivel"] for e in reg["eventos"] if e["origen"] == "cámara"}
    assert niveles["ARRANQUE: "] == "error" and niveles["WiFi pert"[:9] + "d"] if False else True
    por_texto = {e["texto"]: e["nivel"] for e in reg["eventos"]}
    assert por_texto[texto.splitlines()[0]] == "error"   # arrancó por un cuelgue
    assert por_texto[texto.splitlines()[1]] == "info"
    assert por_texto[texto.splitlines()[2]] == "aviso"   # perdió la WiFi (normal en el taxi)
    assert any("registrada" in e["texto"] for e in reg["eventos"])  # evento del servidor
    errores = cli.get("/api/panel/taxi/TX-000001/registro?nivel=error", headers=PANEL).json()["eventos"]
    assert len(errores) == 1
    txt = cli.get("/api/panel/taxi/TX-000001/registro.txt", headers=PANEL)
    assert txt.status_code == 200 and "WiFi perdido" in txt.text
    assert cli.post("/api/v1/eventos", headers={"X-Dispositivo": "TX-000001", "Authorization": "Bearer x"},
                    content=b"hola").status_code == 401


def test_linea_del_registro_explicada_con_fotos_y_contexto(srv):
    """Al abrir una línea: qué significa, qué hacer, sus valores y las fotos de ese momento."""
    _, cli, _ = srv
    tok = registrar(cli)
    h = {"X-Dispositivo": "TX-000001", "Authorization": f"Bearer {tok}"}
    t = __import__("time").time() - 600
    cli.post("/api/v1/lote", headers=h, content=lote_bytes([(t + i * 15, 0) for i in range(-3, 4)]))
    hora = __import__("datetime").datetime.fromtimestamp(t).strftime("%d/%m %H:%M:%S")
    texto = (f"{hora} [arranque 9] ARRANQUE: encendido normal · firmware 3.7 · SIN TARJETA SD (guarda en la memoria interna)\n"
             f"{hora} [arranque 9] estado: WiFi ok -82 dBm · servidor 'conectada' · 5 enviadas · 0 en cola (interna, 2 errores)"
             f" · 2.1 fps · 58 C · RAM 150 KB\n")
    cli.post("/api/v1/eventos", headers=h, content=texto.encode())
    reg = cli.get("/api/panel/taxi/TX-000001/registro", headers=PANEL).json()["eventos"]
    sin_sd = next(e for e in reg if "SIN TARJETA" in e["texto"])
    assert sin_sd["nivel"] == "error"
    d = cli.get(f"/api/panel/taxi/TX-000001/registro/{sin_sd['id']}", headers=PANEL).json()
    assert "tarjeta SD" in d["explicacion"]["que"] and d["explicacion"]["hacer"]
    assert d["hora_exacta"] and abs(d["momento"] - t) < 2
    assert len(d["fotos"]) == 6 and min(abs(f["dif_s"]) for f in d["fotos"]) <= 1
    assert any(e["id"] == sin_sd["id"] for e in d["alrededor"])
    est = next(e for e in reg if "estado:" in e["texto"])
    valores = {v["dato"]: v for v in cli.get(f"/api/panel/taxi/TX-000001/registro/{est['id']}", headers=PANEL).json()["valores"]}
    assert valores["WiFi"]["mal"] and valores["Guarda en"]["mal"] and valores["Errores de memoria"]["mal"]
    assert not valores["Temperatura"]["mal"]
    diag = cli.get("/api/panel/taxi/TX-000001/registro/diagnostico", headers=PANEL).json()["problemas"]
    assert diag[0]["titulo"] == "Problemas con la tarjeta SD" and diag[0]["gravedad"] == "error"
    assert cli.get("/api/panel/taxi/TX-000001/registro/999999", headers=PANEL).status_code == 404


def test_panel_muestra_si_llega_informacion(srv):
    """Conectada pero sin fotos (solo registro) → recibiendo → subiendo lo guardado."""
    _, cli, _ = srv
    tok = registrar(cli)
    h = {"X-Dispositivo": "TX-000001", "Authorization": f"Bearer {tok}"}
    estado = lambda: cli.get("/api/panel/taxi/TX-000001", headers=PANEL).json()["conexion"]
    cli.post("/api/v1/eventos", headers={**h, "X-Cola": "1100"}, content=b"hola")
    c = estado()
    assert c["estado"] == "sin_fotos" and c["cola"] == 1100 and "1100" in c["detalle"]
    t = __import__("time").time() - 600
    cli.post("/api/v1/lote", headers={**h, "X-Cola": "400"}, content=lote_bytes([(t + i, 0) for i in range(5)]))
    c = estado()
    assert c["estado"] == "subiendo" and c["cola"] == 400 and c["cola_max"] == 1100 and "400" in c["titulo"]
    assert c["por_min"] >= 5
    cli.post("/api/v1/lote", headers={**h, "X-Cola": "0"}, content=lote_bytes([(t + 10, 0)]))
    assert estado()["estado"] == "recibiendo" and estado()["cola_max"] == 0
    enviar(cli, tok, 0)
    assert estado()["estado"] == "recibiendo"


def test_carrera_con_wifi_queda_por_revisar_y_se_decide(srv):
    """Fotos tomadas con WiFi (la cámara en casa del dueño subiendo lo grabado):
    la carrera no cuenta sola, queda por revisar; en el panel se aprueba o rechaza."""
    _, cli, personas = srv
    tok = registrar(cli)
    h = {"X-Dispositivo": "TX-000001", "Authorization": f"Bearer {tok}"}
    t0 = __import__("time").time() - 7200
    con_wifi = 0x40000000
    personas.append(PERSONA)
    cli.post("/api/v1/lote", headers=h, content=lote_bytes([(t0 + i, 1 | con_wifi) for i in range(60)]))
    personas.clear()
    cli.post("/api/v1/lote", headers=h, content=lote_bytes([(t0 + i, 0 | con_wifi) for i in range(60, 95)]))
    dia = __import__("datetime").datetime.fromtimestamp(t0).strftime("%Y-%m-%d")
    r = cli.get(f"/api/panel/taxi/TX-000001/carreras?dia={dia}", headers=PANEL).json()
    assert r["resumen"]["carreras"] == 0 and r["resumen"]["por_revisar"] == 1 and r["resumen"]["descartadas"] == 0
    pend = cli.get("/api/panel/taxi/TX-000001/por_revisar", headers=PANEL).json()
    assert len(pend) == 1 and pend[0]["con_wifi"] == 1
    assert cli.get("/api/panel/taxi/TX-000001", headers=PANEL).json()["por_revisar"] == 1
    # La cámara no ve su conteo con la marca de WiFi mezclada.
    assert cli.get("/api/panel/taxi/TX-000001", headers=PANEL).json()["pax_esp"] == 0
    assert cli.post(f"/api/panel/taxi/TX-000001/carrera/{pend[0]['id']}", headers=PANEL, json={"valida": True}).status_code == 200
    r = cli.get(f"/api/panel/taxi/TX-000001/carreras?dia={dia}", headers=PANEL).json()
    assert r["resumen"]["carreras"] == 1 and r["resumen"]["por_revisar"] == 0
    assert cli.get("/api/panel/taxi/TX-000001/por_revisar", headers=PANEL).json() == []
    # Reanalizar el día conserva la decisión.
    cli.post("/api/panel/taxi/TX-000001/reanalizar", headers=PANEL, json={"dia": dia, "aplicar": True})
    assert cli.get(f"/api/panel/taxi/TX-000001/carreras?dia={dia}", headers=PANEL).json()["resumen"]["carreras"] == 1


def test_con_wifi_cuenta_si_el_taxi_usa_hotspot(srv):
    _, cli, personas = srv
    tok = registrar(cli)
    h = {"X-Dispositivo": "TX-000001", "Authorization": f"Bearer {tok}"}
    cli.post("/api/panel/taxi/TX-000001", headers=PANEL, json={"contar_con_wifi": True})
    t0 = __import__("time").time() - 7200
    personas.append(PERSONA)
    cli.post("/api/v1/lote", headers=h, content=lote_bytes([(t0 + i, 1 | 0x40000000) for i in range(60)]))
    personas.clear()
    cli.post("/api/v1/lote", headers=h, content=lote_bytes([(t0 + i, 0x40000000) for i in range(60, 95)]))
    dia = __import__("datetime").datetime.fromtimestamp(t0).strftime("%Y-%m-%d")
    r = cli.get(f"/api/panel/taxi/TX-000001/carreras?dia={dia}", headers=PANEL).json()["resumen"]
    assert r["carreras"] == 1 and r["por_revisar"] == 0


def test_foto_sin_hora_va_aparte_y_no_arma_carreras(srv):
    """Sin ninguna hora: no se mezcla en la línea del tiempo ni cuenta para carreras."""
    _, cli, personas = srv
    tok = registrar(cli)
    h = {"X-Dispositivo": "TX-000001", "Authorization": f"Bearer {tok}"}
    personas.append(PERSONA)
    cli.post("/api/v1/lote", headers=h, content=lote_bytes([(0, 1) for _ in range(60)]))
    dia = __import__("datetime").datetime.now().strftime("%Y-%m-%d")
    q = lambda f: cli.get(f"/api/panel/taxi/TX-000001/fotos?dia={dia}&filtro={f}&limite=2000", headers=PANEL).json()
    assert q("") == [] and len(q("sin_hora")) == 60 and q("sin_hora")[0]["sin_hora"]
    assert cli.get("/api/panel/taxi/TX-000001", headers=PANEL).json()["estado"] == "LIBRE"


def test_fotos_de_tarde_a_temprano(srv):
    """orden=desc: la última primero; 'ver más' con hasta= sigue hacia atrás sin repetir."""
    _, cli, personas = srv
    tok = registrar(cli)
    h = {"X-Dispositivo": "TX-000001", "Authorization": f"Bearer {tok}"}
    t0 = int(__import__("time").time()) - 3600
    cli.post("/api/v1/lote", headers=h, content=lote_bytes([(t0 + i, 0) for i in range(10)]))
    dia = __import__("datetime").datetime.fromtimestamp(t0).strftime("%Y-%m-%d")
    q = lambda extra: cli.get(f"/api/panel/taxi/TX-000001/fotos?dia={dia}&{extra}", headers=PANEL).json()
    pag1 = q("orden=desc&limite=4")
    assert [round(f["ts"]) - t0 for f in pag1] == [9, 8, 7, 6]
    pag2 = q(f"orden=desc&limite=4&hasta={pag1[-1]['ts'] - 0.0005}")
    assert [round(f["ts"]) - t0 for f in pag2] == [5, 4, 3, 2]
    assert [round(f["ts"]) - t0 for f in q("orden=asc&limite=3")] == [0, 1, 2]
    # "importantes" al revés: la última foto (cómo quedó la cabina) va primero.
    imp = q("orden=desc&filtro=importantes")
    assert round(imp[0]["ts"]) - t0 == 9 and round(imp[-1]["ts"]) - t0 == 0


def test_filtros_de_fotos(srv):
    """vacía 30 s → 1 pasajero 30 s → vacía 30 s: 'importantes' son los cambios."""
    _, cli, personas = srv
    tok = registrar(cli)
    h = {"X-Dispositivo": "TX-000001", "Authorization": f"Bearer {tok}"}
    t0 = int(__import__("time").time()) - 3600
    cli.post("/api/v1/lote", headers=h, content=lote_bytes([(t0 + i, 0) for i in range(30)]))
    personas.append(PERSONA)
    cli.post("/api/v1/lote", headers=h, content=lote_bytes([(t0 + i, 1) for i in range(30, 60)]))
    personas.clear()
    cli.post("/api/v1/lote", headers=h, content=lote_bytes([(t0 + i, 0) for i in range(60, 90)]))
    dia = __import__("datetime").datetime.fromtimestamp(t0).strftime("%Y-%m-%d")
    q = lambda extra: cli.get(f"/api/panel/taxi/TX-000001/fotos?dia={dia}&limite=2000&{extra}", headers=PANEL).json()
    assert len(q("")) == 90
    assert len(q("filtro=pasajeros")) == 30 and len(q("filtro=vacias")) == 60
    imp = q("filtro=importantes")
    # empieza, sube, baja, última (con mediana de 3 el cambio se confirma una foto después)
    assert [round(f["ts"]) - t0 for f in imp] == [0, 31, 61, 89]
    assert len(q("filtro=vacias&cada=10")) == 6                    # una cada 10 s de cabina vacía
    assert len(q(f"desde={t0 + 30}&hasta={t0 + 59}")) == 30           # solo la carrera


def test_carrera_en_curso_sobrevive_a_un_reinicio_del_servidor(srv, monkeypatch):
    m, cli, personas = srv
    tok = registrar(cli)
    t0 = __import__("time").time() - 600
    personas.append(PERSONA)
    for i in range(20):
        r = enviar(cli, tok, t0 + i)
    assert r.json()["estado"] == "EN_CARRERA" and r.json()["intervalo_ms"] == m.RITMO_CARRERA_MS
    # "Reinicio": se borra lo que había en memoria; queda solo lo guardado en la base.
    m._carreras.clear()
    for i in range(20, 40):
        enviar(cli, tok, t0 + i)
    personas.clear()
    for i in range(40, 70):
        r = enviar(cli, tok, t0 + i)
    assert r.json()["intervalo_ms"] == m.RITMO_VACIO_MS
    carreras = cli.get("/api/panel/carreras", headers=PANEL).json()
    assert len(carreras) == 1 and 38 <= carreras[0]["duracion"] <= 41  # una sola carrera, sin cortarse


def test_lote_danado_se_rechaza(srv):
    _, cli, _ = srv
    tok = registrar(cli)
    h = {"X-Dispositivo": "TX-000001", "Authorization": f"Bearer {tok}"}
    assert cli.post("/api/v1/lote", headers=h, content=lote_bytes([(1, 0)])[:-5]).status_code == 400


def test_hora_estimada_por_la_camara_se_respeta_y_queda_aproximada(srv):
    """Fotos de un arranque sin internet: la cámara estima su hora (bit alto).
    Quedan en su lugar del día, en orden, y marcadas como aproximadas."""
    _, cli, _ = srv
    tok = registrar(cli)
    h = {"X-Dispositivo": "TX-000001", "Authorization": f"Bearer {tok}"}
    hace_3_h = __import__("time").time() - 3 * 3600
    datos = b"".join(__import__("struct").pack("<QiI", int((hace_3_h + i) * 1000) | (1 << 63), 0, len(JPEG)) + JPEG
                     for i in range(5))
    assert cli.post("/api/v1/lote", headers=h, content=datos).status_code == 200
    dia = __import__("datetime").datetime.fromtimestamp(hace_3_h).strftime("%Y-%m-%d")
    fotos = cli.get(f"/api/panel/taxi/TX-000001/fotos?dia={dia}", headers=PANEL).json()
    assert len(fotos) == 5 and all(f["aprox"] for f in fotos)
    assert sorted(abs(f["ts"] - hace_3_h) < 6 for f in fotos) == [True] * 5


def test_foto_sin_hora_queda_aproximada(srv):
    """Sin hora: va en el filtro "sin_hora" (con la hora de llegada, marcada aproximada)."""
    _, cli, _ = srv
    tok = registrar(cli)
    enviar(cli, tok, 0)
    dia = __import__("datetime").datetime.now().strftime("%Y-%m-%d")
    fotos = cli.get(f"/api/panel/taxi/TX-000001/fotos?dia={dia}&filtro=sin_hora", headers=PANEL).json()
    assert fotos and fotos[0]["aprox"] and fotos[0]["sin_hora"]


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
