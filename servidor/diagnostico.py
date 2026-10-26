"""Explica en palabras simples las líneas del registro de una cámara y busca
problemas en las últimas horas (pestaña Registro del panel)."""
import re
import time
from datetime import datetime

# (patrón, gravedad, qué pasó, posibles causas, qué hacer). La primera regla que
# coincide gana: las más específicas van primero.
_REGLAS = [
    (r"SIN TARJETA SD", "error",
     "Al encender no encontró la tarjeta SD: guarda las fotos en la memoria interna (unas 600).",
     "La tarjeta no está bien puesta, se movió por las vibraciones, o el cargador da poca corriente al encender.",
     "Saca y vuelve a poner la tarjeta. Cuando vuelva a verla, la cámara pasa sola a la SD lo guardado en la memoria interna."),
    (r"ARRANQUE: CAIDA DE VOLTAJE|ARRANQUE:.*falta corriente", "error",
     "La cámara se reinició porque le faltó corriente (bajó el voltaje).",
     "Cargador o power bank débil, cable largo o de mala calidad, o el encendedor del auto da poca corriente al arrancar el motor.",
     "Usa un cargador de 2 A o más y un cable USB corto y bueno. Si pasa al encender el auto, conéctala después de arrancar."),
    (r"ARRANQUE: FALLO", "error",
     "El programa de la cámara tuvo un error y la placa se reinició sola.",
     "Un error del firmware (a veces por falta de memoria o una foto dañada).",
     "Si se repite seguido, descarga el registro completo y revisa qué pasaba justo antes."),
    (r"ARRANQUE: programa colgado", "error",
     "El programa se quedó trabado y el vigilante (watchdog) reinició la placa.",
     "Una tarea que tardó demasiado: WiFi muy débil, tarjeta SD lenta o un envío que no terminaba.",
     "Mira las líneas de antes: WiFi débil (cerca de -80 dBm) o errores de la SD."),
    (r"ARRANQUE: encendido normal", "aviso",
     "La cámara se encendió (recibió corriente).",
     "Normal si la conectaste. Si nadie la tocó, se cortó la corriente: el auto se apagó, el cable se movió o el power bank se apagó solo.",
     "Si aparece muchas veces seguidas sin que la desconectes, revisa el cable y el cargador."),
    (r"ARRANQUE: reinicio por software", "info",
     "La cámara se reinició a propósito.",
     "Cambio de WiFi o de resolución, actualización de firmware o un comando por cable.",
     "Nada, es normal."),
    (r"tarjeta SD dejó de responder", "error",
     "La tarjeta SD dejó de responder mientras funcionaba; siguió guardando en la memoria interna.",
     "Mal contacto (vibración), corte breve de corriente o tarjeta defectuosa.",
     "Revisa que la tarjeta esté firme. Si se repite, cámbiala por una de buena marca (clase 10 / A1)."),
    (r"tarjeta SD montada de nuevo", "aviso",
     "La tarjeta SD falló un momento y la cámara la recuperó sola. No se perdieron fotos.",
     "Mal contacto o corte breve de corriente.",
     "Si pasa seguido, asegura la tarjeta y revisa el cable de corriente."),
    (r"se pasaron a la SD", "info",
     "Fotos que habían quedado en la memoria interna (cuando falló la SD) se pasaron a la tarjeta y se subirán.",
     "En algún arranque la tarjeta no estaba disponible.", "Nada: se recuperaron."),
    (r"prueba de memoria .*FALLO", "error",
     "La prueba de la memoria falló: no se pudo escribir o leer bien.",
     "Tarjeta SD dañada o mal puesta.", "Cambia la tarjeta SD."),
    (r"prueba de memoria", "info", "Resultado de la prueba de la memoria (comando SDTEST).", "", ""),
    (r"memoria llena: se descartaron", "error",
     "La memoria se llenó y se borraron las fotos más viejas que no se habían subido.",
     "Muchos días sin internet, o la tarjeta es pequeña.",
     "Conecta la cámara a internet más seguido, o pon una tarjeta más grande."),
    (r"memoria llena", "aviso", "La memoria está llena.", "", "Conéctala a internet para que suba las fotos."),
    (r"servidor no responde \(código 5\d\d\)", "aviso",
     "La cámara tiene internet pero el servidor no contestó. Las fotos se guardan y se suben después.",
     "El servidor está apagado o cambió la dirección del túnel (trycloudflare cambia cada vez que se reinicia).",
     "Arranca el servidor con -Tunel -Esp <ip-de-la-cámara> para que la cámara reciba la dirección nueva."),
    (r"servidor no responde", "aviso",
     "No se pudo hablar con el servidor. Las fotos se guardan y se suben después.",
     "Sin internet en la red WiFi, o el servidor está apagado.", "Revisa el internet de la red y que el servidor esté prendido."),
    (r"servidor responde de nuevo", "info", "El servidor volvió a contestar: se sube lo pendiente.", "", ""),
    (r"no se pudo conectar a", "error",
     "La cámara vio una red guardada pero no pudo conectarse.",
     "Clave incorrecta, o la red cambió de clave.", "Vuelve a guardar la red con la clave correcta (BOOT 3 s → Taxiff-Cam)."),
    (r"ninguna red guardada disponible", "aviso",
     "No encontró ninguna de sus redes WiFi: graba sin internet y busca de nuevo cada minuto.",
     "Normal en el taxi. En casa: la red está apagada, es solo de 5 GHz o está lejos.",
     "Nada en el taxi. En casa, revisa que la WiFi sea de 2,4 GHz y esté cerca."),
    (r"sin redes WiFi guardadas", "aviso",
     "La cámara no tiene ninguna red guardada.", "Es nueva o se borraron.",
     "Conéctate a Taxiff-Cam desde el celular y elige la red."),
    (r"WiFi perdido", "aviso",
     "Se perdió la conexión WiFi. Sigue grabando y se reconecta sola.",
     "El taxi salió del alcance, el hotspot se apagó o la señal es débil.", "Nada, salvo que pase seguido estando quieta."),
    (r"WiFi conectado", "info", "Se conectó a una red WiFi.", "", ""),
    (r"red de configuración", "info",
     "La red Taxiff-Cam (para configurar la WiFi desde el celular) se abrió o se cerró.", "", ""),
    (r"red WiFi (agregada|quitada)", "info", "Cambió la lista de redes WiFi guardadas.", "", ""),
    (r"PRUEBA SIN WiFi", "aviso", "Modo de prueba: actúa como si no hubiera WiFi.", "Comando SINWIFI.",
     "Termina con CONWIFI o se acaba solo a los 3 arranques."),
    (r"MUY caliente", "error",
     "La cámara se calentó demasiado y bajó el ritmo para enfriarse.",
     "Sol directo sobre la caja o caja sin ventilación.", "Ponla a la sombra y deja agujeros de ventilación en la caja."),
    (r"temperatura normal", "info", "La temperatura volvió a lo normal.", "", ""),
    (r"FALLO: la cámara no da imagen", "error",
     "El sensor de la cámara dejó de dar imagen y se reinició la placa.",
     "Cable plano de la cámara flojo, calor o falta de corriente.", "Revisa el cable plano de la cámara."),
    (r"la cámara dejó de dar imagen", "aviso",
     "El sensor dejó de dar imagen un momento y se reinició.", "Calor o corriente justa.", "Si se repite, revisa el cable plano."),
    (r"FALLÓ la actualización", "error",
     "No se pudo instalar el firmware nuevo; sigue con el anterior.", "Internet lento o cortado durante la descarga.",
     "Se reintenta sola. Si sigue fallando, cárgalo por cable."),
    (r"instalando firmware|firmware nuevo instalado", "info", "Actualización del firmware por internet.", "", ""),
    (r"ajustes (recibidos|enviados)", "info", "Cambio de ajustes desde el panel.", "", ""),
    (r"reinicio pedido", "info", "Se reinicia para aplicar un ajuste (resolución).", "", ""),
    (r"carrera válida", "info", "El servidor cerró una carrera.", "", ""),
    (r"carrera descartada", "info",
     "Detección de pasajeros demasiado corta para ser una carrera (menos de 30 s).",
     "Un falso positivo del detector, o alguien que entró y salió.", "Si son muchas, revisa la jaula en la pestaña Jaula."),
    (r"dejó de enviar .* en plena carrera", "aviso",
     "La cámara dejó de enviar fotos en medio de una carrera; se cerró sola.",
     "Se apagó o perdió internet.", "Mira si hay un ARRANQUE o un WiFi perdido cerca."),
    (r"registrada|registre de nuevo", "info", "Registro de la cámara en el servidor.", "", ""),
    (r"jaula|reanalizado", "info", "Cambio en la jaula o reanálisis del día.", "", ""),
]
_REGLAS = [(re.compile(p, re.I), *r) for p, *r in _REGLAS]

