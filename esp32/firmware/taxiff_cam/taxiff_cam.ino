// Taxiff Cam v1 · ESP32-S3 + OV3660, todo en el chip.
//
// - Cámara + detección en el ESP32: cabezas con FOMO (modelo propio de Edge
//   Impulse, 160x160 en gris) o caras (ESP-DL de Espressif), a elegir en la página.
// - Lógica de carrera en el ESP32: LIBRE → CONFIRMANDO → EN CARRERA; cierra
//   tras 10 s sin nadie y descarta carreras de menos de 30 s.
// - Página web propia: se abre desde cualquier navegador de la misma red
//   (http://taxiff-cam.local o la IP que muestra el puerto serie).
// - Configuración WiFi sin código: si no conoce ninguna red, crea la red
//   "Taxiff-Cam" (clave taxiff123); al conectarse se abre 192.168.4.1 para
//   elegir la WiFi de la casa o el hotspot del teléfono.

#include <WiFi.h>
#include <ESPmDNS.h>
#include <DNSServer.h>
#include <algorithm>
#include <vector>
#include <Preferences.h>
#include <FFat.h>
#include <SD_MMC.h>
#include "ff.h"
#include <HTTPClient.h>
#include <Update.h>
#include <WiFiClientSecure.h>
#include "esp_camera.h"
#include "esp_http_server.h"
#include "img_converters.h"
#include "human_face_detect_msr01.hpp"
#include "human_face_detect_mnp01.hpp"
#include <taxiff-cabezas-v2_inferencing.h>
#include "time.h"
#include "mbedtls/aes.h"
#include "mbedtls/base64.h"
#include "lwip/sockets.h"
// CLAVE_ADMIN: la crea cargar_firmware.ps1 la primera vez (no se sube a GitHub).
#include "secretos.h"

// Va aquí arriba porque Arduino coloca los prototipos de las funciones antes
// del resto del código, y algunas usan este tipo.
struct Red { String ssid, pass; };  // una red WiFi guardada
struct BootRec { uint32_t boot, start, dur; };  // un arranque; start: hora (s) de inicio, 0 = no la supo
const int32_t FOTO_CON_WIFI = 0x40000000;       // bit en el conteo de una foto: se tomó con WiFi

// ---- Pines de cámara (ESP32-S3-EYE / Freenove S3 CAM) ----------------------
#define XCLK_GPIO_NUM 15
#define SIOD_GPIO_NUM 4
#define SIOC_GPIO_NUM 5
#define Y9_GPIO_NUM 16
#define Y8_GPIO_NUM 17
#define Y7_GPIO_NUM 18
#define Y6_GPIO_NUM 12
#define Y5_GPIO_NUM 10
#define Y4_GPIO_NUM 8
#define Y3_GPIO_NUM 9
#define Y2_GPIO_NUM 11
#define VSYNC_GPIO_NUM 6
#define HREF_GPIO_NUM 7
#define PCLK_GPIO_NUM 13

static const char *AP_SSID = "Taxiff-Cam";
static const char *AP_PASS = "taxiff123";

// ---- Reglas de carrera ------------------------------------------------------
static const uint32_t ENTER_CONFIRM_MS = 1000;
static const uint32_t EXIT_GRACE_MS = 20000;
static const uint32_t MIN_TRIP_MS = 30000;

Preferences prefs;
httpd_handle_t server = nullptr;
// Ajustes en caliente (panel de la página / endpoint /set), guardados en la
// memoria del ESP32. La resolución se aplica al arrancar (cambiarla reinicia).
float detScale = 0.4F;  // escala del detector: más = caras más pequeñas/lejanas, más lento
float detThr = 0.1F;    // umbral de la 1.ª etapa
int jpegQ = 60;
int frameSz = FRAMESIZE_QVGA;
volatile bool restartPending = false;
bool night = true;
volatile bool reconfig = true;
HumanFaceDetectMSR01 *s1 = nullptr;
static HumanFaceDetectMNP01 s2(0.5F, 0.3F, 5);

// Detector de cabezas FOMO: recibe la foto reducida a la entrada del modelo
// (como se entrenó) y devuelve centroides. A veces marca la misma cabeza dos
// o tres veces: los centroides a menos de `mergeCells` celdas se unen.
bool usePersons = true;
float personThr = 0.5F;
float mergeCells = 2.5F;
uint8_t *eiRgb = nullptr;  // entrada del modelo, RGB888 en PSRAM
const int EI_W = EI_CLASSIFIER_INPUT_WIDTH, EI_H = EI_CLASSIFIER_INPUT_HEIGHT;

// Último fotograma (JPEG) y su detección, compartidos con el servidor web.
SemaphoreHandle_t lock;
uint8_t *lastJpg = nullptr;
size_t lastLen = 0;
String lastDet = "{}";

// Estado de la carrera.
enum TripState { LIBRE, CONFIRMANDO, EN_CARRERA };
TripState state = LIBRE;
uint32_t candStart = 0, tripStart = 0, zeroSince = 0;
int maxPax = 0, paxNow = 0, recentMax[5] = {0};
uint32_t frames = 0, detMs = 0;
float fps = 0;

// Métricas de carga y temperatura. Los tiempos son promedios móviles por foto:
// esperar a la cámara, detectar, comprimir a JPEG. "busy" es el % del tiempo
// del bucle que la CPU pasa trabajando (detectar + JPEG) en vez de esperar.
bool detOn = true;
float camAvg = 0, detAvg = 0, jpgAvg = 0, busy = 0, temp = 0, tempMax = 0;
bool hot = false;              // protección térmica activa
const float HOT_ON = 80, HOT_OFF = 72;
volatile uint32_t sentBytes = 0;
float sendKBs = 0;

// Vigilancia de la cámara: en el carro la vibración o un cargador débil
// pueden dejarla sin enviar fotos. Tras 3 s sin imagen se reinicia la
// cámara; si 3 reinicios seguidos no la reviven, se reinicia la placa.
uint32_t camFailSince = 0, camReinits = 0, camReinitsInRow = 0;

// Cámara montada al revés: el sensor gira la imagen 180° sin costo.
bool rot180 = false;

// Almacenamiento: la tarjeta microSD si hay una (pines de la placa tipo
// Freenove ESP32-S3 CAM, modo 1 bit); si no, la memoria interna (FFat, 9 MB).
// Ahí van la cola de envío sin internet (/q) y las fotos para entrenar (/fotos).
const int SD_CLK = 39, SD_CMD = 38, SD_D0 = 40;
bool fatOk = false, sdOk = false;
fs::FS *store = &FFat;
volatile uint32_t freeKB = 0;  // espacio libre (se recalcula cada 10 s: en la SD es lento)

bool storeOk() { return sdOk || fatOk; }

// Espacio libre de la SD. SD_MMC.totalBytes()/usedBytes() de este core miran
// siempre la unidad "0:", que es la memoria interna (se monta antes), así que
// se busca a mano la unidad grande (la tarjeta).
uint64_t sdFreeBytes() {
  for (char d = '0'; d <= '3'; d++) {
    char drv[3] = {d, ':', 0};
    FATFS *fs;
    DWORD freeClusters;
    if (f_getfree(drv, &freeClusters, &fs) != FR_OK) continue;
    uint64_t total = (uint64_t)(fs->n_fatent - 2) * fs->csize * 512;
    if (total > 1000000000ULL) return (uint64_t)freeClusters * fs->csize * 512;
  }
  return 0;
}

uint32_t measureFreeKB() {
  if (sdOk) return (uint32_t)(sdFreeBytes() / 1024);
  return fatOk ? FFat.freeBytes() / 1024 : 0;
}

// Fotos para entrenar: se guardan cada `capEvery` segundos o al pulsar
// "Guardar foto", y la PC las descarga.
bool capNow = false;
int capEvery = 0;
uint32_t capCount = 0, lastCap = 0;
uint32_t capMinFreeKB() { return sdOk ? 100 * 1024 : 300; }
void removeFilesIn(const char *dirPath);
void logEvent(const char *fmt, ...);

// ---- Redes WiFi guardadas -----------------------------------------------------
// Hasta 5 (la casa del dueño, su hotspot, la de un familiar…), la más reciente
// primero. Se conecta sola a la que tenga mejor señal entre las que ve.
const int MAX_REDES = 5;
DNSServer dns;
uint32_t portalUntil = 0;  // la red propia de configuración se cierra a esta hora (millis)
uint32_t portalDesde = 0;  // cuándo se abrió (buscar redes en ese mismo instante no ve ninguna)

std::vector<Red> loadNetworks() {
  // Las versiones anteriores guardaban una sola red en "ssid"/"pass".
  if (prefs.isKey("ssid") && !prefs.isKey("w0")) {
    String s = prefs.getString("ssid", "");
    if (s.length()) prefs.putString("w0", s + "\t" + prefs.getString("pass", ""));
    prefs.remove("ssid");
    prefs.remove("pass");
  }
  std::vector<Red> v;
  for (int i = 0; i < MAX_REDES; i++) {
    String e = prefs.getString(("w" + String(i)).c_str(), "");
    int t = e.indexOf('\t');
    if (t > 0) v.push_back({e.substring(0, t), e.substring(t + 1)});
  }
  return v;
}

void saveNetworks(const std::vector<Red> &v) {
  for (int i = 0; i < MAX_REDES; i++) {
    String k = "w" + String(i);
    if (i < (int)v.size()) prefs.putString(k.c_str(), v[i].ssid + "\t" + v[i].pass);
    else if (prefs.isKey(k.c_str())) prefs.remove(k.c_str());
  }
}

void addNetwork(const String &ssid, const String &pass) {
  auto v = loadNetworks();
  v.erase(std::remove_if(v.begin(), v.end(), [&](const Red &r) { return r.ssid == ssid; }), v.end());
  v.insert(v.begin(), {ssid, pass});
  if ((int)v.size() > MAX_REDES) v.resize(MAX_REDES);
  saveNetworks(v);
}

void removeNetwork(const String &ssid) {
  auto v = loadNetworks();
  v.erase(std::remove_if(v.begin(), v.end(), [&](const Red &r) { return r.ssid == ssid; }), v.end());
  saveNetworks(v);
}

// Envío al servidor. Cada cámara se identifica con su ID de fábrica
// (TX-XXXXXX, de la MAC) y el token que el servidor le da al registrarse.
// Sin internet, las fotos se guardan en /q y se suben después, las más viejas
// primero.
const char *FW_VERSION = "4.1";
char devId[12];
String srvUrl, devToken;
char srvState[64] = "sin servidor configurado";
uint32_t ajustesVer = 0;  // versión de los ajustes del panel que ya se aplicaron
String cfgJson();
void applySettings(const char *q);
volatile uint32_t srvInterval = 5000, sentOk = 0, sentErr = 0, lastSentMs = 0;
// Cola numerada: las fotos [qHead, qTail) esperan envío. Cada una va en
// /q/<seq/4096>/<seq%4096>.JPG (nombres cortos 8.3 y carpetas de 4096 para
// que FAT32 no se llene ni se vuelva lenta con miles de fotos). Así la más
// vieja se encuentra sin recorrer la carpeta.
volatile uint32_t qHead = 0, qTail = 0;
uint32_t queueSize() { return qTail - qHead; }
uint32_t queueMinFreeKB() { return sdOk ? 200 * 1024 : 600; }  // deja espacio a las fotos de entrenamiento
void setServer(String url);

// Actualización por internet: el servidor guarda el firmware más nuevo y la
// cámara lo instala sola. Mientras se descarga, el bucle principal se pausa.
volatile bool otaRequested = false, camStopped = false, otaHint = false;
const uint32_t OTA_CHECK_MS = 3600000;  // cada hora (y 1 min después de arrancar)
bool apMode = false;
String bootReason, bootHistory;

// Prueba "sin WiFi" (comando SINWIFI): la cámara arranca como si no viera
// ninguna de sus redes, para probar en la mesa lo que hace en el taxi. Dura
// hasta CONWIFI, y como mucho 3 arranques (por si se olvida terminarla).
bool sinWifi = false;

// Fallos al escribir en la tarjeta (corte breve de corriente, mal contacto):
// antes se perdían en silencio. Ahora se cuentan, se monta de nuevo la SD y,
// si no vuelve, se sigue en la memoria interna.
volatile uint32_t storeErrors = 0;
void storeFailed(const char *what);

String rstName(int r) {
  switch (r) {
    case ESP_RST_POWERON: return "encendido";
    case ESP_RST_SW: return "software";
    case ESP_RST_PANIC: return "FALLO";
    case ESP_RST_INT_WDT: case ESP_RST_TASK_WDT: case ESP_RST_WDT: return "colgado";
    case ESP_RST_BROWNOUT: return "FALTA DE CORRIENTE";
    default: return "otro(" + String(r) + ")";
  }
}

struct Trip { time_t start; uint32_t durS; int maxPax; };
Trip trips[30];
int tripCount = 0, discarded = 0;

// ---- Utilidades -------------------------------------------------------------
const char *resetReason() {
  switch (esp_reset_reason()) {
    case ESP_RST_POWERON: return "encendido normal";
    case ESP_RST_SW: return "reinicio por software";
    case ESP_RST_PANIC: return "FALLO del programa";
    case ESP_RST_INT_WDT:
    case ESP_RST_TASK_WDT:
    case ESP_RST_WDT: return "programa colgado (watchdog)";
    case ESP_RST_BROWNOUT: return "CAIDA DE VOLTAJE: falta corriente";
    default: return "otro";
  }
}

time_t nowEpoch() {
  time_t t = time(nullptr);
  return t > 1700000000 ? t : 0;  // 0 = aún sin hora de internet
}

String fmtTime(time_t t) {
  if (!t) return "--:--";
  struct tm tm;
  localtime_r(&t, &tm);
  char b[24];
  strftime(b, sizeof b, "%d/%m %H:%M:%S", &tm);
  return b;
}

bool initCamera() {
  camera_config_t c = {};
  c.ledc_channel = LEDC_CHANNEL_0;
  c.ledc_timer = LEDC_TIMER_0;
  c.pin_d0 = Y2_GPIO_NUM; c.pin_d1 = Y3_GPIO_NUM; c.pin_d2 = Y4_GPIO_NUM;
  c.pin_d3 = Y5_GPIO_NUM; c.pin_d4 = Y6_GPIO_NUM; c.pin_d5 = Y7_GPIO_NUM;
  c.pin_d6 = Y8_GPIO_NUM; c.pin_d7 = Y9_GPIO_NUM;
  c.pin_xclk = XCLK_GPIO_NUM; c.pin_pclk = PCLK_GPIO_NUM;
  c.pin_vsync = VSYNC_GPIO_NUM; c.pin_href = HREF_GPIO_NUM;
  c.pin_sccb_sda = SIOD_GPIO_NUM; c.pin_sccb_scl = SIOC_GPIO_NUM;
  c.pin_pwdn = -1; c.pin_reset = -1;
  c.xclk_freq_hz = 20000000;
  c.pixel_format = PIXFORMAT_RGB565;
  // Cambiar el tamaño en marcha desborda la pila de cam_task con el OV3660:
  // se fija aquí, al arrancar.
  c.frame_size = (framesize_t)frameSz;
  c.fb_location = CAMERA_FB_IN_PSRAM;
  c.fb_count = 2;
  c.grab_mode = CAMERA_GRAB_LATEST;
  if (esp_camera_init(&c) != ESP_OK) return false;
  sensor_t *s = esp_camera_sensor_get();
  if (s->id.PID == OV3660_PID) {
    s->set_vflip(s, 1);
    s->set_brightness(s, 1);
    s->set_saturation(s, -1);
  }
  return true;
}

// ---- Lógica de carrera ------------------------------------------------------
void updateTrip(int n, uint32_t now) {
  // Las caras parpadean: se usa el máximo de los últimos 5 fotogramas.
  for (int i = 4; i > 0; i--) recentMax[i] = recentMax[i - 1];
  recentMax[0] = n;
  int stable = 0;
  for (int v : recentMax) stable = max(stable, v);
  paxNow = stable;

  switch (state) {
    case LIBRE:
      if (stable > 0) { state = CONFIRMANDO; candStart = now; }
      break;
    case CONFIRMANDO:
      if (stable == 0) state = LIBRE;
      else if (now - candStart >= ENTER_CONFIRM_MS) {
        state = EN_CARRERA; tripStart = candStart; zeroSince = 0; maxPax = stable;
      }
      break;
    case EN_CARRERA:
      if (stable > 0) { zeroSince = 0; maxPax = max(maxPax, stable); break; }
      if (!zeroSince) zeroSince = now;
      if (now - zeroSince > EXIT_GRACE_MS) {
        uint32_t dur = zeroSince - tripStart;
        if (dur >= MIN_TRIP_MS) {
          Trip t{nowEpoch() ? nowEpoch() - (now - tripStart) / 1000 : 0, dur / 1000, maxPax};
          if (tripCount == 30) { memmove(trips, trips + 1, sizeof(Trip) * 29); tripCount--; }
          trips[tripCount++] = t;
          Serial.printf("# Carrera guardada: %u s, max %d\n", dur / 1000, maxPax);
        } else {
          discarded++;
          Serial.printf("# Carrera descartada (%u s)\n", dur / 1000);
        }
        state = LIBRE;
      }
      break;
  }
}

// ---- Página web ---------------------------------------------------------------
static const char PAGE[] PROGMEM = R"HTML(<!doctype html><html lang="es"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>Taxiff Cam</title><style>
:root{--bg:#f2f2f4;--card:#fff;--c2:#f0f0f3;--fg:#111114;--m:#6f6f76;--acc:#0a6cff;--ok:#1f9d55;--okbg:#dff3e6;--warn:#e08600;--warnbg:#fdefd8;--bad:#e5352b;--lin:#e4e4e8}
@media(prefers-color-scheme:dark){:root{--bg:#000;--card:#1a1a1c;--c2:#252528;--fg:#f4f4f6;--m:#9b9ba3;--acc:#3e91ff;--ok:#3ddc84;--okbg:#173a26;--warn:#ffb03a;--warnbg:#3d2c12;--bad:#ff5a50;--lin:#2c2c30}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.45 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
header{max-width:1200px;margin:0 auto;padding:16px 16px 8px;display:flex;gap:10px;align-items:center;flex-wrap:wrap}
h1{font-size:20px;margin:0}
.pill{padding:4px 11px;border-radius:99px;font-weight:700;font-size:12px;letter-spacing:.02em;background:var(--c2);color:var(--m)}
.pill.verde{background:var(--okbg);color:var(--ok)}.pill.amarillo{background:var(--warnbg);color:var(--warn)}
main{max-width:1200px;margin:0 auto;padding:4px 16px 28px;display:grid;grid-template-columns:minmax(0,1.7fr) minmax(300px,1fr);gap:14px;align-items:start}
@media(max-width:860px){main{grid-template-columns:1fr}}
.col{display:grid;gap:14px;min-width:0}
.card{background:var(--card);border-radius:22px;padding:14px 16px;min-width:0}
canvas{width:100%;height:auto;border-radius:16px;background:#000;display:block}
.k{display:grid;grid-template-columns:repeat(4,1fr);gap:8px}
.k div{background:var(--c2);border-radius:14px;padding:10px 12px}.k b{display:block;font-size:24px;line-height:1.2}.k span{color:var(--m);font-size:12px}
@media(max-width:520px){.k{grid-template-columns:1fr 1fr}}
#timer{font-size:42px;font-weight:300;line-height:1.1}
details{background:var(--card);border-radius:22px;padding:2px 16px}
summary{cursor:pointer;font-weight:700;padding:13px 0;list-style:none;display:flex;justify-content:space-between;align-items:center}
summary::-webkit-details-marker{display:none}summary::after{content:"+";color:var(--m);font-size:20px;font-weight:400}
details[open] summary::after{content:"\2013"}details>div{padding-bottom:14px}
.ajustes{display:grid;grid-template-columns:1fr 1fr;gap:10px}
@media(max-width:520px){.ajustes{grid-template-columns:1fr}}
label{display:block;font-size:13px;color:var(--m)}
select,input{width:100%;margin-top:4px;padding:11px 12px;border-radius:12px;border:1px solid var(--lin);background:var(--c2);color:var(--fg);font-size:15px;outline:none}
select:focus,input:focus{border-color:var(--acc)}
button{border:0;border-radius:99px;padding:11px 18px;font-weight:700;font-size:15px;background:var(--acc);color:#fff;cursor:pointer}
button.sec{background:var(--c2);color:var(--fg)}
.fila{display:flex;gap:8px;flex-wrap:wrap;margin:10px 0}.fila button{flex:1}
.m{color:var(--m);font-size:13px}
table{width:100%;border-collapse:collapse;font-size:14px}td{padding:8px 4px;border-top:1px solid var(--lin)}tr:first-child td{border-top:0}
.barra{height:8px;background:var(--c2);border-radius:4px;margin:4px 0 12px;overflow:hidden}.barra i{display:block;height:100%;border-radius:4px}
</style></head><body>
<header><h1>Taxiff Cam</h1><span id="st" class="pill">…</span><span class="m" id="net"></span></header>
<main><div class="col">
<section class="card"><canvas id="v" width="640" height="480"></canvas>
<p class="m" style="margin:10px 2px 0">Detección, conteo y carreras se calculan en la cámara. Modelo: <b id="mname">–</b></p></section>
<div class="card k"><div><b id="n" style="color:var(--ok)">0</b><span>personas</span></div>
<div><b id="ms">–</b><span>ms detección</span></div><div><b id="fps">–</b><span>fotos por seg.</span></div>
<div><b id="tc">0</b><span>carreras</span></div></div>
</div>
<aside class="col">
<div class="card"><div class="m">Carrera</div><div id="timer">00:00</div><div class="m" id="tdet"></div></div>
<details><summary>Servidor Taxiff</summary><div>
<div class="m">Esta cámara: <b id="devid">–</b></div>
<input id="srv" placeholder="Dirección del servidor (https…)" autocapitalize="none" style="margin:10px 0 8px">
<button id="srvsave">Guardar servidor</button>
<div id="srvinfo" class="m" style="margin-top:10px"></div></div></details>
<details><summary>Ajustes de cámara y detección</summary><div class="ajustes">
<label>Resolución (reinicia)<select id="fs"><option value="qvga">320x240 (rápido)</option><option value="vga">640x480 (más alcance)</option></select></label>
<label>Alcance del detector<select id="scale"><option value="0.2">Corto (rápido)</option><option value="0.3">Medio</option><option value="0.4">Largo</option><option value="0.5">Muy largo (lento)</option></select></label>
<label>Calidad imagen<select id="q"><option value="40">Baja</option><option value="60">Media</option><option value="80">Alta</option></select></label>
<label>Qué detecta<select id="model"><option value="personas">Cabezas (modelo propio)</option><option value="caras">Caras (Espressif)</option></select></label>
<label>Unir detecciones cercanas<select id="mrg"><option value="0.0">No unir</option><option value="1.5">Poco</option><option value="2.5">Normal</option><option value="4.0">Mucho</option></select></label>
<label>Sensibilidad cabezas<select id="pthr"><option value="0.30">Alta (cuenta más)</option><option value="0.40">Media-alta</option><option value="0.50">Normal</option><option value="0.65">Baja (menos errores)</option></select></label>
<label>Detección en la cámara<select id="det"><option value="1">Sí</option><option value="0">No (solo cámara)</option></select></label>
<label>Orientación<select id="rot"><option value="0">Normal</option><option value="1">Girada 180°</option></select></label>
<label>Modo noche<select id="night"><option value="0">No</option><option value="1">Sí</option></select></label>
</div></details>
<details><summary>Temperatura y carga</summary><div id="met" class="m"></div></details>
<details><summary>Carreras guardadas</summary><div><table id="tr"></table></div></details>
<details><summary>Fotos para entrenar el modelo</summary><div>
<label>Guardar automáticamente<select id="cap"><option value="0">No</option><option value="2">Cada 2 s</option><option value="5">Cada 5 s</option><option value="10">Cada 10 s</option></select></label>
<div class="fila"><button id="capnow">Guardar foto ahora</button><button id="capdel" class="sec">Borrar todas</button></div>
<div id="capinfo" class="m"></div></div></details>
<details><summary>Sistema</summary><div class="m" id="sys"></div></details>
</aside></main>
<script>
const v=document.getElementById('v'),c=v.getContext('2d');const $=i=>document.getElementById(i);
const two=x=>String(x).padStart(2,'0');const dur=s=>two(Math.floor(s/60))+':'+two(s%60);
async function frame(){try{const r=await fetch('/frame?'+Date.now());const d=JSON.parse(r.headers.get('X-Det')||'{}');
const img=await createImageBitmap(await r.blob());v.width=img.width*2;v.height=img.height*2;c.drawImage(img,0,0,v.width,v.height);
c.lineWidth=4;c.font='bold 22px system-ui';const k=v.width/img.width,fomo=$('model').value=='personas';
for(const[x1,y1,x2,y2,s]of d.b||[]){c.strokeStyle=c.fillStyle='#30c26b';const t='pasajero '+Math.round(s*100)+'%';let lx=x1*k,ly=y1*k;
if(fomo){const cx=(x1+x2)/2*k,cy=(y1+y2)/2*k;c.beginPath();c.arc(cx,cy,14,0,7);c.fill();c.beginPath();c.arc(cx,cy,26,0,7);c.stroke();lx=cx-26;ly=cy-30;}
else c.strokeRect(x1*k,y1*k,(x2-x1)*k,(y2-y1)*k);
const w=c.measureText(t).width+12;c.fillRect(lx,Math.max(0,ly-28),w,26);c.fillStyle='#000';c.fillText(t,lx+6,Math.max(20,ly-8));}
$('n').textContent=d.pax;$('ms').textContent=d.ms;$('fps').textContent=d.fps;
const st=['LIBRE','CONFIRMANDO','EN CARRERA'][d.state];$('st').textContent=st;$('st').className='pill'+(d.state==2?' verde':d.state==1?' amarillo':'');
$('timer').textContent=dur(d.trip_s||0);$('tdet').textContent=d.state==2?(d.zero_s?('Sin pasajeros · cierra en '+Math.max(0,20-d.zero_s)+' s'):('máx. '+d.max+' pasajero(s)')):'Esperando pasajeros';
}catch(e){}setTimeout(frame,120)}
async function info(){try{const d=await (await fetch('/status')).json();$('tc').textContent=d.trips.length;
$('tr').innerHTML=d.trips.length?d.trips.slice().reverse().map(t=>`<tr><td>${t.inicio}</td><td>${dur(t.dur)}</td><td>${t.max} pax</td></tr>`).join(''):'<tr><td class="m">Aún no hay carreras</td></tr>';
$('net').textContent=d.net;$('sys').innerHTML=`Arranque: <b>${d.boot}</b><br>Reinicios: ${d.hist}<br>Encendido: ${dur(d.up)} · RAM libre ${d.heap} KB · PSRAM libre ${d.psram} KB<br>WiFi: ${d.rssi} dBm · descartadas: ${d.discarded}`;
const tc=d.temp>=80?'var(--bad)':d.temp>=65?'var(--warn)':'var(--ok)';
const bar=(v,c)=>`<div class="barra"><i style="width:${Math.min(100,v)}%;background:${c}"></i></div>`;
$('devid').textContent=d.id;if(document.activeElement!==$('srv'))$('srv').value=d.srv;
$('srvinfo').textContent=d.srv?`${d.srv_estado} · ${d.enviadas} fotos enviadas${d.ult_envio_s>=0?' (última hace '+d.ult_envio_s+' s)':''} · ${d.en_cola} en cola sin internet · ritmo ${d.intervalo_ms/1000} s`:'No envía a ningún servidor.';
$('mname').textContent=d.cfg.model=='caras'?'caras (Espressif)':d.modelo;
const mb=d.fotos_libre_kb/1024,libre=mb>=1024?(mb/1024).toFixed(1)+' GB':mb.toFixed(1)+' MB';
$('capinfo').textContent=(d.almacen=='sd'?`Tarjeta SD de ${d.sd_gb} GB`:d.almacen=='interna'?'Sin tarjeta SD: memoria interna':'Sin memoria')+` · ${d.fotos} fotos guardadas · libre ${libre} (≈ ${Math.floor(d.fotos_libre_kb/12).toLocaleString()} fotos más)`;
$('met').innerHTML=(d.cam_ok?'':'<b style="color:var(--bad)">LA CÁMARA NO ENVÍA IMAGEN: reiniciándola…</b><br>')+(d.cam_reinits?`Reinicios de cámara: ${d.cam_reinits}<br>`:'')+`Temperatura del chip: <b style="color:${tc};font-size:20px">${d.temp} °C</b> (máx. ${d.tmax} °C)${d.hot?' · <b style="color:var(--bad)">MUY CALIENTE: va más lento para enfriarse</b>':''}${bar(d.temp,tc)}`+
`CPU ocupada: <b>${d.busy}%</b>${bar(d.busy,d.busy>85?'var(--warn)':'var(--ok)')}`+
`Por foto: cámara ${d.cam_ms} ms · detección ${d.det_ms} ms · JPEG ${d.jpg_ms} ms<br>Enviando al servidor: ${d.kbs} KB/s (≈ ${Math.round(d.kbs*3.6)} MB/hora) · ${d.fps} fps`;}catch(e){}setTimeout(info,2000)}
const KS=['fs','scale','q','night','det','model','pthr','mrg','rot','cap'];
$('srvsave').onclick=()=>fetch('/set?srv='+encodeURIComponent($('srv').value.trim())).then(()=>setTimeout(info,500));
$('capnow').onclick=()=>fetch('/set?capnow=1').then(()=>setTimeout(info,600));
$('capdel').onclick=()=>{if(confirm('¿Borrar todas las fotos guardadas en el ESP32?'))fetch('/foto?borrar=todas').then(()=>setTimeout(info,300));};
for(const k of KS)$(k).onchange=()=>fetch('/set?'+k+'='+$(k).value);
fetch('/status').then(r=>r.json()).then(d=>{for(const k of KS)$(k).value=k=='pthr'?d.cfg[k].toFixed(2):k=='mrg'?d.cfg[k].toFixed(1):String(d.cfg[k]);});
frame();info();
</script></body></html>)HTML";

// Página para elegir la WiFi desde el teléfono (lo único que puede hacer el
// dueño). Se abre sola al conectarse a la red "Taxiff-Cam" (portal cautivo).
// Ojo: sin "//" en este texto (el preprocesador de Arduino lo corta).
static const char SETUP_PAGE[] PROGMEM = R"HTML(<!doctype html><html lang="es"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"><title>Taxiff · WiFi</title>
<style>
:root{--bg:#f2f2f4;--card:#fff;--c2:#f0f0f3;--fg:#111114;--m:#6f6f76;--acc:#0a6cff;--ok:#1f9d55;--okbg:#dff3e6;--bad:#e5352b;--badbg:#fde4e2;--lin:#e4e4e8}
@media(prefers-color-scheme:dark){:root{--bg:#000;--card:#1a1a1c;--c2:#252528;--fg:#f4f4f6;--m:#9b9ba3;--acc:#3e91ff;--ok:#3ddc84;--okbg:#173a26;--bad:#ff5a50;--badbg:#3d1714;--lin:#2c2c30}}
*{box-sizing:border-box}
body{margin:0;font:16px system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;background:var(--bg);color:var(--fg);-webkit-tap-highlight-color:transparent}
main{max-width:460px;margin:0 auto;padding:22px 16px 40px}
.marca{display:flex;align-items:center;gap:12px;margin:6px 4px 18px}
.logo{width:44px;height:44px;border-radius:14px;background:var(--acc);display:grid;place-items:center;color:#fff;flex:none}
h1{font-size:22px;margin:0}.m{color:var(--m);font-size:14px}
.card{background:var(--card);border-radius:24px;padding:6px 16px;margin:12px 0}
.tit{display:flex;justify-content:space-between;align-items:center;padding:12px 0 6px;font-weight:700}
.tit button{all:unset;color:var(--acc);font-size:14px;font-weight:600;cursor:pointer;padding:4px 2px}
.red{display:flex;align-items:center;gap:12px;padding:13px 0;border-top:1px solid var(--lin);cursor:pointer}
.red:first-of-type{border-top:0}
.red .nom{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.chip{font-size:12px;font-weight:600;padding:3px 9px;border-radius:99px;background:var(--c2);color:var(--m)}
.chip.ok{background:var(--okbg);color:var(--ok)}
.sk{height:20px;border-radius:8px;margin:16px 0;background:linear-gradient(100deg,var(--c2) 30%,var(--lin) 50%,var(--c2) 70%);background-size:300% 100%;animation:br 1.3s linear infinite}
@keyframes br{from{background-position:100% 0}to{background-position:0 0}}
.aviso{border-radius:18px;padding:12px 14px;margin:12px 0;font-size:15px;display:none}
.aviso.ok{display:block;background:var(--okbg);color:var(--ok)}.aviso.mal{display:block;background:var(--badbg);color:var(--bad)}
.hoja{position:fixed;inset:0;background:rgba(0,0,0,.45);display:none;align-items:flex-end;justify-content:center;z-index:5}
.hoja.ver{display:flex}
.panel{background:var(--card);width:100%;max-width:460px;border-radius:28px 28px 0 0;padding:20px 18px calc(22px + env(safe-area-inset-bottom));animation:sube .22s ease-out}
@keyframes sube{from{transform:translateY(40px);opacity:.4}}
label{display:block;font-size:14px;color:var(--m);margin:12px 4px 6px}
.campo{position:relative}
input{width:100%;padding:15px 16px;border-radius:16px;border:1.5px solid var(--lin);background:var(--c2);color:var(--fg);font-size:17px;outline:none}
input:focus{border-color:var(--acc)}
.ojo{all:unset;cursor:pointer;color:var(--m);font-size:14px;font-weight:600;padding:8px}
.campo .ojo{position:absolute;right:10px;top:9px}
.btn{display:block;width:100%;border:0;border-radius:999px;padding:16px;margin-top:16px;font-size:17px;font-weight:700;background:var(--acc);color:#fff;cursor:pointer}
.btn.sec{background:var(--c2);color:var(--fg)}
.btn:disabled{opacity:.6}
.quitar{all:unset;color:var(--bad);font-size:14px;font-weight:600;cursor:pointer;padding:6px 2px}
.listo{text-align:center;padding:40px 10px}
.check{width:84px;height:84px;border-radius:50%;background:var(--okbg);color:var(--ok);display:grid;place-items:center;margin:0 auto 18px;animation:pop .35s ease-out}
@keyframes pop{from{transform:scale(.6);opacity:0}}
.giro{width:20px;height:20px;border-radius:50%;border:3px solid rgba(255,255,255,.4);border-top-color:#fff;display:inline-block;vertical-align:-4px;margin-right:8px;animation:g .8s linear infinite}
@keyframes g{to{transform:rotate(360deg)}}
.tips{font-size:13px;color:var(--m);padding:4px 6px;line-height:1.5}
@media(prefers-reduced-motion:reduce){*{animation:none!important}}
</style></head><body><main id="app">
<div class="marca"><div class="logo"><svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M2 8.5a15 15 0 0 1 20 0"/><path d="M5 12a10 10 0 0 1 14 0"/><path d="M8.5 15.5a5 5 0 0 1 7 0"/><circle cx="12" cy="19" r="1.2" fill="currentColor"/></svg></div>
<div><h1>Conectar la cámara</h1><div class="m">Taxiff · elige la WiFi para subir las fotos</div></div></div>
<div id="aviso" class="aviso"></div>
<div class="card"><div class="tit">Redes disponibles<button id="otra">Actualizar</button></div><div id="vis"><div class="sk"></div><div class="sk"></div><div class="sk"></div></div></div>
<div class="card"><div class="tit">Redes guardadas</div><div id="gua"><div class="sk"></div></div></div>
<p class="tips">La cámara recuerda varias redes y se conecta sola a la que encuentre. Solo funciona con redes de <b>2,4 GHz</b>: si usas el hotspot del celular, actívalo en 2,4 GHz (o "máxima compatibilidad").<br><a href="#" id="manual" style="color:var(--acc)">Mi red no aparece</a></p>
</main>
<div class="hoja" id="hoja"><form class="panel" id="form">
<div class="m">Conectar a</div><h1 id="hNom" style="margin:2px 0 6px;overflow-wrap:anywhere"></h1>
<div id="hSsid" style="display:none"><label for="s">Nombre de la red</label><input id="s" autocomplete="off" autocapitalize="none"></div>
<label for="p">Contraseña</label><div class="campo"><input id="p" type="password" autocomplete="current-password"><button type="button" class="ojo" id="ojo">Mostrar</button></div>
<button class="btn" id="ok">Conectar</button><button type="button" class="btn sec" id="cancelar">Cancelar</button>
</form></div>
<script>
const $=i=>document.getElementById(i);
const esc=t=>String(t).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const senal=r=>{const n=r>-55?4:r>-67?3:r>-75?2:1;return '<svg width="22" height="18" viewBox="0 0 22 18">'+[0,1,2,3].map(i=>'<rect x="'+(i*5+1)+'" y="'+(14-i*4)+'" width="3.4" height="'+(4+i*4)+'" rx="1.2" fill="'+(i<n?'var(--acc)':'var(--lin)')+'"/>').join('')+'</svg>'};
let red='';
const abrir=(n,manual)=>{red=n;$('hNom').textContent=manual?'otra red':n;$('hSsid').style.display=manual?'block':'none';$('p').value='';$('hoja').classList.add('ver');setTimeout(()=>(manual?$('s'):$('p')).focus(),250)};
const cerrar=()=>$('hoja').classList.remove('ver');
let reintento;
const cargar=nuevo=>{clearTimeout(reintento);if(nuevo)$('vis').innerHTML='<div class="sk"></div><div class="sk"></div><div class="sk"></div><p class="m">Buscando… si el teléfono se desconecta un momento, vuelve a conectarte a Taxiff-Cam.</p>';
fetch('/redes'+(nuevo?'?nuevo=1':'')).then(r=>r.json()).then(d=>{
if(d.buscando)reintento=setTimeout(()=>cargar(false),1500);
if(d.buscando&&!d.visibles.length)return;
const a=$('aviso');a.className='aviso';
if(d.conectada){a.className='aviso ok';a.textContent='Conectada a '+d.conectada+'. Todo listo.'}
else if(d.ultimo_mal){a.className='aviso mal';a.textContent='No se pudo conectar a '+d.ultimo_mal+'. Revisa la contraseña y vuelve a intentarlo.'}
$('vis').innerHTML=d.visibles.length?d.visibles.map((n,i)=>'<div class="red" data-i="'+i+'">'+senal(n.rssi)+'<span class="nom">'+esc(n.ssid)+'</span>'+(n.ssid===d.conectada?'<span class="chip ok">Conectada</span>':d.guardadas.includes(n.ssid)?'<span class="chip">Guardada</span>':'')+'</div>').join(''):'<p class="m">No encontró redes de 2,4 GHz. Acerca la cámara al router.</p>';
$('vis').querySelectorAll('.red').forEach(el=>el.onclick=()=>abrir(d.visibles[el.dataset.i].ssid));
$('gua').innerHTML=d.guardadas.length?d.guardadas.map((g,i)=>'<div class="red" style="cursor:default"><span class="nom">'+esc(g)+'</span><button class="quitar" data-i="'+i+'">Quitar</button></div>').join(''):'<p class="m">Ninguna todavía.</p>';
$('gua').querySelectorAll('.quitar').forEach(b=>b.onclick=()=>{const g=d.guardadas[b.dataset.i];if(confirm('¿Olvidar la red '+g+'?'))fetch('/wifi_borrar',{method:'POST',body:'s='+encodeURIComponent(g)}).then(cargar)});
}).catch(()=>{reintento=setTimeout(()=>cargar(false),2500)})};
$('otra').onclick=()=>cargar(true);$('cancelar').onclick=cerrar;
$('manual').onclick=e=>{e.preventDefault();abrir('',true)};
$('ojo').onclick=()=>{const p=$('p');p.type=p.type==='password'?'text':'password';$('ojo').textContent=p.type==='password'?'Mostrar':'Ocultar'};
$('form').onsubmit=e=>{e.preventDefault();const n=red||$('s').value.trim();if(!n)return;
$('ok').disabled=true;$('ok').innerHTML='<span class="giro"></span>Guardando…';
const fin=()=>{cerrar();$('app').innerHTML='<div class="listo"><div class="check"><svg width="42" height="42" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12.5l4.5 4.5L19 7.5"/></svg></div><h1>Guardado</h1><p>La cámara se reinicia y se conecta a <b>'+esc(n)+'</b>.</p><p class="m">Ya puedes volver a tu WiFi de siempre.<br>Si la contraseña estaba mal, la red <b>Taxiff-Cam</b> vuelve a aparecer en un minuto para corregirla.</p></div>'};
fetch('/save',{method:'POST',body:'s='+encodeURIComponent(n)+'&p='+encodeURIComponent($('p').value)}).then(fin,fin)};
cargar(false);
</script></body></html>)HTML";

// ---- Quién puede entrar --------------------------------------------------------
// La página de la cámara (en vivo, ajustes, fotos) es solo para la empresa:
// usuario "admin" y CLAVE_ADMIN. El dueño del taxi solo puede elegir la WiFi, y
// solo estando conectado a la red Taxiff-Cam de la cámara (desde la WiFi de su
// casa no puede tocar nada).
String authEsperada;  // "Basic <base64 de admin:clave>"

void initAuth() {
  String plano = String("admin:") + CLAVE_ADMIN;
  unsigned char out[160];
  size_t n = 0;
  mbedtls_base64_encode(out, sizeof out - 1, &n, (const unsigned char *)plano.c_str(), plano.length());
  out[n] = 0;
  authEsperada = String("Basic ") + (const char *)out;
}

bool esAdmin(httpd_req_t *req) {
  char h[200];
  if (httpd_req_get_hdr_value_str(req, "Authorization", h, sizeof h) != ESP_OK) return false;
  return authEsperada.length() > 6 && authEsperada.equals(h);
}

// ¿El pedido viene de un teléfono conectado a la red Taxiff-Cam?
bool desdeRedPropia(httpd_req_t *req) {
  if (!apMode) return false;
  struct sockaddr_storage a;
  socklen_t l = sizeof a;
  if (getpeername(httpd_req_to_sockfd(req), (struct sockaddr *)&a, &l) != 0) return false;
  uint32_t ip = 0;
  if (a.ss_family == AF_INET) ip = ((struct sockaddr_in *)&a)->sin_addr.s_addr;
  else if (a.ss_family == AF_INET6) memcpy(&ip, &((struct sockaddr_in6 *)&a)->sin6_addr.un.u32_addr[3], 4);
  uint32_t ap = (uint32_t)WiFi.softAPIP();
  return (ip & 0x00FFFFFF) == (ap & 0x00FFFFFF);  // misma red 192.168.4.x
}

// Sin permiso: al teléfono del dueño se le muestra la página de WiFi; al resto se le pide la clave.
esp_err_t sinAcceso(httpd_req_t *req) {
  if (desdeRedPropia(req)) {
    httpd_resp_set_status(req, "302 Found");
    httpd_resp_set_hdr(req, "Location", "/wifi");
    return httpd_resp_send(req, nullptr, 0);
  }
  httpd_resp_set_status(req, "401 Unauthorized");
  httpd_resp_set_hdr(req, "WWW-Authenticate", "Basic realm=\"Taxiff\", charset=\"UTF-8\"");
  httpd_resp_set_type(req, "text/plain; charset=utf-8");
  return httpd_resp_sendstr(req, "Acceso solo para administradores de Taxiff.");
}
#define SOLO_ADMIN() if (!esAdmin(req)) return sinAcceso(req)
#define SOLO_CONFIGURACION() if (!esAdmin(req) && !desdeRedPropia(req)) return sinAcceso(req)

esp_err_t handlePage(httpd_req_t *req) {
  SOLO_ADMIN();
  httpd_resp_set_type(req, "text/html");
  return httpd_resp_send(req, PAGE, HTTPD_RESP_USE_STRLEN);
}

esp_err_t handleSetup(httpd_req_t *req) {
  SOLO_CONFIGURACION();
  httpd_resp_set_type(req, "text/html");
  return httpd_resp_send(req, SETUP_PAGE, HTTPD_RESP_USE_STRLEN);
}

String urlDecode(const String &s) {
  String o;
  for (size_t i = 0; i < s.length(); i++) {
    char ch = s[i];
    if (ch == '+') o += ' ';
    else if (ch == '%' && i + 2 < s.length()) {
      o += (char)strtol(s.substring(i + 1, i + 3).c_str(), nullptr, 16);
      i += 2;
    } else o += ch;
  }
  return o;
}

// Campo `key` de un formulario (application/x-www-form-urlencoded).
String formField(const String &body, const char *key) {
  String k = String(key) + "=";
  int i = body.startsWith(k) ? 0 : body.indexOf("&" + k);
  if (i < 0) return "";
  if (i > 0) i++;
  int fin = body.indexOf('&', i);
  return urlDecode(body.substring(i + k.length(), fin < 0 ? body.length() : fin));
}

String readForm(httpd_req_t *req) {
  char buf[400] = {0};
  int len = httpd_req_recv(req, buf, min((size_t)req->content_len, sizeof(buf) - 1));
  return len > 0 ? String(buf) : String();
}

// Guarda una red nueva (se suma a las que ya conoce) y reinicia para conectarse.
esp_err_t handleSave(httpd_req_t *req) {
  SOLO_CONFIGURACION();
  String body = readForm(req), ssid = formField(body, "s"), pass = formField(body, "p");
  if (!ssid.length()) return httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Falta el nombre de la red");
  addNetwork(ssid, pass);
  logEvent("red WiFi agregada desde el teléfono: %s", ssid.c_str());
  httpd_resp_set_type(req, "text/plain; charset=utf-8");
  httpd_resp_sendstr(req, "ok");  // la página muestra "Guardado"
  delay(1500);
  ESP.restart();
  return ESP_OK;
}

esp_err_t handleWifiBorrar(httpd_req_t *req) {
  SOLO_CONFIGURACION();
  String ssid = formField(readForm(req), "s");
  removeNetwork(ssid);
  logEvent("red WiFi quitada: %s", ssid.c_str());
  httpd_resp_set_type(req, "text/plain; charset=utf-8");
  return httpd_resp_sendstr(req, "ok");
}

String jsonEsc(const String &s) {
  String o;
  for (char c : s) { if (c == '"' || c == '\\') o += '\\'; if ((uint8_t)c >= 0x20) o += c; }
  return o;
}

// Búsqueda de redes en segundo plano. Buscar recorre todos los canales y,
// mientras tanto, la red Taxiff-Cam no atiende: si /redes esperaba la búsqueda,
// el teléfono del dueño perdía la conexión. Ahora /redes responde al instante
// con lo último encontrado y la página vuelve a preguntar hasta que termina.
String redesVisibles = "";        // JSON de la última búsqueda: [{"ssid":..,"rssi":..},…]
volatile bool buscandoRedes = false;
uint32_t redesCuando = 0;
SemaphoreHandle_t redesLock = nullptr;  // la escribe el bucle principal y la lee el servidor web

void buscarRedes() {
  if (buscandoRedes) return;
  if (WiFi.scanNetworks(true, false, false, 120) == WIFI_SCAN_FAILED) return;  // async, 120 ms por canal
  buscandoRedes = true;
}

// Desde el bucle principal: guarda el resultado cuando la búsqueda termina.
void revisarBusqueda() {
  if (!buscandoRedes) return;
  int n = WiFi.scanComplete();
  if (n == WIFI_SCAN_RUNNING) return;
  buscandoRedes = false;
  if (n <= 0) {  // falló o no vio nada (pasa justo al abrir Taxiff-Cam): se reintenta
    WiFi.scanDelete();
    return;
  }
  std::vector<std::pair<int, String>> vis;
  for (int i = 0; i < n; i++) {
    String s = WiFi.SSID(i);
    if (!s.length()) continue;
    auto it = std::find_if(vis.begin(), vis.end(), [&](const std::pair<int, String> &v) { return v.second == s; });
    if (it == vis.end()) vis.push_back({WiFi.RSSI(i), s});
    else it->first = max(it->first, (int)WiFi.RSSI(i));
  }
  WiFi.scanDelete();
  std::sort(vis.begin(), vis.end(), [](const std::pair<int, String> &a, const std::pair<int, String> &b) { return a.first > b.first; });
  String j = "[";
  for (size_t i = 0; i < vis.size(); i++)
    j += String(i ? "," : "") + "{\"ssid\":\"" + jsonEsc(vis[i].second) + "\",\"rssi\":" + vis[i].first + "}";
  j += "]";
  xSemaphoreTake(redesLock, portMAX_DELAY);
  redesVisibles = j;
  redesCuando = millis();
  xSemaphoreGive(redesLock);
}

// La búsqueda para reconectarse (connectBest) no puede correr junto a una en segundo plano.
void esperarBusqueda() {
  if (!buscandoRedes) return;
  for (int i = 0; i < 60 && WiFi.scanComplete() == WIFI_SCAN_RUNNING; i++) delay(100);
  revisarBusqueda();
  buscandoRedes = false;
}

// /redes: redes que ve la cámara (sin repetir, mejor señal primero) y guardadas.
// ?nuevo=1 pide una búsqueda nueva (botón Actualizar).
esp_err_t handleRedes(httpd_req_t *req) {
  SOLO_CONFIGURACION();
  char q[32] = {0}, v[4];
  bool nuevo = httpd_req_get_url_query_str(req, q, sizeof q) == ESP_OK &&
               httpd_query_key_value(q, "nuevo", v, sizeof v) == ESP_OK;
  // Con un teléfono conectado a Taxiff-Cam solo se busca si lo pide (Actualizar):
  // buscar apaga un momento esa red y el teléfono se desconecta.
  bool hayTelefono = apMode && WiFi.softAPgetStationNum() > 0;
  if (nuevo || !redesCuando || (!hayTelefono && millis() - redesCuando > 20000)) buscarRedes();
  String j = "{\"conectada\":\"" + jsonEsc(WiFi.status() == WL_CONNECTED ? WiFi.SSID() : String()) +
             "\",\"ultimo_mal\":\"" + jsonEsc(prefs.getString("wmal", "")) +
             "\",\"buscando\":" + (buscandoRedes ? "true" : "false") + ",\"guardadas\":[";
  auto redes = loadNetworks();
  for (size_t i = 0; i < redes.size(); i++) j += String(i ? "," : "") + "\"" + jsonEsc(redes[i].ssid) + "\"";
  xSemaphoreTake(redesLock, portMAX_DELAY);
  j += "],\"visibles\":" + (redesVisibles.length() ? redesVisibles : String("[]")) + "}";
  xSemaphoreGive(redesLock);
  httpd_resp_set_type(req, "application/json");
  return httpd_resp_send(req, j.c_str(), j.length());
}

// Portal cautivo: con la red propia abierta, cualquier dirección que pida el
// teléfono (las pruebas de "¿hay internet?") se manda a la página de WiFi,
// y el teléfono la abre solo.
esp_err_t handleNotFound(httpd_req_t *req, httpd_err_code_t err) {
  if (desdeRedPropia(req)) {
    httpd_resp_set_status(req, "302 Found");
    httpd_resp_set_hdr(req, "Location", "http://192.168.4.1/wifi");
    return httpd_resp_send(req, nullptr, 0);
  }
  httpd_resp_send_err(req, HTTPD_404_NOT_FOUND, "No existe");
  return ESP_FAIL;
}

esp_err_t handleFrame(httpd_req_t *req) {
  SOLO_ADMIN();
  xSemaphoreTake(lock, portMAX_DELAY);
  if (!lastJpg) {
    xSemaphoreGive(lock);
    return httpd_resp_send_404(req);
  }
  uint8_t *copy = (uint8_t *)ps_malloc(lastLen);
  size_t len = lastLen;
  memcpy(copy, lastJpg, len);
  String det = lastDet;
  xSemaphoreGive(lock);
  httpd_resp_set_type(req, "image/jpeg");
  httpd_resp_set_hdr(req, "X-Det", det.c_str());
  httpd_resp_set_hdr(req, "Cache-Control", "no-store");
  esp_err_t r = httpd_resp_send(req, (const char *)copy, len);
  free(copy);
  sentBytes += len;
  return r;
}

esp_err_t handleStatus(httpd_req_t *req) {
  SOLO_ADMIN();
  String j = "{\"cfg\":" + cfgJson() + ",\"boot\":\"" + bootReason + "\",\"hist\":\"" + bootHistory + "\",\"up\":" + String(millis() / 1000) +
             ",\"heap\":" + String(ESP.getFreeHeap() / 1024) +
             ",\"psram\":" + String(ESP.getFreePsram() / 1024) +
             ",\"rssi\":" + String(WiFi.RSSI()) + ",\"discarded\":" + String(discarded) +
             ",\"temp\":" + String(temp, 1) + ",\"tmax\":" + String(tempMax, 1) +
             ",\"hot\":" + String(hot ? 1 : 0) + ",\"busy\":" + String((int)busy) +
             ",\"cam_ms\":" + String((int)camAvg) + ",\"det_ms\":" + String((int)detAvg) +
             ",\"jpg_ms\":" + String((int)jpgAvg) + ",\"kbs\":" + String(sendKBs, 1) +
             ",\"modelo\":\"" + String(EI_CLASSIFIER_PROJECT_NAME) + " v" +
             String(EI_CLASSIFIER_PROJECT_DEPLOY_VERSION) + " · " + String(EI_W) + "x" + String(EI_H) + "\"" +
             ",\"fps\":" + String(fps, 1) + ",\"cam_ok\":" + String(camFailSince ? 0 : 1) +
             ",\"cam_reinits\":" + String(camReinits) +
             ",\"fotos\":" + String(capCount) +
             ",\"id\":\"" + devId + "\",\"srv\":\"" + srvUrl + "\",\"srv_estado\":\"" + srvState +
             "\",\"enviadas\":" + String(sentOk) + ",\"errores\":" + String(sentErr) +
             ",\"en_cola\":" + String(queueSize()) +
             ",\"ult_envio_s\":" + String(lastSentMs ? (millis() - lastSentMs) / 1000 : -1) +
             ",\"intervalo_ms\":" + String(srvInterval) +
             ",\"fotos_libre_kb\":" + String(freeKB) +
             ",\"almacen\":\"" + (sdOk ? "sd" : fatOk ? "interna" : "ninguno") + "\"" +
             ",\"errores_memoria\":" + String(storeErrors) + ",\"prueba_sin_wifi\":" + String(sinWifi ? 1 : 0) +
             ",\"sd_gb\":" + String(sdOk ? SD_MMC.cardSize() / 1073741824.0 : 0, 1) +
             ",\"net\":\"" + (WiFi.status() != WL_CONNECTED ? String("Red propia ") + AP_SSID : "WiFi " + WiFi.SSID() + " · " + WiFi.localIP().toString()) +
             "\",\"trips\":[";
  for (int i = 0; i < tripCount; i++) {
    if (i) j += ",";
    j += "{\"inicio\":\"" + fmtTime(trips[i].start) + "\",\"dur\":" + String(trips[i].durS) +
         ",\"max\":" + String(trips[i].maxPax) + "}";
  }
  j += "]}";
  httpd_resp_set_type(req, "application/json");
  return httpd_resp_send(req, j.c_str(), j.length());
}

void loadConfig() {
  detScale = prefs.getFloat("scale", detScale);
  detThr = prefs.getFloat("thr", detThr);
  jpegQ = prefs.getInt("q", jpegQ);
  frameSz = prefs.getInt("fs", frameSz);
  night = prefs.getBool("night", night);
  usePersons = prefs.getBool("persons", usePersons);
  rot180 = prefs.getBool("rot", rot180);
  capCount = prefs.getUInt("capn", 0);
  personThr = prefs.getFloat("pthr", personThr);
  mergeCells = prefs.getFloat("mrg", mergeCells);
  // Si el arranque anterior terminó en fallo, se vuelve a 320x240 para no
  // quedar en un bucle de reinicios.
  if (esp_reset_reason() == ESP_RST_PANIC && frameSz != FRAMESIZE_QVGA) {
    frameSz = FRAMESIZE_QVGA;
    prefs.putInt("fs", frameSz);
    Serial.println("# fallo anterior: se vuelve a 320x240");
  }
  reconfig = true;
}

void applyConfig() {
  delete s1;
  s1 = new HumanFaceDetectMSR01(detThr, 0.5F, 10, detScale);
  sensor_t *s = esp_camera_sensor_get();
  if (s) {
    // El OV3660 de esta placa viene de cabeza (vflip 1 es "derecho").
    s->set_vflip(s, rot180 ? 0 : 1);
    s->set_hmirror(s, rot180 ? 1 : 0);
    s->set_exposure_ctrl(s, 1);
    s->set_gain_ctrl(s, 1);
    // La corrección de lente del OV3660 pinta un círculo rosado en el centro
    // (con luz fuerte o ganancia alta): se deja apagada.
    s->set_lenc(s, 0);
    // Noche: exposición más larga y más ganancia (más ruido, pero ve algo).
    s->set_aec2(s, night ? 1 : 0);
    s->set_ae_level(s, night ? 2 : 0);
    s->set_gainceiling(s, (gainceiling_t)(night ? 6 : 2));
  }
  // Se descartan un par de fotos para que el sensor se estabilice.
  for (int i = 0; i < 2; i++) {
    camera_fb_t *fb = esp_camera_fb_get();
    if (fb) esp_camera_fb_return(fb);
  }
  reconfig = false;
  Serial.printf("# ajustes: %s escala %.2f umbral %.2f jpeg %d noche %d\n",
                frameSz == FRAMESIZE_QVGA ? "320x240" : frameSz == FRAMESIZE_VGA ? "640x480" : "800x600",
                detScale, detThr, jpegQ, night);
}

String cfgJson() {
  return "{\"fs\":\"" + String(frameSz == FRAMESIZE_QVGA ? "qvga" : frameSz == FRAMESIZE_VGA ? "vga" : "svga") +
         "\",\"scale\":" + String(detScale, 2) + ",\"thr\":" + String(detThr, 2) +
         ",\"q\":" + String(jpegQ) + ",\"night\":" + String(night ? 1 : 0) +
         ",\"det\":" + String(detOn ? 1 : 0) + ",\"model\":\"" + (usePersons ? "personas" : "caras") +
         "\",\"pthr\":" + String(personThr, 2) + ",\"mrg\":" + String(mergeCells, 1) + ",\"rot\":" + String(rot180 ? 1 : 0) +
         ",\"cap\":" + String(capEvery) + "}";
}

// Aplica ajustes en formato "clave=valor&clave=valor" (fs, q, pthr, mrg, night,
// rot, model, det, cap, scale, thr). Los usa la página de la cámara (/set) y el
// servidor, que manda los ajustes elegidos en el panel junto con su respuesta.
void applySettings(const char *q) {
  char v[16];
  {
    if (httpd_query_key_value(q, "fs", v, sizeof v) == ESP_OK) {
      // 800x600 en RGB565 cuelga la cámara: el máximo es 640x480.
      int fs = !strcmp(v, "qvga") ? FRAMESIZE_QVGA : FRAMESIZE_VGA;
      if (fs != frameSz) {
        frameSz = fs;
        prefs.putInt("fs", frameSz);
        restartPending = true;
      }
    }
    if (httpd_query_key_value(q, "scale", v, sizeof v) == ESP_OK) {
      detScale = constrain(atof(v), 0.1, 0.8);
      prefs.putFloat("scale", detScale);
    }
    if (httpd_query_key_value(q, "thr", v, sizeof v) == ESP_OK) {
      detThr = constrain(atof(v), 0.05, 0.9);
      prefs.putFloat("thr", detThr);
    }
    if (httpd_query_key_value(q, "q", v, sizeof v) == ESP_OK) {
      jpegQ = constrain(atoi(v), 10, 95);
      prefs.putInt("q", jpegQ);
    }
    // det=0: solo cámara (sin detectar), para comparar carga y temperatura.
    if (httpd_query_key_value(q, "det", v, sizeof v) == ESP_OK) detOn = atoi(v) != 0;
    if (httpd_query_key_value(q, "model", v, sizeof v) == ESP_OK) {
      usePersons = strcmp(v, "caras") != 0;
      prefs.putBool("persons", usePersons);
    }
    if (httpd_query_key_value(q, "rot", v, sizeof v) == ESP_OK) {
      rot180 = atoi(v) != 0;
      prefs.putBool("rot", rot180);
    }
    // cap=N: guarda una foto de entrenamiento cada N segundos (0 = no).
    if (httpd_query_key_value(q, "cap", v, sizeof v) == ESP_OK) capEvery = constrain(atoi(v), 0, 600);
    if (httpd_query_key_value(q, "mrg", v, sizeof v) == ESP_OK) {
      mergeCells = constrain(atof(v), 0, 6);
      prefs.putFloat("mrg", mergeCells);
    }
    if (httpd_query_key_value(q, "pthr", v, sizeof v) == ESP_OK) {
      personThr = constrain(atof(v), 0.1, 0.95);
      prefs.putFloat("pthr", personThr);
    }
    if (httpd_query_key_value(q, "night", v, sizeof v) == ESP_OK) {
      night = atoi(v) != 0;
      prefs.putBool("night", night);
    }
    reconfig = true;
  }
}

// /set?fs=qvga&q=60&night=1… (ver applySettings); además srv=<servidor> y capnow=1.
esp_err_t handleSet(httpd_req_t *req) {
  SOLO_ADMIN();
  char q[400] = {0}, v[16], sv[300];
  if (httpd_req_get_url_query_str(req, q, sizeof q) == ESP_OK) {
    // srv=<dirección del servidor> (vacía = no enviar).
    if (httpd_query_key_value(q, "srv", sv, sizeof sv) == ESP_OK) setServer(urlDecode(String(sv)));
    if (httpd_query_key_value(q, "capnow", v, sizeof v) == ESP_OK) capNow = true;  // una foto de entrenamiento ya
    applySettings(q);
  }
  String j = cfgJson();
  httpd_resp_set_type(req, "application/json");
  return httpd_resp_send(req, j.c_str(), j.length());
}

// /fotos: lista de fotos guardadas para entrenar, en JSON.
esp_err_t handlePhotos(httpd_req_t *req) {
  SOLO_ADMIN();
  String j = "{\"ok\":" + String(storeOk() ? 1 : 0) + ",\"free_kb\":" + String(freeKB) + ",\"files\":[";
  int n = 0;
  if (storeOk()) {
    File dir = store->open("/fotos");
    for (File f = dir ? dir.openNextFile() : File(); f; f = dir.openNextFile()) {
      String name = f.name();
      name = name.substring(name.lastIndexOf('/') + 1);
      if (name.endsWith(".jpg")) j += String(n++ ? "," : "") + "\"" + name + "\"";
    }
  }
  j += "]}";
  httpd_resp_set_type(req, "application/json");
  return httpd_resp_send(req, j.c_str(), j.length());
}

// /foto?f=t00001.jpg descarga una; /foto?borrar=todas las borra.
esp_err_t handlePhoto(httpd_req_t *req) {
  SOLO_ADMIN();
  char q[64] = {0}, v[40];
  if (!storeOk() || httpd_req_get_url_query_str(req, q, sizeof q) != ESP_OK) return httpd_resp_send_404(req);
  if (httpd_query_key_value(q, "borrar", v, sizeof v) == ESP_OK) {
    int every = capEvery;
    capEvery = 0;
    delay(300);  // deja terminar una captura en curso
    if (sdOk) {
      // En la SD se borran solo las fotos de entrenamiento (la cola no).
      removeFilesIn("/fotos");
    } else {
      // En la memoria interna se formatea: también recupera el espacio
      // perdido si la placa se reinició a mitad de una escritura.
      fatOk = false;
      FFat.end();
      FFat.format();
      fatOk = FFat.begin(true);
      qHead = qTail = 0;  // vacía también la cola de envío
    }
    store->mkdir("/fotos");
    store->mkdir("/q");
    freeKB = measureFreeKB();
    capEvery = every;
    capCount = 0;
    prefs.putUInt("capn", 0);
    httpd_resp_set_type(req, "application/json");
    return httpd_resp_sendstr(req, "{\"borradas\":1}");
  }
  if (httpd_query_key_value(q, "f", v, sizeof v) != ESP_OK || strchr(v, '/')) return httpd_resp_send_404(req);
  File f = store->open(String("/fotos/") + v, "r");
  if (!f) return httpd_resp_send_404(req);
  httpd_resp_set_type(req, "image/jpeg");
  static uint8_t buf[4096];
  size_t r;
  while ((r = f.read(buf, sizeof buf)) > 0) httpd_resp_send_chunk(req, (const char *)buf, r);
  f.close();
  return httpd_resp_send_chunk(req, nullptr, 0);
}

// Guarda la foto actual en buena calidad (para entrenar, no para la página).
void capturePhoto(camera_fb_t *fb) {
  if (!storeOk() || freeKB < capMinFreeKB()) {
    capEvery = 0;
    Serial.println("# memoria de fotos llena: captura detenida");
    logEvent("memoria llena: se detuvo la captura de fotos de entrenamiento");
    return;
  }
  uint8_t *jpg = nullptr;
  size_t len = 0;
  if (!frame2jpg(fb, 90, &jpg, &len)) return;
  char name[24];
  snprintf(name, sizeof name, "/fotos/t%05u.jpg", (unsigned)++capCount);
  File f = store->open(name, "w");
  if (f) {
    f.write(jpg, len);
    f.close();
    prefs.putUInt("capn", capCount);
    freeKB -= min<uint32_t>((uint32_t)freeKB, (uint32_t)(len / 1024 + 1));
  }
  free(jpg);
}

// Borra los archivos de una carpeta (no las subcarpetas).
void removeFilesIn(const char *dirPath) {
  std::vector<String> names;
  File dir = store->open(dirPath);
  for (File f = dir ? dir.openNextFile() : File(); f; f = dir.openNextFile()) {
    if (f.isDirectory()) continue;
    String name = f.name();
    names.push_back(String(dirPath) + "/" + name.substring(name.lastIndexOf('/') + 1));
  }
  if (dir) dir.close();
  for (auto &n : names) store->remove(n);
}

// ---- Envío al servidor -------------------------------------------------------

// Abre una petición al servidor (HTTPS sin verificar certificado, o HTTP).
bool srvBegin(HTTPClient &http, WiFiClientSecure &sec, WiFiClient &plain, const String &path) {
  String url = srvUrl + path;
  http.setTimeout(10000);
  http.setReuse(false);  // cerrar cada conexión: no dejar sockets abiertos entre envíos
  if (srvUrl.startsWith("https")) {
    sec.setInsecure();
    return http.begin(sec, url);
  }
  return http.begin(plain, url);
}

// Valor numérico de `key` en un JSON simple ({"intervalo_ms":1000,...}).
long jsonNumber(const String &body, const char *key, long def) {
  int i = body.indexOf(String("\"") + key + "\"");
  if (i < 0) return def;
  i = body.indexOf(':', i);
  return i < 0 ? def : body.substring(i + 1).toInt();
}

void registerDevice() {
  HTTPClient http;
  WiFiClientSecure sec;
  WiFiClient plain;
  if (!srvBegin(http, sec, plain, "/api/v1/registro")) return;
  http.addHeader("Content-Type", "application/json");
  int code = http.POST(String("{\"id\":\"") + devId + "\",\"fw\":\"" + FW_VERSION + "\"}");
  String body = code > 0 ? http.getString() : "";
  http.end();
  int i = body.indexOf("\"token\":\"");
  if (code == 200 && i >= 0) {
    devToken = body.substring(i + 9, body.indexOf('"', i + 9));
    prefs.putString("tok", devToken);
    snprintf(srvState, sizeof srvState, "registrada");
    Serial.printf("# registrada en el servidor como %s\n", devId);
    logEvent("registrada en el servidor como %s", devId);
  } else if (code == 409) {
    snprintf(srvState, sizeof srvState, "ya registrada: permite registrarla de nuevo en el panel");
  } else {
    snprintf(srvState, sizeof srvState, "no se pudo registrar (%d)", code);
  }
}

// Hora actual en ms desde 1970, o 0 si la cámara aún no la sabe (arrancó sin
// internet y todavía no la tomó del servidor de hora).
uint64_t nowMs() {
  if (!nowEpoch()) return 0;
  struct timeval tv;
  gettimeofday(&tv, nullptr);
  return (uint64_t)tv.tv_sec * 1000 + tv.tv_usec / 1000;
}

// Envía `buf` al servidor con los datos de la cámara en las cabeceras.
int srvPost(const char *path, const char *ctype, const uint8_t *buf, size_t len, uint32_t cola,
            String &body, const char *tsHeader = nullptr, int n = -1) {
  HTTPClient http;
  WiFiClientSecure sec;
  WiFiClient plain;
  if (!srvBegin(http, sec, plain, path)) return -1;
  http.setTimeout(20000);
  http.addHeader("Content-Type", ctype);
  http.addHeader("X-Dispositivo", devId);
  http.addHeader("Authorization", "Bearer " + devToken);
  if (tsHeader) http.addHeader("X-Ts", tsHeader);
  if (n >= 0) http.addHeader("X-Conteo", String(n));
  http.addHeader("X-Cola", String(cola));  // fotos que aún esperan: el servidor no cierra la carrera
  http.addHeader("X-Temp", String(temp, 1));
  http.addHeader("X-Rssi", String(WiFi.RSSI()));
  http.addHeader("X-Fw", FW_VERSION);
  // Ajustes actuales, versión de los ajustes del panel ya aplicados e IP local:
  // el panel los muestra y sabe si tiene que mandar ajustes nuevos.
  http.addHeader("X-Cfg", cfgJson());
  http.addHeader("X-Ajustes-Ver", String(ajustesVer));
  http.addHeader("X-Ip", WiFi.localIP().toString());
  int code = http.POST((uint8_t *)buf, len);
  body = code > 0 ? http.getString() : "";
  http.end();
  return code;
}

// Interpreta la respuesta del servidor. true si se recibió (o si la cámara
// está pendiente de aprobar: no tiene sentido guardar esas fotos).
bool handleReply(int code, const String &body, uint32_t count) {
  // En el registro solo se anotan los cambios (se cayó / volvió), no cada envío.
  static int prevOk = -1;
  if ((code == 200) != (prevOk == 1)) {
    if (code == 200) {
      if (prevOk == 0) logEvent("servidor responde de nuevo");
    } else {
      logEvent("servidor no responde (código %d): las fotos se guardan y se suben después", code);
    }
    prevOk = code == 200;
  }
  if (code == 200) {
    srvInterval = constrain(jsonNumber(body, "intervalo_ms", 5000), 500, 60000);
    // El servidor avisa cuál es el firmware más nuevo: si no es este, se revisa ya.
    int f = body.indexOf("\"firmware\":\"");
    if (f >= 0) {
      String latest = body.substring(f + 12, body.indexOf('"', f + 12));
      if (latest.length() && latest != FW_VERSION) otaHint = true;
    }
    // Ajustes nuevos elegidos en el panel del servidor: se aplican y se anota la versión.
    int a = body.indexOf("\"ajustes_q\":\"");
    long ver = jsonNumber(body, "ajustes_ver", -1);
    if (a >= 0 && ver >= 0 && (uint32_t)ver != ajustesVer) {
      String q = body.substring(a + 13, body.indexOf('"', a + 13));
      Serial.printf("# ajustes del servidor v%ld: %s\n", ver, q.c_str());
      logEvent("ajustes recibidos del panel (v%ld): %s", ver, q.c_str());
      ajustesVer = ver;
      prefs.putUInt("ajv", ajustesVer);  // antes de aplicar: si cambia la resolución, la placa se reinicia
      applySettings(q.c_str());
    }
    sentOk += count;
    lastSentMs = millis();
    snprintf(srvState, sizeof srvState, "conectada");
    return true;
  }
  if (code == 401) {  // el servidor no reconoce el token: registrarse de nuevo
    devToken = "";
    prefs.remove("tok");
  }
  if (code == 403) {
    srvInterval = 30000;
    snprintf(srvState, sizeof srvState, "pendiente de aprobar en el panel");
    return true;
  }
  sentErr++;
  snprintf(srvState, sizeof srvState, code > 0 ? "error del servidor (%d)" : "sin internet (%d)", code);
  return false;
}

// Envía una foto en vivo. false si hay que guardarla para después.
bool postPhoto(const uint8_t *buf, size_t len, uint64_t tsMs, int n) {
  String body;
  // 0 = sin hora: el servidor usa la de llegada. Sin el bit alto (hora estimada, ver TS_APROX).
  String ts = String((double)(tsMs & 0x7FFFFFFFFFFFFFFFULL) / 1000.0, 3);
  int code = srvPost("/api/v1/foto", "image/jpeg", buf, len, queueSize(), body, ts.c_str(), n);
  return handleReply(code, body, 1);
}

String qDir(uint32_t seq) {
  char b[12];
  snprintf(b, sizeof b, "/q/%03X", (unsigned)(seq >> 12));
  return b;
}

String qPath(uint32_t seq) {
  char b[20];
  snprintf(b, sizeof b, "/q/%03X/%03X.JPG", (unsigned)(seq >> 12), (unsigned)(seq & 0xFFF));
  return b;
}

// La foto más vieja ya se envió (o se descartó): se avanza y, al terminar una
// carpeta de 4096, se borra.
void queueDropHead() {
  store->remove(qPath(qHead));
  qHead++;
  if ((qHead & 0xFFF) == 0 || qHead == qTail) store->rmdir(qDir(qHead - 1));
}

// Cabecera de cada foto en la cola. Si la cámara no sabía la hora al tomarla
// (arrancó sin internet), se guarda el momento en millis() y el número de
// arranque: si más tarde, sin reiniciarse, consigue la hora, la calcula hacia atrás.
struct QHdr {
  uint32_t magic;  // QMAGIC (las versiones anteriores guardaban solo hora y conteo, 8 bytes)
  uint32_t boot;   // número de arranque
  uint64_t tsMs;   // hora en ms desde 1970 (0 = no se sabía)
  uint32_t ms;     // millis() al tomarla
  int32_t n;       // pasajeros que contó la cámara
};
const uint32_t QMAGIC = 0x32515854;  // "TXQ2"
uint32_t bootN = 0;

// Las fotos de la cola van cifradas en la tarjeta (AES-128-CTR con una clave
// propia de cada cámara, guardada en su memoria interna): quien saque la SD
// no puede verlas. Mismo formato que TXQ2, con otra marca.
const uint32_t QMAGIC_CIF = 0x33515854;  // "TXQ3"
uint8_t claveAes[16];
bool claveLista = false;

// Cifra o descifra (en CTR es la misma operación). Cada foto usa su propio
// contador, armado con su arranque y su momento (nunca se repite).
void cifrar(uint8_t *d, size_t len, uint32_t boot, uint32_t ms) {
  if (!claveLista) {
    if (prefs.getBytes("aesk", claveAes, 16) != 16) {
      esp_fill_random(claveAes, 16);
      prefs.putBytes("aesk", claveAes, 16);
    }
    claveLista = true;
  }
  mbedtls_aes_context ctx;
  mbedtls_aes_init(&ctx);
  mbedtls_aes_setkey_enc(&ctx, claveAes, 128);
  uint8_t nonce[16] = {0}, bloque[16];
  size_t off = 0;
  memcpy(nonce, &boot, 4);
  memcpy(nonce + 4, &ms, 4);
  mbedtls_aes_crypt_ctr(&ctx, len, &off, nonce, bloque, d, d);
  mbedtls_aes_free(&ctx);
}

// Hora de las fotos de un arranque sin internet (la cámara no tiene reloj
// propio). Por cada arranque se guarda cuánto duró y, si llegó a saber la
// hora, a qué hora empezó. Una foto sin hora del arranque b queda en
//   inicio(B) - (lo que faltaba de b y la duración de los arranques entre medio)
// donde B es el primer arranque posterior que sí supo la hora. Supone que se
// volvió a encender enseguida: si estuvo apagada un rato, la hora sale más
// tarde que la real, pero el orden de las fotos siempre es el correcto.
const int BOOT_RECS = 32;
const uint64_t TS_APROX = 1ULL << 63;  // marca en la hora enviada: es estimada

bool bootRec(uint32_t b, BootRec &r) {
  char k[8];
  snprintf(k, sizeof k, "bt%02u", (unsigned)(b % BOOT_RECS));
  return prefs.getBytes(k, &r, sizeof r) == sizeof r && r.boot == b;
}

// Cada minuto: duración del arranque actual y, en cuanto se sabe, su hora de inicio.
void updateBootRec() {
  BootRec r;
  if (!bootRec(bootN, r)) r = {bootN, 0, 0};
  r.dur = millis();
  time_t t = nowEpoch();
  if (!r.start && t) r.start = t - millis() / 1000;
  char k[8];
  snprintf(k, sizeof k, "bt%02u", (unsigned)(bootN % BOOT_RECS));
  prefs.putBytes(k, &r, sizeof r);
}

// Cuánto duró un arranque. La duración se anota cada minuto, así que si se
// cortó la corriente entre medio queda corta: la última foto de ese arranque
// en la cola da un dato mejor. La cola se recorre una sola vez, avanzando
// junto con la subida (antes se releía entera por cada foto y, con cientos de
// fotos de varios arranques, la subida quedaba casi detenida).
uint32_t bootDuration(uint32_t boot, uint32_t saved) {
  static std::vector<std::pair<uint32_t, uint32_t>> ultimo;  // (arranque, ms de su última foto)
  static uint32_t pos = 0;
  if (pos < qHead) pos = qHead;
  if (pos > qTail) pos = qTail;  // la cola se vació o se volvió a leer
  // Se lee hasta ver una foto de un arranque posterior: ahí ya están todas las de `boot`.
  while (pos < qTail && (ultimo.empty() || ultimo.back().first <= boot)) {
    File f = store->open(qPath(pos), "r");
    pos++;
    if (!f) continue;
    QHdr h = {};
    bool ok = f.read((uint8_t *)&h, sizeof h) == sizeof h && (h.magic == QMAGIC || h.magic == QMAGIC_CIF);
    f.close();
    if (!ok) continue;
    if (!ultimo.empty() && ultimo.back().first == h.boot) ultimo.back().second = max(ultimo.back().second, h.ms);
    else ultimo.push_back({h.boot, h.ms});
    if (ultimo.size() > 64) ultimo.erase(ultimo.begin());
  }
  for (auto &u : ultimo)
    if (u.first == boot) return max(saved, u.second);
  return saved;
}

// Hora en ms de una foto sin hora (arranque `boot`, `ms` desde que arrancó).
// Lleva la marca TS_APROX si es estimada; 0 si no hay datos para calcularla.
uint64_t estimateMs(uint32_t boot, uint32_t ms) {
  BootRec r;
  if (!bootRec(boot, r)) return 0;
  if (r.start) return (uint64_t)r.start * 1000 + ms;  // ese arranque supo la hora después
  uint32_t dur = bootDuration(boot, r.dur);
  uint64_t before = dur > ms ? dur - ms : 0;
  for (uint32_t b = boot + 1; b <= bootN && b < boot + BOOT_RECS; b++) {
    if (b == bootN) {  // el arranque actual: su inicio se calcula ahora, no del registro de cada minuto
      uint64_t now = nowMs();
      return now ? ((now - millis()) - before) | TS_APROX : 0;
    }
    // Un arranque que no alcanzó a anotarse (se cortó la corriente al toque)
    // no corta la cuenta: se toma su duración de sus fotos (o 0 si no tiene).
    if (!bootRec(b, r)) r = {b, 0, 0};
    if (r.start) return ((uint64_t)r.start * 1000 - before) | TS_APROX;
    before += bootDuration(b, r.dur);
  }
  return 0;
}

// Registro de lo que pasa (arranques, WiFi, estado cada minuto) en
// /registro.txt de la SD o memoria interna, para revisar después qué pasó
// mientras la cámara funcionaba sola. Se lee por cable con el comando LOG.
void logEvent(const char *fmt, ...) {
  if (!storeOk()) return;
  char msg[180];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(msg, sizeof msg, fmt, ap);
  va_end(ap);
  File f = store->open("/registro.txt", "a");
  if (!f) {
    storeFailed("anotar en el registro");
    if (!storeOk() || !(f = store->open("/registro.txt", "a"))) return;
  }
  if (f.size() > 256 * 1024) {  // muy largo: se guarda como .old y se empieza otro
    f.close();
    store->remove("/registro.old");
    store->rename("/registro.txt", "/registro.old");
    f = store->open("/registro.txt", "a");
    if (!f) return;
  }
  char ts[24];
  time_t t = nowEpoch();
  if (t) {
    struct tm tm;
    localtime_r(&t, &tm);
    strftime(ts, sizeof ts, "%d/%m %H:%M:%S", &tm);
  } else {
    snprintf(ts, sizeof ts, "+%lus sin hora", millis() / 1000);
  }
  f.printf("%s [arranque %u] %s\n", ts, (unsigned)bootN, msg);
  f.close();
  // Copia pendiente de enviar al servidor (sendLogs la sube cuando hay internet).
  File p = store->open("/registro.pend", "a");
  if (p) {
    if (p.size() < 200 * 1024) p.printf("%s [arranque %u] %s\n", ts, (unsigned)bootN, msg);
    p.close();
  }
}

// Sube al servidor las líneas del registro que aún no envió. Se renombran
// antes de enviar para que lo que se anote mientras tanto vaya a otro archivo.
bool sendLogs() {
  if (!storeOk()) return true;
  if (!store->exists("/registro.env")) {
    if (!store->exists("/registro.pend")) return true;
    store->rename("/registro.pend", "/registro.env");
  }
  File f = store->open("/registro.env", "r");
  if (!f) return true;
  size_t len = f.size();
  uint8_t *buf = len ? (uint8_t *)ps_malloc(len) : nullptr;
  if (!buf) {
    f.close();
    store->remove("/registro.env");
    return true;
  }
  f.read(buf, len);
  f.close();
  String body;
  int code = srvPost("/api/v1/eventos", "text/plain; charset=utf-8", buf, len, queueSize(), body);
  free(buf);
  if (code == 200) store->remove("/registro.env");
  return code == 200;
}

// Muestra por el puerto serie el final del registro (comando LOG).
void printLog() {
  File f = storeOk() ? store->open("/registro.txt", "r") : File();
  if (!f) { Serial.println("# (registro vacío)"); return; }
  size_t size = f.size();
  if (size > 6000) f.seek(size - 6000);
  Serial.println("# ---- registro ----");
  while (f.available()) Serial.write(f.read());
  Serial.println("# ---- fin del registro ----");
  f.close();
}

// Lee la foto `seq` de la cola (buf queda en PSRAM: liberarlo con free).
bool readQueued(uint32_t seq, uint8_t *&buf, size_t &len, uint64_t &tsMs, int &n) {
  buf = nullptr;
  File f = store->open(qPath(seq), "r");
  if (!f) return false;
  size_t total = f.size();
  QHdr h = {};
  size_t hdr = sizeof h;
  if (total < 8 || f.read((uint8_t *)&h, min(total, sizeof h)) < 8) { f.close(); return false; }
  bool cifrada = h.magic == QMAGIC_CIF;
  if (h.magic != QMAGIC && !cifrada) {  // formato anterior: [hora en s][conteo]
    uint32_t *old = (uint32_t *)&h;
    tsMs = (uint64_t)old[0] * 1000;
    n = (int32_t)old[1];
    hdr = 8;
  } else {
    tsMs = h.tsMs;
    n = h.n;
    if (!tsMs && h.boot == bootN && nowMs()) tsMs = nowMs() - (millis() - h.ms);
    else if (!tsMs && h.boot != bootN) tsMs = estimateMs(h.boot, h.ms);
  }
  if (total <= hdr + 2) { f.close(); return false; }
  len = total - hdr;
  buf = (uint8_t *)ps_malloc(len);
  if (buf) {
    f.seek(hdr);
    bool leida = f.read(buf, len) == len;
    if (leida && cifrada) cifrar(buf, len, h.boot, h.ms);  // descifra
    if (!leida || buf[0] != 0xFF || buf[1] != 0xD8) {
      free(buf);
      buf = nullptr;
    }
  }
  f.close();
  return buf != nullptr;
}

// Guarda una foto en la cola, con su cabecera QHdr delante.
void enqueuePhoto(const uint8_t *buf, size_t len, uint64_t tsMs, int n) {
  if (!storeOk()) return;
  // Memoria casi llena: se descartan las fotos más viejas de la cola. Antes se
  // vuelve a medir: si la tarjeta falló, la medición da 0 y se borraba la cola
  // entera sin estar llena.
  if (freeKB < queueMinFreeKB()) {
    freeKB = measureFreeKB();
    if (!freeKB) {
      storeFailed("medir el espacio libre");
      return;
    }
  }
  uint32_t dropped = 0;
  while (freeKB < queueMinFreeKB() && qHead < qTail) {
    queueDropHead();
    freeKB += len / 1024 + 1;
    dropped++;
  }
  if (dropped) logEvent("memoria llena: se descartaron %u fotos viejas sin enviar", (unsigned)dropped);
  String path = qPath(qTail);
  File f = store->open(path, "w");
  if (!f) {
    store->mkdir(qDir(qTail));
    f = store->open(path, "w");
  }
  if (!f) {
    storeFailed("guardar una foto");
    return;
  }
  QHdr h = {QMAGIC_CIF, bootN, tsMs, millis(), n};
  uint8_t *cif = (uint8_t *)ps_malloc(len);
  if (!cif) {
    f.close();
    store->remove(path);
    return;
  }
  memcpy(cif, buf, len);
  cifrar(cif, len, h.boot, h.ms);
  size_t w = f.write((const uint8_t *)&h, sizeof h);
  w += f.write(cif, len);
  free(cif);
  f.close();
  if (w != sizeof h + len) {
    store->remove(path);
    storeFailed("guardar una foto");
    return;
  }
  qTail++;
  freeKB -= min<uint32_t>((uint32_t)freeKB, (uint32_t)(len / 1024 + 1));
}

// Sube la foto más vieja de la cola, sola. false si no se pudo (sin internet).
bool sendOldestQueued() {
  while (qHead < qTail) {
    uint8_t *buf;
    size_t len;
    uint64_t tsMs;
    int n;
    if (!readQueued(qHead, buf, len, tsMs, n)) {  // falta o quedó a medias (corte de luz)
      queueDropHead();
      continue;
    }
    bool ok = postPhoto(buf, len, tsMs, n);
    free(buf);
    if (ok) queueDropHead();
    return ok;
  }
  return true;
}

// Sube varias fotos de la cola en un solo envío (mucho más rápido que una por
// una con días de fotos guardadas). Formato por foto: hora en ms (8 bytes),
// conteo (4), largo (4) y el JPEG. false si no se pudo (sin internet).
// Tamaño del lote: se adapta a la conexión. Si un envío se corta (WiFi débil,
// hotspot lento) el siguiente es la mitad; si sale bien, vuelve a crecer.
const size_t BATCH_MAX = 300 * 1024, BATCH_MIN = 16 * 1024;
size_t batchBytes = 64 * 1024;

bool sendBatch() {
  const size_t MAX_BYTES = batchBytes;
  const int MAX_FOTOS = 20;
  uint8_t *out = (uint8_t *)ps_malloc(MAX_BYTES + 64 * 1024);
  if (!out) return false;
  size_t used = 0;
  int k = 0;
  while (qHead + k < qTail && k < MAX_FOTOS) {
    uint8_t *buf;
    size_t len;
    uint64_t tsMs;
    int n;
    if (!readQueued(qHead + k, buf, len, tsMs, n)) {
      if (k == 0) { queueDropHead(); continue; }  // dañada al principio: se descarta
      break;                                       // en medio: se manda lo que hay
    }
    if (k > 0 && used + 16 + len > MAX_BYTES) { free(buf); break; }
    uint32_t len32 = len;
    memcpy(out + used, &tsMs, 8);
    memcpy(out + used + 8, &n, 4);
    memcpy(out + used + 12, &len32, 4);
    memcpy(out + used + 16, buf, len);
    used += 16 + len;
    free(buf);
    k++;
  }
  if (!k) { free(out); return true; }
  String body;
  int code = srvPost("/api/v1/lote", "application/octet-stream", out, used, queueSize() - k, body);
  free(out);
  if (code == 404) return sendOldestQueued();  // servidor viejo sin envío por lotes
  if (code == 200) batchBytes = min(batchBytes * 2, BATCH_MAX);
  else if (code < 0) batchBytes = max(batchBytes / 2, BATCH_MIN);  // se cortó: lotes más chicos
  bool ok = handleReply(code, body, k);
  if (ok && code == 200) for (int i = 0; i < k; i++) queueDropHead();
  return ok && code == 200;
}

// Al arrancar: busca dónde empieza y termina la cola que quedó guardada.
void queueInit() {
  store->mkdir("/q");
  int minD = 0x1000, maxD = -1;
  std::vector<String> old;
  File root = store->open("/q");
  for (File e = root ? root.openNextFile() : File(); e; e = root.openNextFile()) {
    String name = e.name();
    name = name.substring(name.lastIndexOf('/') + 1);
    if (e.isDirectory()) {
      int d = strtol(name.c_str(), nullptr, 16);
      minD = min(minD, d);
      maxD = max(maxD, d);
    } else {
      old.push_back("/q/" + name);  // formato de versiones anteriores: se descarta
    }
  }
  if (root) root.close();
  for (auto &o : old) store->remove(o);
  if (maxD < 0) {
    qHead = qTail = 0;
    return;
  }
  // Primera foto de la carpeta más vieja y última de la más nueva.
  auto scan = [](int d, bool first) -> int {
    int best = first ? 0x1000 : -1;
    File dir = store->open(qDir((uint32_t)d << 12));
    for (File f = dir ? dir.openNextFile() : File(); f; f = dir.openNextFile()) {
      String name = f.name();
      int i = strtol(name.substring(name.lastIndexOf('/') + 1).c_str(), nullptr, 16);
      best = first ? min(best, i) : max(best, i);
    }
    if (dir) dir.close();
    return best;
  };
  int h = scan(minD, true), t = scan(maxD, false);
  qHead = ((uint32_t)minD << 12) + (h < 0x1000 ? h : 0);
  qTail = ((uint32_t)maxD << 12) + (t >= 0 ? t + 1 : 0);
  if (qTail < qHead) qTail = qHead;
}

void storeFailed(const char *what) {
  static volatile bool busy = false;
  static uint32_t lastFix = 0;
  storeErrors++;
  if (busy || (lastFix && millis() - lastFix < 10000)) return;
  busy = true;
  lastFix = millis();
  if (sdOk) {
    SD_MMC.end();
    delay(200);
    if (SD_MMC.begin("/sdcard", true, false) && SD_MMC.cardType() != CARD_NONE) {
      queueInit();  // la cola se vuelve a leer de la tarjeta
      freeKB = measureFreeKB();
      Serial.printf("# tarjeta SD montada de nuevo (fallo al %s)\n", what);
      logEvent("tarjeta SD montada de nuevo tras un fallo al %s", what);
    } else {
      sdOk = false;
      if (fatOk) {
        store = &FFat;
        queueInit();
        freeKB = measureFreeKB();
      }
      Serial.printf("# ERROR: la tarjeta SD dejo de responder (%s); se usa la memoria interna\n", what);
      logEvent("ERROR: la tarjeta SD dejó de responder al %s: se sigue en la memoria interna", what);
    }
  }
  busy = false;
}

// Si en algún arranque la SD falló y se guardó en la memoria interna, al volver
// la tarjeta se pasa todo a ella: las fotos al final de la cola (son más nuevas
// que las que ya estaban) y las líneas del registro.
void rescueInternal() {
  if (!sdOk || !fatOk) return;
  uint32_t moved = 0;
  std::vector<String> dirs;
  File root = FFat.open("/q");
  for (File e = root ? root.openNextFile() : File(); e; e = root.openNextFile())
    if (e.isDirectory()) dirs.push_back(String("/q/") + String(e.name()).substring(String(e.name()).lastIndexOf('/') + 1));
  if (root) root.close();
  std::sort(dirs.begin(), dirs.end());
  for (auto &d : dirs) {
    std::vector<String> files;
    File dir = FFat.open(d);
    for (File f = dir ? dir.openNextFile() : File(); f; f = dir.openNextFile())
      files.push_back(d + "/" + String(f.name()).substring(String(f.name()).lastIndexOf('/') + 1));
    if (dir) dir.close();
    std::sort(files.begin(), files.end());
    for (auto &p : files) {
      File in = FFat.open(p, "r");
      size_t len = in ? in.size() : 0;
      uint8_t *buf = len ? (uint8_t *)ps_malloc(len) : nullptr;
      if (buf && in.read(buf, len) == len) {
        SD_MMC.mkdir(qDir(qTail));
        File out = SD_MMC.open(qPath(qTail), "w");
        if (out && out.write(buf, len) == len) { qTail++; moved++; }
        if (out) out.close();
      }
      if (in) in.close();
      free(buf);
      FFat.remove(p);
    }
    FFat.rmdir(d);
  }
  for (const char *name : {"/registro.txt", "/registro.pend"}) {
    File in = FFat.open(name, "r");
    if (!in) continue;
    File out = SD_MMC.open(name, "a");
    uint8_t b[512];
    size_t k;
    while (out && (k = in.read(b, sizeof b)) > 0) out.write(b, k);
    if (out) out.close();
    in.close();
    FFat.remove(name);
  }
  if (moved) logEvent("se pasaron a la SD %u fotos que quedaron en la memoria interna", (unsigned)moved);
}

// Comando SDTEST: escribe 1 MB en la memoria en uso, lo lee, lo compara byte a
// byte y mide la velocidad. Para descartar una tarjeta defectuosa.
void sdSelfTest() {
  if (!storeOk()) { Serial.println("# SDTEST: no hay memoria disponible"); return; }
  const size_t CH = 8192, N = 128;
  uint8_t *b = (uint8_t *)ps_malloc(CH), *r = (uint8_t *)ps_malloc(CH);
  if (!b || !r) { free(b); free(r); Serial.println("# SDTEST: sin RAM"); return; }
  bool ok = true;
  uint32_t t0 = millis();
  File f = store->open("/sdtest.bin", "w");
  for (size_t i = 0; f && i < N && ok; i++) {
    for (size_t k = 0; k < CH; k++) b[k] = (uint8_t)(i * 31 + k * 7);
    ok = f.write(b, CH) == CH;
  }
  if (!f) ok = false;
  if (f) f.close();
  uint32_t tw = millis() - t0;
  t0 = millis();
  f = ok ? store->open("/sdtest.bin", "r") : File();
  for (size_t i = 0; f && i < N && ok; i++) {
    for (size_t k = 0; k < CH; k++) b[k] = (uint8_t)(i * 31 + k * 7);
    ok = f.read(r, CH) == CH && memcmp(b, r, CH) == 0;
  }
  if (!f) ok = false;
  if (f) f.close();
  uint32_t tr = millis() - t0;
  store->remove("/sdtest.bin");
  free(b);
  free(r);
  Serial.printf("# SDTEST %s en %s: escritura %u KB/s, lectura %u KB/s, errores acumulados %u\n",
                ok ? "OK" : "FALLO", sdOk ? "SD" : "memoria interna", (unsigned)(1024000 / max<uint32_t>(tw, 1)),
                (unsigned)(1024000 / max<uint32_t>(tr, 1)), (unsigned)storeErrors);
  logEvent("prueba de memoria (%s): %s, escritura %u KB/s", sdOk ? "SD" : "interna", ok ? "OK" : "FALLO",
           (unsigned)(1024000 / max<uint32_t>(tw, 1)));
}

// Descarga el firmware y lo escribe en la otra partición; si todo llega bien,
// reinicia con él. Devuelve el motivo si falla. (Se hace a mano en vez de con
// HTTPUpdate: este revisa el primer byte antes de que llegue y falla en
// conexiones lentas.)
const char *flashFromServer(const String &path) {
  HTTPClient http;
  WiFiClientSecure sec;
  WiFiClient plain;
  int code = 0, total = 0;
  for (int attempt = 1; attempt <= 3; attempt++) {
    if (!srvBegin(http, sec, plain, path)) return "no se pudo conectar";
    http.setTimeout(30000);
    code = http.GET();
    total = http.getSize();
    Serial.printf("# descarga intento %d: codigo %d, %d bytes, WiFi %d, RAM %u KB\n", attempt, code, total,
                  (int)WiFi.status(), (unsigned)(ESP.getFreeHeap() / 1024));
    if (code == 200 && total >= 100000) break;
    http.end();
    vTaskDelay(pdMS_TO_TICKS(2000));
  }
  if (code != 200 || total < 100000) return "el servidor no entregó el firmware";
  if (!Update.begin(total, U_FLASH)) {
    http.end();
    return "no hay espacio para el firmware";
  }
  // Escribir la flash ocupa mucho este núcleo: el vigilante de tareas creería
  // que se colgó y reiniciaría la placa a mitad. Se pausa mientras dura.
  disableCore0WDT();
  static uint8_t buf[4096];
  WiFiClient *s = http.getStreamPtr();
  int done = 0, lastPct = -1;
  uint32_t lastData = millis();
  const char *err = nullptr;
  while (done < total) {
    size_t avail = s->available();
    if (!avail) {
      if (millis() - lastData > 30000) { err = "la descarga se cortó"; break; }
      vTaskDelay(pdMS_TO_TICKS(5));
      continue;
    }
    int n = s->readBytes(buf, min(avail, sizeof buf));
    if (done == 0 && buf[0] != 0xE9) { err = "el archivo no es un firmware de ESP32"; break; }
    if ((int)Update.write(buf, n) != n) { err = "error al escribir la flash"; break; }
    done += n;
    lastData = millis();
    int pct = done * 100 / total;
    if (pct / 10 != lastPct) {
      lastPct = pct / 10;
      snprintf(srvState, sizeof srvState, "instalando firmware: %d%%", pct);
      Serial.printf("# actualizacion %d%%\n", pct);
    }
  }
  http.end();
  enableCore0WDT();
  if (err) {
    Update.abort();
    return err;
  }
  if (!Update.end(true)) return "el firmware llegó dañado";
  Serial.println("# firmware instalado: reiniciando");
  logEvent("firmware nuevo instalado: reiniciando con él");
  delay(300);
  ESP.restart();
  return "";
}

// Pregunta al servidor si hay firmware nuevo y, si lo hay, lo instala y reinicia.
void checkFirmware() {
  HTTPClient http;
  WiFiClientSecure sec;
  WiFiClient plain;
  String q = String("/api/v1/firmware?id=") + devId + "&token=" + devToken + "&actual=" + FW_VERSION;
  if (!srvBegin(http, sec, plain, q)) return;
  int code = http.GET();
  String body = code == 200 ? http.getString() : "";
  http.end();
  int i = body.indexOf("\"url\":\""), v = body.indexOf("\"version\":\"");
  if (body.indexOf("\"actualizar\":true") < 0 || i < 0 || v < 0) return;
  String path = body.substring(i + 7, body.indexOf('"', i + 7));
  String version = body.substring(v + 11, body.indexOf('"', v + 11));

  // Si esta versión ya falló 3 veces (p. ej. se corta la luz al instalar), no se
  // insiste hasta que se publique otra: la cámara nunca queda reiniciándose.
  if (prefs.getString("otaVer", "") != version) {
    prefs.putString("otaVer", version);
    prefs.putUInt("otaTries", 0);
  }
  uint32_t tries = prefs.getUInt("otaTries", 0);
  if (tries >= 3) {
    snprintf(srvState, sizeof srvState, "firmware %s falló 3 veces: no se reintenta", version.c_str());
    return;
  }
  prefs.putUInt("otaTries", tries + 1);
  snprintf(srvState, sizeof srvState, "instalando firmware %s…", version.c_str());
  Serial.printf("# firmware %s en el servidor: instalando (intento %u)\n", version.c_str(), (unsigned)tries + 1);

  otaRequested = true;  // el bucle principal se pausa
  for (int k = 0; k < 50 && !camStopped; k++) vTaskDelay(pdMS_TO_TICKS(100));
  Serial.printf("# descargando firmware %s\n", version.c_str());
  logEvent("instalando firmware %s (intento %u)", version.c_str(), (unsigned)tries + 1);
  const char *err = flashFromServer(path);
  // Solo se llega aquí si falló (si salió bien la placa ya se reinició).
  logEvent("FALLÓ la actualización a %s: %s", version.c_str(), err);
  snprintf(srvState, sizeof srvState, "falló la actualización: %s", err);
  Serial.printf("# %s\n", srvState);
  otaRequested = false;  // el bucle principal sigue
}

// Tarea aparte (núcleo 0) para que enviar no frene la cámara ni la detección.
void uploadTask(void *) {
  // Las fotos se toman SIEMPRE (con o sin internet o servidor): si no se pueden
  // enviar quedan guardadas con su hora y se suben después, en orden.
  uint32_t lastLive = 0, lastReg = 0, retryAt = 0, lastOta = millis() - OTA_CHECK_MS + 60000;
  for (;;) {
    vTaskDelay(pdMS_TO_TICKS(100));
    bool online = WiFi.status() == WL_CONNECTED && srvUrl.length();
    if (online && !devToken.length() && millis() - lastReg > 10000) {
      lastReg = millis();
      registerDevice();
    }
    bool canSend = online && devToken.length();
    // Revisión cada hora, o antes si el servidor avisó (como mucho cada 10 min,
    // para no reintentar sin parar si una actualización falla).
    if (canSend && (millis() - lastOta >= OTA_CHECK_MS || (otaHint && millis() - lastOta >= 600000))) {
      lastOta = millis();
      otaHint = false;
      checkFirmware();
    }
    // Ritmo: 1 foto/s durante ~6 s cuando cambia el conteo o se está confirmando
    // una carrera. Si no, el que pide el servidor; sin internet, 4 s en carrera
    // y 15 s con la cabina vacía (la SD dura días sin llenarse).
    static int lastPax = 0;
    static uint32_t lastChange = 0;
    if (paxNow != lastPax) {
      lastPax = paxNow;
      lastChange = millis();
    }
    bool burst = lastChange && millis() - lastChange < 6000;
    uint32_t base = canSend ? srvInterval : ((paxNow > 0 || state != LIBRE) ? 4000 : 15000);
    uint32_t every = (burst || state == CONFIRMANDO) ? 1000 : base;
    if (millis() - lastLive >= every) {
      lastLive = millis();
      xSemaphoreTake(lock, portMAX_DELAY);
      size_t len = lastLen;
      uint8_t *buf = lastJpg && len ? (uint8_t *)ps_malloc(len) : nullptr;
      if (buf) memcpy(buf, lastJpg, len);
      // Marca de "tomada con WiFi": con internet la cámara suele estar en la casa
      // del dueño subiendo lo grabado, no en el taxi. El servidor deja esas
      // carreras "por revisar" en vez de contarlas.
      int n = paxNow | (WiFi.status() == WL_CONNECTED ? FOTO_CON_WIFI : 0);
      xSemaphoreGive(lock);
      if (buf) {
        uint64_t ts = nowMs();
        // Si hay fotos esperando, la nueva va detrás de ellas: así el servidor
        // las recibe siempre en el orden en que se tomaron.
        if (!canSend || queueSize() > 0 || !postPhoto(buf, len, ts, n)) enqueuePhoto(buf, len, ts, n);
        free(buf);
      }
      continue;
    }
    // El registro de eventos se sube cada minuto (lo anotado sin internet, al volver).
    static uint32_t lastLogs = 0;
    if (canSend && millis() - lastLogs > 60000) {
      lastLogs = millis();
      sendLogs();
    }
    // Entre foto y foto se va vaciando la cola, de a varias por envío. Si el
    // servidor no responde se reintenta en 15 s, sin frenar las fotos. Recién
    // conectada se espera a tener la hora de internet (unos segundos, como
    // mucho 2 min): con ella se calcula la de las fotos tomadas sin hora.
    bool clockReady = nowEpoch() || millis() > 120000;
    if (canSend && clockReady && queueSize() > 0 && (int32_t)(millis() - retryAt) >= 0 && !sendBatch()) {
      retryAt = millis() + 15000;
    }
  }
}

void startUploader() {
  uint64_t mac = ESP.getEfuseMac();
  snprintf(devId, sizeof devId, "TX-%02X%02X%02X", (uint8_t)(mac >> 24), (uint8_t)(mac >> 32), (uint8_t)(mac >> 40));
  srvUrl = prefs.getString("srv", "");
  devToken = prefs.getString("tok", "");
  ajustesVer = prefs.getUInt("ajv", 0);
  if (srvUrl.length()) snprintf(srvState, sizeof srvState, "conectando…");
  if (storeOk()) queueInit();
  Serial.printf("# camara %s · servidor: %s · %u fotos en cola\n", devId,
                srvUrl.length() ? srvUrl.c_str() : "(ninguno)", (unsigned)queueSize());
  xTaskCreatePinnedToCore(uploadTask, "subida", 12288, nullptr, 1, nullptr, 0);
}

void setServer(String url) {
  url.trim();
  while (url.endsWith("/")) url.remove(url.length() - 1);
  srvUrl = url;
  prefs.putString("srv", url);
  snprintf(srvState, sizeof srvState, url.length() ? "conectando…" : "sin servidor configurado");
}

void startServer() {
  httpd_config_t cfg = HTTPD_DEFAULT_CONFIG();
  cfg.max_uri_handlers = 16;
  cfg.stack_size = 8192;
  if (httpd_start(&server, &cfg) != ESP_OK) return;
  httpd_uri_t uris[] = {
      {"/", HTTP_GET, handlePage, nullptr},
      {"/frame", HTTP_GET, handleFrame, nullptr},
      {"/status", HTTP_GET, handleStatus, nullptr},
      {"/wifi", HTTP_GET, handleSetup, nullptr},
      {"/save", HTTP_POST, handleSave, nullptr},
      {"/wifi_borrar", HTTP_POST, handleWifiBorrar, nullptr},
      {"/redes", HTTP_GET, handleRedes, nullptr},
      {"/set", HTTP_GET, handleSet, nullptr},
      {"/fotos", HTTP_GET, handlePhotos, nullptr},
      {"/foto", HTTP_GET, handlePhoto, nullptr},
  };
  for (auto &u : uris) httpd_register_uri_handler(server, &u);
  httpd_register_err_handler(server, HTTPD_404_NOT_FOUND, handleNotFound);  // portal cautivo
}

// Busca las redes guardadas que estén a la vista y se conecta a la de mejor
// señal (en redes de varios puntos, al punto de 2,4 GHz más fuerte). Prueba
// hasta 3 candidatas. true si quedó conectada.
bool connectBest(bool verbose) {
  auto redes = loadNetworks();
  if (redes.empty()) return false;
  esperarBusqueda();
  int n = WiFi.scanNetworks();
  std::vector<std::pair<int, int>> cand;  // (señal, índice en la búsqueda)
  for (int i = 0; i < n; i++)
    for (auto &r : redes)
      if (WiFi.SSID(i) == r.ssid) cand.push_back({WiFi.RSSI(i), i});
  if (sinWifi) cand.clear();  // prueba: como si ninguna estuviera a la vista
  std::sort(cand.begin(), cand.end(), [](const std::pair<int, int> &a, const std::pair<int, int> &b) { return a.first > b.first; });
  if (cand.empty() && verbose) {
    Serial.println("# ninguna red guardada a la vista. Redes visibles:");
    for (int i = 0; i < n && i < 12; i++) Serial.printf("#   red: %s  canal %d  %d dBm\n", WiFi.SSID(i).c_str(), WiFi.channel(i), WiFi.RSSI(i));
  }
  int tries = 0;
  for (auto &c : cand) {
    if (tries++ >= 3) break;
    int i = c.second;
    String ssid = WiFi.SSID(i), pass;
    for (auto &r : redes) if (r.ssid == ssid) pass = r.pass;
    if (verbose) Serial.printf("# Conectando a %s (canal %d, %d dBm)", ssid.c_str(), WiFi.channel(i), WiFi.RSSI(i));
    WiFi.begin(ssid.c_str(), pass.c_str(), WiFi.channel(i), WiFi.BSSID(i));
    for (int k = 0; k < 30 && WiFi.status() != WL_CONNECTED; k++) {
      delay(500);
      if (verbose) Serial.print(".");
    }
    if (verbose) Serial.println();
    if (WiFi.status() == WL_CONNECTED) return true;
    logEvent("no se pudo conectar a '%s' (estado %d: ¿clave incorrecta?)", ssid.c_str(), WiFi.status());
    prefs.putString("wmal", ssid);  // la página de WiFi avisa que revise la clave
    WiFi.disconnect();
    delay(300);
  }
  return false;
}

void onConnected(const char *como) {
  if (prefs.isKey("wmal")) prefs.remove("wmal");
  MDNS.begin("taxiff-cam");
  configTzTime("<-05>5", "pool.ntp.org", "time.google.com");  // hora de Ecuador
  Serial.printf("# WiFi OK: abre http://%s o http://taxiff-cam.local\n", WiFi.localIP().toString().c_str());
  logEvent("WiFi conectado a %s (%d dBm), IP %s%s", WiFi.SSID().c_str(), WiFi.RSSI(),
           WiFi.localIP().toString().c_str(), como);
}

// Red propia "Taxiff-Cam" para configurar la WiFi desde el teléfono (portal
// cautivo). Si ya hay redes guardadas se cierra sola a los `ms`, para que en
// el taxi no quede una red visible todo el día; se reabre manteniendo BOOT 3 s.
void startPortal(uint32_t ms) {
  apMode = true;
  portalUntil = millis() + ms;
  WiFi.mode(WIFI_AP_STA);  // a la vez sigue buscando las redes guardadas
  WiFi.softAP(AP_SSID, AP_PASS);
  dns.start(53, "*", WiFi.softAPIP());
  portalDesde = millis();  // la lista de redes se busca a los 3 s (ver loop)
  Serial.printf("# Configurar WiFi: conectate a la red %s (clave %s); la pagina se abre sola\n", AP_SSID, AP_PASS);
  logEvent("red de configuración '%s' abierta", AP_SSID);
}

void closePortal() {
  dns.stop();
  WiFi.softAPdisconnect(true);
  apMode = false;
}

void startWifi() {
  WiFi.persistent(false);
  WiFi.mode(WIFI_STA);
  WiFi.setSleep(false);
  // Algunos routers usan WPA (no WPA2); por defecto el ESP32 los ignora.
  WiFi.setMinSecurity(WIFI_AUTH_WPA_PSK);
  // Motivo exacto de cada desconexión (código del estándar 802.11).
  WiFi.onEvent([](WiFiEvent_t e, WiFiEventInfo_t info) {
    Serial.printf("\n# router rechazo la conexion, motivo %d\n", info.wifi_sta_disconnected.reason);
  }, ARDUINO_EVENT_WIFI_STA_DISCONNECTED);
  if (loadNetworks().empty()) {
    logEvent("sin redes WiFi guardadas: esperando configuración");
    startPortal(0xFFFFFFFF / 2);  // sin redes: queda abierta hasta que se configure
    return;
  }
  for (int attempt = 1; attempt <= 2; attempt++) {
    if (connectBest(true)) {
      onConnected("");
      return;
    }
  }
  // Ninguna red conocida a la vista (p. ej. en el taxi): sigue grabando en la
  // SD y reintentando; la red de configuración queda abierta 10 minutos.
  logEvent("ninguna red guardada disponible al arrancar: graba sin internet y reintenta cada minuto");
  startPortal(10 * 60 * 1000UL);
}

// Vigila la WiFi (cada 10 s desde el bucle principal):
// - sin conexión, cada minuto busca las redes guardadas (p. ej. al llegar el
//   taxi a la casa del dueño) y se conecta a la mejor;
// - cierra la red de configuración al conectarse o al vencer su tiempo;
// - anota en el registro cuando se pierde o vuelve la conexión.
void wifiWatchdog(uint32_t now) {
  static uint32_t lastTry = 0, downSince = 0;
  static int wasConnected = -1;
  bool connected = WiFi.status() == WL_CONNECTED;
  if ((int)connected != wasConnected) {
    if (wasConnected == 1 && !connected) logEvent("WiFi perdido (estado %d): reconectando", WiFi.status());
    if (wasConnected == 0 && connected) onConnected(" (reconexión)");  // volvió sola
    wasConnected = connected;
  }
  // La red de configuración se cierra al vencer su tiempo (si hay redes guardadas).
  if (apMode && (int32_t)(now - portalUntil) > 0 && !loadNetworks().empty()) {
    closePortal();
    logEvent("red de configuración cerrada (se reabre manteniendo BOOT 3 s)");
  }
  if (connected) {
    downSince = 0;
    return;
  }
  if (!downSince) downSince = now;
  if (now - downSince > 20000 && now - lastTry > 60000) {
    lastTry = now;
    if (connectBest(false)) {
      onConnected(" (encontró una red guardada)");
      wasConnected = 1;
    }
  }
}

void setup() {
  Serial.begin(115200);
  delay(1500);
  // Hora de Ecuador desde el inicio: tras un reinicio por software el reloj
  // sigue en hora, pero sin esto se mostraba en UTC (5 h adelantada).
  setenv("TZ", "<-05>5", 1);
  tzset();
  bootReason = resetReason();
  // Historial de reinicios (sobrevive a los reinicios): para saber si las
  // desconexiones son por falta de corriente (brownout) o por un fallo.
  prefs.begin("taxiff", false);
  String key = String("rst") + (int)esp_reset_reason();
  prefs.putUInt(key.c_str(), prefs.getUInt(key.c_str(), 0) + 1);
  bootN = prefs.getUInt("bootn", 0) + 1;  // para corregir la hora de fotos tomadas sin internet
  prefs.putUInt("bootn", bootN);
  updateBootRec();  // el arranque queda anotado aunque se corte la corriente enseguida
  sinWifi = bootN <= prefs.getUInt("sinw", 0);  // prueba SINWIFI: hasta ese arranque
  bootHistory = "";
  for (int r = 0; r <= 15; r++) {
    uint32_t n = prefs.getUInt((String("rst") + r).c_str(), 0);
    if (n) bootHistory += String(bootHistory.length() ? ", " : "") + rstName(r) + " x" + n;
  }
  Serial.printf("# Arranque: %s | historial: %s\n", bootReason.c_str(), bootHistory.c_str());
  lock = xSemaphoreCreateMutex();
  redesLock = xSemaphoreCreateMutex();
  // La primera vez formatea la partición de 9 MB (tarda unos segundos).
  fatOk = FFat.begin(true);
  if (!fatOk) Serial.println("# ERROR: no se pudo abrir la memoria interna");
  // Tarjeta microSD (si hay): modo 1 bit, sin formatear nunca sola.
  // Con algunos cargadores la tarjeta tarda en estar lista al encender: se
  // reintenta antes de rendirse y usar la memoria interna.
  SD_MMC.setPins(SD_CLK, SD_CMD, SD_D0);
  for (int i = 0; i < 3 && !sdOk; i++) {
    if (i) {
      SD_MMC.end();
      delay(500);
    }
    sdOk = SD_MMC.begin("/sdcard", true, false) && SD_MMC.cardType() != CARD_NONE;
  }
  if (sdOk) {
    store = &SD_MMC;
    Serial.printf("# tarjeta SD: %.1f GB\n", SD_MMC.cardSize() / 1073741824.0);
  } else {
    Serial.println("# sin tarjeta SD: se usa la memoria interna (9 MB)");
  }
  if (storeOk()) store->mkdir("/fotos");
  freeKB = measureFreeKB();
  Serial.printf("# espacio libre para fotos: %u MB\n", (unsigned)(freeKB / 1024));
  logEvent("ARRANQUE: %s · firmware %s · %s", bootReason.c_str(), FW_VERSION,
           sdOk ? "con tarjeta SD" : "SIN TARJETA SD (guarda en la memoria interna)");
  if (sinWifi) logEvent("PRUEBA SIN WiFi: actúa como si no viera ninguna red (CONWIFI para terminar)");
  loadConfig();
  // Cuando se pierde una foto (WiFi, escritura en memoria, 640x480) la tarea
  // de la cámara imprime "EV-EOF-OVF" y su pila es tan pequeña que imprimir la
  // desborda y reinicia la placa. Perder una foto no importa: se silencia.
  esp_log_level_set("cam_hal", ESP_LOG_NONE);
  // Antes de encender la cámara: copiar puede tardar y, con la cámara andando,
  // nadie leería sus fotos mientras tanto (se desborda y reinicia la placa).
  if (sdOk) {
    queueInit();
    rescueInternal();
  }
  if (!initCamera()) Serial.println("# ERROR: no se pudo iniciar la camara");
  pinMode(0, INPUT_PULLUP);  // botón BOOT: mantenerlo 3 s abre la red de configuración
  startWifi();
  initAuth();
  startServer();
  startUploader();
}

// Comando por USB: "WIFI <red><TAB><clave>" guarda la WiFi y reinicia;
// "RESETLOG" borra el historial de reinicios.
void serialCommands() {
  static String line;
  while (Serial.available()) {
    char ch = Serial.read();
    if (ch != '\n') { if (line.length() < 200) line += ch; continue; }
    line.trim();
    if (line.startsWith("WIFI ")) {
      int tab = line.indexOf('\t');
      String ssid = line.substring(5, tab > 0 ? tab : line.length());
      String pass = tab > 0 ? line.substring(tab + 1) : "";
      addNetwork(ssid, pass);  // se suma a las que ya conoce
      logEvent("red WiFi agregada por cable: %s", ssid.c_str());
      Serial.printf("# WiFi guardada: %s. Reiniciando...\n", ssid.c_str());
      delay(500);
      ESP.restart();
    } else if (line == "REDES") {
      auto redes = loadNetworks();
      Serial.printf("# REDES guardadas: %d\n", (int)redes.size());
      for (auto &r : redes) Serial.printf("#   %s\n", r.ssid.c_str());
    } else if (line.startsWith("OLVIDAR ")) {
      removeNetwork(line.substring(8));
      Serial.printf("# red olvidada: %s\n", line.substring(8).c_str());
    } else if (line == "PORTAL") {  // igual que mantener BOOT 3 s
      if (!apMode) startPortal(10 * 60 * 1000UL);
    } else if (line == "SINWIFI" || line == "CONWIFI") {
      bool on = line == "SINWIFI";
      prefs.putUInt("sinw", on ? bootN + 3 : 0);
      Serial.printf("# %s. Reiniciando...\n", on ? "Prueba sin WiFi (3 arranques)" : "Fin de la prueba sin WiFi");
      delay(300);
      ESP.restart();
    } else if (line == "SDTEST") {
      sdSelfTest();
    } else if (line == "QHEX") {  // diagnóstico: primeros 64 bytes de la última foto de la cola, tal como están en la SD
      File f = qTail > qHead ? store->open(qPath(qTail - 1), "r") : File();
      uint8_t b[64];
      size_t n = f ? f.read(b, sizeof b) : 0;
      if (f) f.close();
      Serial.print("# QHEX ");
      for (size_t i = 0; i < n; i++) Serial.printf("%02x", b[i]);
      Serial.println(n ? "" : "(cola vacia)");
    } else if (line == "CLAVESD") {  // solo por cable: para descifrar la tarjeta en una PC (docs/SEGURIDAD.md)
      uint8_t k[16];
      if (prefs.getBytes("aesk", k, 16) == 16) {
        Serial.print("# CLAVESD ");
        for (int i = 0; i < 16; i++) Serial.printf("%02x", k[i]);
        Serial.println();
      } else {
        Serial.println("# CLAVESD (todavia no hay: se crea con la primera foto guardada)");
      }
    } else if (line == "SDFALLA") {  // prueba: la tarjeta deja de responder de golpe
      Serial.println("# SDFALLA: se desconecta la tarjeta; la siguiente escritura debe recuperarla");
      SD_MMC.end();
    } else if (line.startsWith("SERVER ")) {
      setServer(line.substring(7));
      Serial.printf("# servidor: %s\n", srvUrl.c_str());
    } else if (line == "LOG") {
      printLog();
    } else if (line == "SCAN") {
      esperarBusqueda();
      int n = WiFi.scanNetworks(false, true);
      Serial.printf("# SCAN: %d redes\n", n);
      for (int i = 0; i < n && i < 15; i++) {
        Serial.printf("#   %s  canal %d  %d dBm\n", WiFi.SSID(i).c_str(), WiFi.channel(i), WiFi.RSSI(i));
      }
    } else if (line == "RESETLOG") {
      for (int r = 0; r <= 15; r++) prefs.remove((String("rst") + r).c_str());
      Serial.println("# historial de reinicios borrado");
    }
    line = "";
  }
}

// Zona de la foto que ve el modelo, igual que al entrenar: con "Squash" la
// foto entera (aplastada a cuadrado); con "Fit shortest axis" el cuadrado
// central.
void modelArea(camera_fb_t *fb, int &ox, int &oy, int &aw, int &ah) {
#if EI_CLASSIFIER_RESIZE_MODE == EI_CLASSIFIER_RESIZE_SQUASH
  ox = 0; oy = 0; aw = fb->width; ah = fb->height;
#else
  aw = ah = min(fb->width, fb->height);
  ox = (fb->width - aw) / 2; oy = (fb->height - ah) / 2;
#endif
}

// Reduce esa zona de la foto RGB565 a la entrada del modelo (RGB888)
// promediando cada bloque (reducir sin promediar deja la imagen con ruido).
void toModelInput(camera_fb_t *fb) {
  int ox, oy, aw, ah;
  modelArea(fb, ox, oy, aw, ah);
  const uint8_t *src = fb->buf;
  for (int y = 0; y < EI_H; y++) {
    int y0 = oy + y * ah / EI_H, y1 = max(y0 + 1, oy + (y + 1) * ah / EI_H);
    for (int x = 0; x < EI_W; x++) {
      int x0 = ox + x * aw / EI_W, x1 = max(x0 + 1, ox + (x + 1) * aw / EI_W);
      uint32_t r = 0, g = 0, b = 0, cnt = 0;
      for (int yy = y0; yy < y1; yy++) {
        for (int xx = x0; xx < x1; xx++) {
          size_t i = 2 * (yy * fb->width + xx);
          uint16_t p = (src[i] << 8) | src[i + 1];  // RGB565 big-endian
          r += (p >> 11) << 3;
          g += ((p >> 5) & 0x3F) << 2;
          b += (p & 0x1F) << 3;
          cnt++;
        }
      }
      uint8_t *o = eiRgb + 3 * (y * EI_W + x);
      o[0] = r / cnt; o[1] = g / cnt; o[2] = b / cnt;
    }
  }
}

int eiGetData(size_t offset, size_t length, float *out) {
  for (size_t i = 0; i < length; i++) {
    const uint8_t *p = eiRgb + 3 * (offset + i);
    out[i] = (p[0] << 16) | (p[1] << 8) | p[2];
  }
  return 0;
}

// Cabezas con FOMO. Devuelve cuántas hay y agrega sus cajas (en píxeles de la
// foto) a `boxes`.
int detectPersons(camera_fb_t *fb, String &boxes) {
  if (!eiRgb) eiRgb = (uint8_t *)ps_malloc(EI_W * EI_H * 3);
  if (!eiRgb) return 0;
  toModelInput(fb);
  signal_t sig;
  sig.total_length = EI_W * EI_H;
  sig.get_data = &eiGetData;
  ei_impulse_result_t res = {0};
  if (run_classifier(&sig, &res, false) != EI_IMPULSE_OK) return 0;
  int ox, oy, aw, ah;
  modelArea(fb, ox, oy, aw, ah);
  float kx = (float)aw / EI_W, ky = (float)ah / EI_H;

  // Une detecciones de la misma cabeza: de la más segura a la menos, cada una
  // absorbe a las que tienen el centro cerca (en celdas FOMO de 8 px).
  struct Det { float x1, y1, x2, y2, v; bool used; };
  Det d[32];
  int m = 0;
  for (uint32_t i = 0; i < res.bounding_boxes_count && m < 32; i++) {
    auto &bb = res.bounding_boxes[i];
    if (bb.value < personThr) continue;
    d[m++] = {(float)bb.x, (float)bb.y, (float)(bb.x + bb.width), (float)(bb.y + bb.height), bb.value, false};
  }
  std::sort(d, d + m, [](const Det &a, const Det &b) { return a.v > b.v; });
  const float cell = 8, lim = mergeCells * cell;  // FOMO: 1 celda = 8 px de la entrada
  int n = 0;
  for (int i = 0; i < m; i++) {
    if (d[i].used) continue;
    Det g = d[i];
    for (int j = i + 1; j < m; j++) {
      if (d[j].used) continue;
      float dx = (d[j].x1 + d[j].x2 - g.x1 - g.x2) / 2, dy = (d[j].y1 + d[j].y2 - g.y1 - g.y2) / 2;
      if (dx * dx + dy * dy > lim * lim) continue;
      d[j].used = true;
      g.x1 = min(g.x1, d[j].x1); g.y1 = min(g.y1, d[j].y1);
      g.x2 = max(g.x2, d[j].x2); g.y2 = max(g.y2, d[j].y2);
    }
    if (n++) boxes += ",";
    boxes += "[" + String((int)(ox + g.x1 * kx)) + "," + String((int)(oy + g.y1 * ky)) + "," +
             String((int)(ox + g.x2 * kx)) + "," + String((int)(oy + g.y2 * ky)) + "," +
             String(g.v, 2) + "]";
  }
  return n;
}

void housekeeping(uint32_t now);

void loop() {
  static uint32_t lastT = 0, bootPressed = 0;
  serialCommands();
  if (apMode) dns.processNextRequest();  // portal cautivo
  revisarBusqueda();
  // Con Taxiff-Cam abierta y nadie conectado, la lista de redes se mantiene al
  // día: cuando el dueño entra ya está lista (sin tener que buscar con él conectado).
  if (apMode && !buscandoRedes && millis() - portalDesde > 3000 && WiFi.softAPgetStationNum() == 0 &&
      (!redesCuando || millis() - redesCuando > 30000)) {
    static uint32_t ultimoIntento = 0;
    if (millis() - ultimoIntento > 5000) {
      ultimoIntento = millis();
      buscarRedes();
    }
  }
  // BOOT mantenido 3 s: abre la red de configuración 10 minutos.
  if (digitalRead(0) == LOW) {
    if (!bootPressed) bootPressed = millis();
    else if (millis() - bootPressed > 3000 && !apMode) startPortal(10 * 60 * 1000UL);
  } else {
    bootPressed = 0;
  }
  if (restartPending) {
    logEvent("reinicio pedido (cambio de resolución)");
    delay(300);  // deja salir la respuesta de /set
    ESP.restart();
  }
  // Actualización en curso: el bucle se pausa (sin capturar ni procesar) para
  // dejarle el procesador. La cámara NO se apaga: apagarla deja al ESP32 sin
  // poder abrir conexiones nuevas hasta que se vuelve a encender.
  if (otaRequested) {
    camStopped = true;
    delay(100);
    return;
  }
  camStopped = false;
  if (reconfig) applyConfig();
  // Protección térmica: sobre 80 °C baja a ~2 fotos/s hasta enfriarse a 72 °C.
  if (hot) delay(400);
  uint32_t tCam = millis();
  camera_fb_t *fb = esp_camera_fb_get();
  if (!fb) {
    uint32_t t = millis();
    if (!camFailSince) {
      camFailSince = t;
      Serial.println("# la camara no envia imagen");
    } else if (t - camFailSince > 3000) {
      if (++camReinitsInRow > 3) {
        Serial.println("# la camara no revive: reiniciando la placa");
        logEvent("FALLO: la cámara no da imagen tras 3 reinicios: se reinicia la placa");
        delay(200);
        ESP.restart();
      }
      camReinits++;
      Serial.printf("# reiniciando la camara (%u)\n", camReinitsInRow);
      logEvent("la cámara dejó de dar imagen: reiniciándola (%u)", (unsigned)camReinitsInRow);
      esp_camera_deinit();
      delay(200);
      bool ok = initCamera();
      if (ok) reconfig = true;
      Serial.printf("# camara %s\n", ok ? "reiniciada" : "no responde (revisa el cable plano)");
      camFailSince = millis();
    }
    housekeeping(t);
    delay(100);
    return;
  }
  camFailSince = 0;
  camReinitsInRow = 0;

  uint32_t t0 = millis();
  String boxes = "[";
  int n = 0;
  if (detOn && usePersons) {
    n = detectPersons(fb, boxes);
  } else if (detOn) {
    std::list<dl::detect::result_t> &cand =
        s1->infer((uint16_t *)fb->buf, {(int)fb->height, (int)fb->width, 3});
    std::list<dl::detect::result_t> &res =
        s2.infer((uint16_t *)fb->buf, {(int)fb->height, (int)fb->width, 3}, cand);
    for (auto &r : res) {
      if (n++) boxes += ",";
      boxes += "[" + String(r.box[0]) + "," + String(r.box[1]) + "," + String(r.box[2]) +
               "," + String(r.box[3]) + "," + String(r.score, 2) + "]";
    }
  }
  detMs = millis() - t0;
  boxes += "]";
  uint32_t now = millis();
  updateTrip(n, now);

  uint8_t *jpg = nullptr;
  size_t len = 0;
  if (capNow || (capEvery && now - lastCap >= (uint32_t)capEvery * 1000)) {
    capNow = false;
    lastCap = now;
    capturePhoto(fb);
  }
  uint32_t t1 = millis();
  bool ok = frame2jpg(fb, jpegQ, &jpg, &len);
  esp_camera_fb_return(fb);
  uint32_t jpgMs = millis() - t1, loopMs = millis() - (lastT ? lastT : tCam);
  frames++;
  camAvg = camAvg * 0.9f + 0.1f * (t0 - tCam);
  detAvg = detAvg * 0.9f + 0.1f * detMs;
  jpgAvg = jpgAvg * 0.9f + 0.1f * jpgMs;
  busy = busy * 0.9f + 0.1f * min(100.0f, 100.0f * (detMs + jpgMs) / max<uint32_t>(1, loopMs));
  if (lastT) fps = fps * 0.9f + 0.1f * (1000.0f / max<uint32_t>(1, now - lastT));
  lastT = now;
  if (!ok) return;

  String det = "{\"b\":" + boxes + ",\"n\":" + String(n) + ",\"pax\":" + String(paxNow) +
               ",\"ms\":" + String(detMs) + ",\"fps\":" + String(fps, 1) +
               ",\"state\":" + String((int)state) +
               ",\"trip_s\":" + String(state == EN_CARRERA ? (now - tripStart) / 1000 : 0) +
               ",\"zero_s\":" + String(state == EN_CARRERA && zeroSince ? (now - zeroSince) / 1000 : 0) +
               ",\"max\":" + String(maxPax) + "}";
  xSemaphoreTake(lock, portMAX_DELAY);
  free(lastJpg);
  lastJpg = jpg;
  lastLen = len;
  lastDet = det;
  xSemaphoreGive(lock);
  housekeeping(now);
}

// Temperatura, ritmo de envío y línea de estado por USB. Corre también cuando
// la cámara no da imagen, para que la página siga mostrando datos reales.
void housekeeping(uint32_t now) {
  static uint32_t lastTemp = 0, lastInfo = 0;
  if (now - lastTemp > 2000) {
    temp = temperatureRead();
    tempMax = max(tempMax, temp);
    if (!hot && temp >= HOT_ON) { hot = true; logEvent("MUY caliente (%.0f C): baja el ritmo para enfriarse", temp); }
    if (hot && temp <= HOT_OFF) { hot = false; logEvent("temperatura normal otra vez (%.0f C)", temp); }
    sendKBs = sentBytes / 1024.0f / ((now - lastTemp) / 1000.0f);
    sentBytes = 0;
    lastTemp = now;
  }
  if (now - lastInfo > 10000) {
    lastInfo = now;
    if (storeOk()) freeKB = measureFreeKB();
    wifiWatchdog(now);
    static uint32_t lastLog = 0;
    if (!lastLog || now - lastLog > 60000) {  // estado en el registro cada minuto
      lastLog = now;
      updateBootRec();
      logEvent("estado: %s %d dBm · servidor '%s' · %u enviadas · %u en cola (%s, %u errores) · %.1f fps · %.0f C · RAM %u KB",
               WiFi.status() == WL_CONNECTED ? (apMode ? "WiFi ok + red de configuración" : "WiFi ok")
                                             : (apMode ? "SIN WiFi (red de configuración abierta)" : "WiFi caída"),
               WiFi.RSSI(), srvState, (unsigned)sentOk, (unsigned)queueSize(), sdOk ? "SD" : "interna",
               (unsigned)storeErrors, fps, temp,
               (unsigned)(ESP.getFreeHeap() / 1024));
    }
    Serial.printf("# %s · %s · %.1f fps · %.1f C · CPU %d%% · RAM %u KB · %s · cola %u en %s (errores %u)\n",
                  WiFi.status() == WL_CONNECTED ? WiFi.localIP().toString().c_str() : "AP 192.168.4.1",
                  camFailSince ? "SIN IMAGEN" : "camara ok", fps, temp,
                  (int)busy, ESP.getFreeHeap() / 1024, bootReason.c_str(), (unsigned)queueSize(),
                  sdOk ? "SD" : fatOk ? "memoria interna" : "NINGUNA", (unsigned)storeErrors);
  }
}