_ESTADO = re.compile(
    r"estado: (?P<wifi>.+?) (?P<rssi>-?\d+) dBm · servidor '(?P<srv>[^']*)' · (?P<enviadas>\d+) enviadas · "
    r"(?P<cola>\d+) en cola(?: \((?P<mem>\w+), (?P<memerr>\d+) errores\))? · (?P<fps>[\d.]+) fps · "
    r"(?P<temp>-?\d+) C · RAM (?P<ram>\d+) KB")


def _senal(rssi):
    if rssi == 0:
        return "sin conexión"
    if rssi > -60:
        return "buena"
    if rssi > -70:
        return "aceptable"
    if rssi > -80:
        return "débil: puede cortarse"
    return "muy débil: casi no sube nada"


def estado(texto):
    """Valores de una línea de estado (la que la cámara anota cada minuto), con su lectura."""
    m = _ESTADO.search(texto)
    if not m:
        return None
    g = m.groupdict()
    rssi, temp, cola, ram = int(g["rssi"]), int(g["temp"]), int(g["cola"]), int(g["ram"])
    filas = [
        ("WiFi", f"{g['wifi']} · {rssi} dBm ({_senal(rssi)})", rssi and rssi <= -75),
        ("Servidor", g["srv"], g["srv"] != "conectada"),
        # Muchas fotos en cola es normal al volver a tener internet; solo preocupa
        # si es más de lo que la cámara graba en un día entero.
        ("Fotos esperando subir", f"{cola}" + (" (todas subidas)" if not cola else ""), cola > 6000),
        ("Fotos por segundo", g["fps"], float(g["fps"]) < 0.5),
        ("Temperatura", f"{temp} °C" + (" (alta)" if temp >= 70 else ""), temp >= 70),
        ("Memoria RAM libre", f"{ram} KB" + (" (poca)" if ram < 60 else ""), ram < 60),
    ]
    if g["mem"]:
        filas.insert(3, ("Guarda en", "tarjeta SD" if g["mem"] == "SD" else "memoria interna (¡sin SD!)",
                         g["mem"] != "SD"))
        if int(g["memerr"]):
            filas.insert(4, ("Errores de memoria", g["memerr"], True))
    return [{"dato": d, "valor": v, "mal": bool(mal)} for d, v, mal in filas]


def explicar(texto):
    """{gravedad, que, causa, hacer} de una línea del registro."""
    if _ESTADO.search(texto):
        return {"gravedad": "info", "que": "Resumen que la cámara anota cada minuto.",
                "causa": "", "hacer": "Mira abajo los valores marcados en rojo, si hay."}
    for patron, gravedad, que, causa, hacer in _REGLAS:
        if patron.search(texto):
            return {"gravedad": gravedad, "que": que, "causa": causa, "hacer": hacer}
    return {"gravedad": "info", "que": "Mensaje informativo.", "causa": "", "hacer": ""}


def hora_camara(texto, recibido):
    """Hora en que la cámara anotó la línea ("23/10 10:38:59 [arranque 28] …"),
    o la de llegada si no la sabía ("+12s sin hora")."""
    m = re.match(r"(\d{2})/(\d{2}) (\d{2}):(\d{2}):(\d{2}) ", texto)
    if not m:
        return recibido, False
    dia, mes, h, mi, s = map(int, m.groups())
    anio = datetime.fromtimestamp(recibido).year
    try:
        t = datetime(anio, mes, dia, h, mi, s).timestamp()
    except ValueError:
        return recibido, False
    if t > recibido + 86400:  # anotada en diciembre, recibida en enero
        t = datetime(anio - 1, mes, dia, h, mi, s).timestamp()
    return t, True


# Problemas que se buscan en las últimas 24 h: (patrón, mínimo de veces, gravedad,
# título, consejo, palabra para filtrar la lista).
_PROBLEMAS = [
    (r"ARRANQUE: (CAIDA DE VOLTAJE|.*falta corriente)", 1, "error", "Le faltó corriente",
     "Usa un cargador de 2 A o más y un cable corto.", "CAIDA"),
    (r"ARRANQUE: encendido normal", 4, "aviso", "Se apagó y encendió muchas veces",
     "Si nadie la desconectó, se está cortando la corriente: revisa cable, cargador o power bank.", "encendido normal"),
    (r"ARRANQUE: (FALLO|programa colgado)", 1, "error", "El programa falló o se colgó",
     "Abre esas líneas para ver qué pasaba justo antes.", "ARRANQUE"),
    (r"SIN TARJETA SD|tarjeta SD dejó de responder|prueba de memoria .*FALLO", 1, "error",
     "Problemas con la tarjeta SD", "Revisa que esté firme; si se repite, cámbiala.", "SD"),
    (r"tarjeta SD montada de nuevo", 3, "aviso", "La tarjeta SD falla de a ratos",
     "Se recupera sola, pero conviene revisar el contacto y la corriente.", "SD"),
    (r"memoria llena: se descartaron", 1, "error", "Se borraron fotos por memoria llena",
     "Conéctala a internet más seguido o usa una tarjeta más grande.", "memoria llena"),
    (r"servidor no responde", 3, "aviso", "El servidor no respondía",
     "Revisa que el servidor y el túnel estén prendidos (-Tunel -Esp).", "servidor"),
    (r"no se pudo conectar a", 1, "error", "Clave de WiFi incorrecta",
     "Vuelve a guardar la red con la clave correcta.", "no se pudo conectar"),
    (r"WiFi perdido", 6, "aviso", "La WiFi se corta seguido",
     "Señal débil o hotspot que se apaga. Acerca la cámara o el teléfono.", "WiFi"),
    (r"MUY caliente", 1, "error", "Se calentó demasiado", "Sombra y ventilación para la caja.", "caliente"),
    (r"no da imagen|dejó de dar imagen", 1, "error", "El sensor de la cámara falló",
     "Revisa el cable plano de la cámara.", "imagen"),
    (r"FALLÓ la actualización", 1, "aviso", "Una actualización falló", "Se reintenta sola.", "actualización"),
]
_PROBLEMAS = [(re.compile(p, re.I), *r) for p, *r in _PROBLEMAS]


def problemas(eventos):
    """Lista de problemas encontrados en `eventos` (filas de la tabla, cualquier orden)."""
    out = []
    for patron, minimo, gravedad, titulo, consejo, buscar in _PROBLEMAS:
        hits = [e for e in eventos if patron.search(e["texto"])]
        if len(hits) >= minimo:
            out.append({"gravedad": gravedad, "titulo": titulo, "veces": len(hits), "consejo": consejo,
                        "buscar": buscar, "ultima": max(e["recibido"] for e in hits)})
    # Señal WiFi débil de forma sostenida (en las líneas de estado).
    rssis = [int(m.group("rssi")) for e in eventos if (m := _ESTADO.search(e["texto"])) and int(m.group("rssi"))]
    if len(rssis) >= 10 and sum(r <= -75 for r in rssis) / len(rssis) > 0.5:
        out.append({"gravedad": "aviso", "titulo": "Señal WiFi débil",
                    "veces": sum(r <= -75 for r in rssis),
                    "consejo": "La mayor parte del tiempo la señal fue -75 dBm o peor: acerca la cámara al router o al teléfono.",
                    "buscar": "estado", "ultima": time.time()})
    out.sort(key=lambda p: (p["gravedad"] != "error", -p["veces"]))
    return out
