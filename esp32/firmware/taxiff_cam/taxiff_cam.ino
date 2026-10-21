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
#include <Preferences.h>
#include <FFat.h>
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
static const uint32_t EXIT_GRACE_MS = 10000;
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

// Fotos para entrenar: se guardan en la memoria interna (FFat, 9 MB) cada
// `capEvery` segundos o al pulsar "Guardar foto", y la PC las descarga.
bool fatOk = false, capNow = false;
int capEvery = 0;
uint32_t capCount = 0, lastCap = 0;
const size_t CAP_MIN_FREE = 300 * 1024;

// Envío al servidor. Cada cámara se identifica con su ID de fábrica
// (TX-XXXXXX, de la MAC) y el token que el servidor le da al registrarse.
// Sin internet, las fotos se guardan en /q de la memoria interna y se suben
// después, las más viejas primero.
const char *FW_VERSION = "2.8";
char devId[12];
String srvUrl, devToken;
char srvState[64] = "sin servidor configurado";
volatile uint32_t srvInterval = 5000, sentOk = 0, sentErr = 0, lastSentMs = 0, queueCount = 0;
const size_t QUEUE_MIN_FREE = 600 * 1024;  // deja espacio a las fotos de entrenamiento
void setServer(String url);

// Actualización por internet: el servidor guarda el firmware más nuevo y la
// cámara lo instala sola. Mientras se descarga, el bucle principal se pausa.
volatile bool otaRequested = false, camStopped = false, otaHint = false;
const uint32_t OTA_CHECK_MS = 3600000;  // cada hora (y 1 min después de arrancar)
bool apMode = false;
String bootReason, bootHistory;

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
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Taxiff Cam</title><style>
:root{--bg:#0b0b0d;--card:#17171a;--mut:#9a9aa2;--acc:#ff9f0a;--ok:#30c26b}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:#f2f2f5;font:15px/1.4 system-ui,Segoe UI,Roboto,sans-serif}
header{padding:16px 20px;display:flex;gap:10px;align-items:center;flex-wrap:wrap}h1{font-size:20px;margin:0 8px 0 0}
.pill{padding:5px 12px;border-radius:999px;font-weight:800;font-size:13px;background:#2a2a2e}
main{display:grid;grid-template-columns:minmax(0,2fr) minmax(260px,1fr);gap:14px;padding:0 20px 20px}
@media(max-width:820px){main{grid-template-columns:1fr}}
.card{background:var(--card);border-radius:22px;padding:16px}canvas{width:100%;border-radius:14px;background:#000;display:block}
.k{display:grid;grid-template-columns:1fr 1fr;gap:12px}.k b{display:block;font-size:32px}.k span{color:var(--mut);font-size:13px}
table{width:100%;border-collapse:collapse;font-size:14px}td{padding:6px 4px;border-bottom:1px solid #2a2a2e}
.m{color:var(--mut);font-size:13px}#timer{font-size:44px;font-weight:300}
</style></head><body>
<header><h1>Taxiff Cam</h1><span id="st" class="pill">…</span><span class="m" id="net"></span></header>
<main><section class="card"><canvas id="v" width="640" height="480"></canvas>
<p class="m">Todo se calcula en el ESP32: detección, conteo y carreras. Modelo: <b id="mname">–</b></p></section>
<aside style="display:grid;gap:14px;align-content:start">
<div class="card"><div class="m">Carrera</div><div id="timer">00:00</div><div class="m" id="tdet"></div></div>
<div class="card k"><div><b id="n" style="color:var(--ok)">0</b><span>personas</span></div>
<div><b id="ms">–</b><span>ms detección</span></div><div><b id="fps">–</b><span>fps cámara</span></div>
<div><b id="tc">0</b><span>carreras</span></div></div>
<div class="card"><div class="m" style="margin-bottom:6px">Carreras guardadas</div><table id="tr"></table></div>
<div class="card"><div class="m" style="margin-bottom:8px">Ajustes de cámara y detección</div>
<div style="display:grid;grid-template-columns:1fr 1fr;gap:8px">
<label class="m">Resolución (reinicia)<br><select id="fs"><option value="qvga">320x240 (rápido)</option><option value="vga">640x480 (más alcance)</option></select></label>
<label class="m">Alcance del detector<br><select id="scale"><option value="0.2">Corto (rápido)</option><option value="0.3">Medio</option><option value="0.4">Largo</option><option value="0.5">Muy largo (lento)</option></select></label>
<label class="m">Calidad imagen<br><select id="q"><option value="40">Baja</option><option value="60">Media</option><option value="80">Alta</option></select></label>
<label class="m">Qué detecta<br><select id="model"><option value="personas">Cabezas (modelo propio)</option><option value="caras">Caras (Espressif)</option></select></label>
<label class="m">Unir detecciones cercanas<br><select id="mrg"><option value="0.0">No unir</option><option value="1.5">Poco</option><option value="2.5">Normal</option><option value="4.0">Mucho</option></select></label>
<label class="m">Sensibilidad cabezas<br><select id="pthr"><option value="0.30">Alta (cuenta más)</option><option value="0.40">Media-alta</option><option value="0.50">Normal</option><option value="0.65">Baja (menos errores)</option></select></label>
<label class="m">Detección en el ESP32<br><select id="det"><option value="1">Sí</option><option value="0">No (solo cámara)</option></select></label>
<label class="m">Orientación<br><select id="rot"><option value="0">Normal</option><option value="1">Girada 180°</option></select></label>
<label class="m">Modo noche<br><select id="night"><option value="0">No</option><option value="1">Sí</option></select></label>
</div></div>
<div class="card"><div class="m" style="margin-bottom:8px">Servidor Taxiff</div>
<div class="m">Esta cámara: <b id="devid">–</b></div>
<input id="srv" placeholder="Dirección del servidor (https…)" style="width:100%;margin:8px 0;padding:10px;border-radius:12px;border:1px solid #444;background:#0f0f12;color:#fff">
<button id="srvsave" style="padding:10px 16px;border-radius:12px;border:0;background:#ff9f0a;font-weight:800">Guardar servidor</button>
<div id="srvinfo" class="m" style="margin-top:8px"></div></div>
<div class="card"><div class="m" style="margin-bottom:8px">Fotos para entrenar el modelo</div>
<label class="m">Guardar automáticamente<br><select id="cap"><option value="0">No</option><option value="2">Cada 2 s</option><option value="5">Cada 5 s</option><option value="10">Cada 10 s</option></select></label>
<div style="display:flex;gap:8px;margin:10px 0"><button id="capnow" style="flex:1;padding:10px;border-radius:12px;border:0;background:#ff9f0a;font-weight:800">Guardar foto ahora</button>
<button id="capdel" style="padding:10px;border-radius:12px;border:1px solid #444;background:none;color:#f2f2f5">Borrar todas</button></div>
<div id="capinfo" class="m"></div></div>
<div class="card"><div class="m" style="margin-bottom:8px">Temperatura y carga</div><div id="met" class="m"></div></div>
<div class="card m" id="sys"></div></aside></main>
<script>
const v=document.getElementById('v'),c=v.getContext('2d');const $=i=>document.getElementById(i);
const two=x=>String(x).padStart(2,'0');const dur=s=>two(Math.floor(s/60))+':'+two(s%60);
async function frame(){try{const r=await fetch('/frame?'+Date.now());const d=JSON.parse(r.headers.get('X-Det')||'{}');
const img=await createImageBitmap(await r.blob());v.width=img.width*2;v.height=img.height*2;c.drawImage(img,0,0,v.width,v.height);
c.lineWidth=4;c.font='bold 22px system-ui';const k=v.width/img.width,fomo=$('model').value=='personas';
for(const[x1,y1,x2,y2,s]of d.b||[]){c.strokeStyle=c.fillStyle='#30c26b';const t='pasajero '+Math.round(s*100)+'%';let lx=x1*k,ly=y1*k;
// FOMO solo marca el centro de la cabeza (no su tamaño): se dibuja un punto.
if(fomo){const cx=(x1+x2)/2*k,cy=(y1+y2)/2*k;c.beginPath();c.arc(cx,cy,14,0,7);c.fill();c.beginPath();c.arc(cx,cy,26,0,7);c.stroke();lx=cx-26;ly=cy-30;}
else c.strokeRect(x1*k,y1*k,(x2-x1)*k,(y2-y1)*k);
const w=c.measureText(t).width+12;c.fillRect(lx,Math.max(0,ly-28),w,26);c.fillStyle='#000';c.fillText(t,lx+6,Math.max(20,ly-8));}
$('n').textContent=d.pax;$('ms').textContent=d.ms;$('fps').textContent=d.fps;
const st=['LIBRE','CONFIRMANDO','EN CARRERA'][d.state];$('st').textContent=st;$('st').style.background=d.state==2?'#1f3d2a':d.state==1?'#4a3a10':'#2a2a2e';
$('timer').textContent=dur(d.trip_s||0);$('tdet').textContent=d.state==2?(d.zero_s?('Sin pasajeros · cierra en '+Math.max(0,10-d.zero_s)+' s'):('máx. '+d.max+' pasajero(s)')):'Esperando pasajeros';
}catch(e){}setTimeout(frame,120)}
async function info(){try{const d=await (await fetch('/status')).json();$('tc').textContent=d.trips.length;
$('tr').innerHTML=d.trips.length?d.trips.slice().reverse().map(t=>`<tr><td>${t.inicio}</td><td>${dur(t.dur)}</td><td>${t.max} pax</td></tr>`).join(''):'<tr><td class="m">Aún no hay carreras</td></tr>';
$('net').textContent=d.net;$('sys').innerHTML=`Arranque: <b>${d.boot}</b><br>Reinicios: ${d.hist}<br>Encendido: ${dur(d.up)} · RAM libre ${d.heap} KB · PSRAM libre ${d.psram} KB<br>WiFi: ${d.rssi} dBm · descartadas: ${d.discarded}`;
const tc=d.temp>=80?'#f2453d':d.temp>=65?'#ff9f0a':'#30c26b';
const bar=(v,c)=>`<div style="height:8px;background:#2a2a2e;border-radius:4px;margin:4px 0 10px"><div style="height:8px;width:${Math.min(100,v)}%;background:${c};border-radius:4px"></div></div>`;
$('devid').textContent=d.id;if(document.activeElement!==$('srv'))$('srv').value=d.srv;
$('srvinfo').textContent=d.srv?`${d.srv_estado} · ${d.enviadas} fotos enviadas${d.ult_envio_s>=0?' (última hace '+d.ult_envio_s+' s)':''} · ${d.en_cola} en cola sin internet · ritmo ${d.intervalo_ms/1000} s`:'No envía a ningún servidor.';
$('mname').textContent=d.cfg.model=='caras'?'caras (Espressif)':d.modelo;
$('capinfo').textContent=`${d.fotos} fotos guardadas · espacio libre ${(d.fotos_libre_kb/1024).toFixed(1)} MB (≈ ${Math.floor(d.fotos_libre_kb/12)} fotos más)`;
$('met').innerHTML=(d.cam_ok?'':'<b style="color:#f2453d">LA CÁMARA NO ENVÍA IMAGEN: reiniciándola…</b><br>')+(d.cam_reinits?`Reinicios de cámara: ${d.cam_reinits}<br>`:'')+`Temperatura del chip: <b style="color:${tc};font-size:20px">${d.temp} °C</b> (máx. ${d.tmax} °C)${d.hot?' · <b style="color:#f2453d">MUY CALIENTE: va más lento para enfriarse</b>':''}${bar(d.temp,tc)}`+
`CPU ocupada: <b>${d.busy}%</b>${bar(d.busy,d.busy>85?'#ff9f0a':'#30c26b')}`+
`Por foto: cámara ${d.cam_ms} ms · detección ${d.det_ms} ms · JPEG ${d.jpg_ms} ms<br>Enviando a la PC: ${d.kbs} KB/s (≈ ${Math.round(d.kbs*3.6)} MB/hora) · ${d.fps} fps`;}catch(e){}setTimeout(info,2000)}
const KS=['fs','scale','q','night','det','model','pthr','mrg','rot','cap'];
$('srvsave').onclick=()=>fetch('/set?srv='+encodeURIComponent($('srv').value.trim())).then(()=>setTimeout(info,500));
$('capnow').onclick=()=>fetch('/set?capnow=1').then(()=>setTimeout(info,600));
$('capdel').onclick=()=>{if(confirm('¿Borrar todas las fotos guardadas en el ESP32?'))fetch('/foto?borrar=todas').then(()=>setTimeout(info,300));};
for(const k of KS)$(k).onchange=()=>fetch('/set?'+k+'='+$(k).value);
fetch('/status').then(r=>r.json()).then(d=>{for(const k of KS)$(k).value=k=='pthr'?d.cfg[k].toFixed(2):k=='mrg'?d.cfg[k].toFixed(1):String(d.cfg[k]);});
frame();info();
</script></body></html>)HTML";

static const char SETUP_PAGE[] PROGMEM = R"HTML(<!doctype html><html lang="es"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Taxiff Cam · WiFi</title>
<style>body{font:16px system-ui;background:#0b0b0d;color:#f2f2f5;padding:24px;max-width:420px;margin:auto}
input,button{width:100%;padding:14px;margin:8px 0;border-radius:14px;border:1px solid #333;background:#17171a;color:#fff;font-size:16px}
button{background:#ff9f0a;color:#000;font-weight:800;border:0}a{color:#ff9f0a}</style></head><body>
<h2>Conectar Taxiff Cam a internet</h2><p>Escribe la WiFi de la casa o el hotspot del teléfono.</p>
<form method="POST" action="/save"><input name="s" placeholder="Nombre de la red (SSID)" required>
<input name="p" type="password" placeholder="Contraseña"><button>Guardar y reiniciar</button></form>
<p><a href="/">Ver la cámara sin conectar a internet</a></p></body></html>)HTML";

esp_err_t handlePage(httpd_req_t *req) {
  httpd_resp_set_type(req, "text/html");
  return httpd_resp_send(req, PAGE, HTTPD_RESP_USE_STRLEN);
}

esp_err_t handleSetup(httpd_req_t *req) {
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

esp_err_t handleSave(httpd_req_t *req) {
  char buf[256] = {0};
  int len = httpd_req_recv(req, buf, min((size_t)req->content_len, sizeof(buf) - 1));
  if (len <= 0) return ESP_FAIL;
  String body(buf), ssid, pass;
  for (String part : {body.substring(0, body.indexOf('&')), body.substring(body.indexOf('&') + 1)}) {
    if (part.startsWith("s=")) ssid = urlDecode(part.substring(2));
    if (part.startsWith("p=")) pass = urlDecode(part.substring(2));
  }
  prefs.putString("ssid", ssid);
  prefs.putString("pass", pass);
  httpd_resp_set_type(req, "text/html");
  httpd_resp_sendstr(req, "<meta charset=utf-8><body style='font:18px system-ui;padding:24px'>"
                          "Guardado. La cámara se reinicia y se conecta a la red. "
                          "Vuelve a tu WiFi y abre <b>http://taxiff-cam.local</b></body>");
  delay(1500);
  ESP.restart();
  return ESP_OK;
}

esp_err_t handleFrame(httpd_req_t *req) {
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
             ",\"en_cola\":" + String(queueCount) +
             ",\"ult_envio_s\":" + String(lastSentMs ? (millis() - lastSentMs) / 1000 : -1) +
             ",\"intervalo_ms\":" + String(srvInterval) +
             ",\"fotos_libre_kb\":" + String(fatOk ? (unsigned)(FFat.freeBytes() / 1024) : 0) +
             ",\"net\":\"" + (apMode ? String("Red propia ") + AP_SSID : "WiFi " + WiFi.SSID() + " · " + WiFi.localIP().toString()) +
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

// /set?fs=qvga|vga|svga&scale=0.2&thr=0.1&q=60&night=1
esp_err_t handleSet(httpd_req_t *req) {
  char q[400] = {0}, v[16], sv[300];
  if (httpd_req_get_url_query_str(req, q, sizeof q) == ESP_OK) {
    // srv=<dirección del servidor> (vacía = no enviar).
    if (httpd_query_key_value(q, "srv", sv, sizeof sv) == ESP_OK) setServer(urlDecode(String(sv)));
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
    // cap=N: guarda una foto cada N segundos (0 = no); capnow=1: una ahora.
    if (httpd_query_key_value(q, "cap", v, sizeof v) == ESP_OK) capEvery = constrain(atoi(v), 0, 600);
    if (httpd_query_key_value(q, "capnow", v, sizeof v) == ESP_OK) capNow = true;
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
  String j = cfgJson();
  httpd_resp_set_type(req, "application/json");
  return httpd_resp_send(req, j.c_str(), j.length());
}

// /fotos: lista de fotos guardadas para entrenar, en JSON.
esp_err_t handlePhotos(httpd_req_t *req) {
  String j = "{\"ok\":" + String(fatOk ? 1 : 0) + ",\"free_kb\":" +
             String(fatOk ? (unsigned)(FFat.freeBytes() / 1024) : 0) + ",\"files\":[";
  int n = 0;
  if (fatOk) {
    File dir = FFat.open("/");
    for (File f = dir.openNextFile(); f; f = dir.openNextFile()) {
      String name = f.name();
      if (name.endsWith(".jpg")) j += String(n++ ? "," : "") + "\"" + name + "\"";
    }
  }
  j += "]}";
  httpd_resp_set_type(req, "application/json");
  return httpd_resp_send(req, j.c_str(), j.length());
}

// /foto?f=t00001.jpg descarga una; /foto?borrar=todas las borra.
esp_err_t handlePhoto(httpd_req_t *req) {
  char q[64] = {0}, v[40];
  if (!fatOk || httpd_req_get_url_query_str(req, q, sizeof q) != ESP_OK) return httpd_resp_send_404(req);
  if (httpd_query_key_value(q, "borrar", v, sizeof v) == ESP_OK) {
    // Formatear en vez de borrar archivo por archivo: también recupera el
    // espacio perdido si la placa se reinició a mitad de una escritura.
    int every = capEvery;
    capEvery = 0;
    fatOk = false;
    delay(300);  // deja terminar una captura en curso
    FFat.end();
    FFat.format();
    fatOk = FFat.begin(true);
    if (fatOk) FFat.mkdir("/q");  // también vacía la cola de envío
    queueCount = 0;
    capEvery = every;
    capCount = 0;
    prefs.putUInt("capn", 0);
    httpd_resp_set_type(req, "application/json");
    return httpd_resp_sendstr(req, "{\"borradas\":1}");
  }
  if (httpd_query_key_value(q, "f", v, sizeof v) != ESP_OK || strchr(v, '/')) return httpd_resp_send_404(req);
  File f = FFat.open(String("/") + v, "r");
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
  if (!fatOk || FFat.freeBytes() < CAP_MIN_FREE) {
    capEvery = 0;
    Serial.println("# memoria de fotos llena: captura detenida");
    return;
  }
  uint8_t *jpg = nullptr;
  size_t len = 0;
  if (!frame2jpg(fb, 90, &jpg, &len)) return;
  char name[20];
  snprintf(name, sizeof name, "/t%05u.jpg", (unsigned)++capCount);
  File f = FFat.open(name, "w");
  if (f) {
    f.write(jpg, len);
    f.close();
    prefs.putUInt("capn", capCount);
  }
  free(jpg);
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
  } else if (code == 409) {
    snprintf(srvState, sizeof srvState, "ya registrada: permite registrarla de nuevo en el panel");
  } else {
    snprintf(srvState, sizeof srvState, "no se pudo registrar (%d)", code);
  }
}

// Envía una foto. Devuelve true si el servidor la recibió (o no la quiere:
// cámara pendiente de aprobar), false si hay que guardarla para después.
bool postPhoto(const uint8_t *buf, size_t len, uint32_t ts, int n) {
  HTTPClient http;
  WiFiClientSecure sec;
  WiFiClient plain;
  if (!srvBegin(http, sec, plain, "/api/v1/foto")) return false;
  http.addHeader("Content-Type", "image/jpeg");
  http.addHeader("X-Dispositivo", devId);
  http.addHeader("Authorization", "Bearer " + devToken);
  http.addHeader("X-Ts", String(ts));
  http.addHeader("X-Conteo", String(n));
  http.addHeader("X-Temp", String(temp, 1));
  http.addHeader("X-Rssi", String(WiFi.RSSI()));
  http.addHeader("X-Fw", FW_VERSION);
  int code = http.POST((uint8_t *)buf, len);
  String body = code > 0 ? http.getString() : "";
  http.end();
  if (code == 200) {
    srvInterval = constrain(jsonNumber(body, "intervalo_ms", 5000), 500, 60000);
    // El servidor avisa cuál es el firmware más nuevo: si no es este, se revisa ya.
    int f = body.indexOf("\"firmware\":\"");
    if (f >= 0) {
      String latest = body.substring(f + 12, body.indexOf('"', f + 12));
      if (latest.length() && latest != FW_VERSION) otaHint = true;
    }
    sentOk++;
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

void enqueuePhoto(const uint8_t *buf, size_t len, uint32_t ts, int n) {
  if (!fatOk) return;
  // Memoria casi llena: se borra la foto más vieja de la cola.
  while (FFat.freeBytes() < QUEUE_MIN_FREE && queueCount > 0) {
    String oldest;
    File dir = FFat.open("/q");
    for (File f = dir.openNextFile(); f; f = dir.openNextFile()) {
      String name = f.name();
      if (!oldest.length() || name < oldest) oldest = name;
    }
    dir.close();
    if (!oldest.length() || !FFat.remove("/q/" + oldest)) break;
    queueCount--;
  }
  char name[40];
  snprintf(name, sizeof name, "/q/%010u_%u_%d.jpg", (unsigned)ts, (unsigned)(millis() % 1000), n);
  File f = FFat.open(name, "w");
  if (!f) return;
  f.write(buf, len);
  f.close();
  queueCount++;
}

// Sube la foto más vieja de la cola. false si no se pudo.
bool sendOldestQueued() {
  String oldest;
  File dir = FFat.open("/q");
  for (File f = dir.openNextFile(); f; f = dir.openNextFile()) {
    String name = f.name();
    if (!oldest.length() || name < oldest) oldest = name;
  }
  dir.close();
  if (!oldest.length()) {
    queueCount = 0;
    return true;
  }
  String path = "/q/" + oldest;
  File f = FFat.open(path, "r");
  size_t len = f ? f.size() : 0;
  uint8_t *buf = len ? (uint8_t *)ps_malloc(len) : nullptr;
  if (buf) f.read(buf, len);
  if (f) f.close();
  // Nombre: <hora>_<ms>_<conteo>.jpg
  uint32_t ts = oldest.substring(0, 10).toInt();
  int n = oldest.substring(oldest.lastIndexOf('_') + 1).toInt();
  bool ok = buf && postPhoto(buf, len, ts, n);
  free(buf);
  if (ok || !buf) {
    FFat.remove(path);
    if (queueCount) queueCount--;
  }
  return ok;
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
  const char *err = flashFromServer(path);
  // Solo se llega aquí si falló (si salió bien la placa ya se reinició).
  snprintf(srvState, sizeof srvState, "falló la actualización: %s", err);
  Serial.printf("# %s\n", srvState);
  otaRequested = false;  // el bucle principal sigue
}

// Tarea aparte (núcleo 0) para que enviar no frene la cámara ni la detección.
void uploadTask(void *) {
  uint32_t lastLive = 0, lastOta = millis() - OTA_CHECK_MS + 60000;
  for (;;) {
    vTaskDelay(pdMS_TO_TICKS(100));
    if (!srvUrl.length() || apMode) continue;
    bool online = WiFi.status() == WL_CONNECTED;
    if (online && !devToken.length()) {
      registerDevice();
      vTaskDelay(pdMS_TO_TICKS(devToken.length() ? 100 : 10000));
      continue;
    }
    // Revisión cada hora, o antes si el servidor avisó (como mucho cada 10 min,
    // para no reintentar sin parar si una actualización falla).
    if (online && devToken.length() &&
        (millis() - lastOta >= OTA_CHECK_MS || (otaHint && millis() - lastOta >= 600000))) {
      lastOta = millis();
      otaHint = false;
      checkFirmware();
    }
    // Ritmo: el que pide el servidor, o rápido si la cámara misma ve pasajeros.
    uint32_t every = (paxNow > 0 || state != LIBRE) ? 1000 : srvInterval;
    if (millis() - lastLive >= every) {
      lastLive = millis();
      xSemaphoreTake(lock, portMAX_DELAY);
      size_t len = lastLen;
      uint8_t *buf = lastJpg && len ? (uint8_t *)ps_malloc(len) : nullptr;
      if (buf) memcpy(buf, lastJpg, len);
      int n = paxNow;
      xSemaphoreGive(lock);
      if (buf) {
        uint32_t ts = (uint32_t)nowEpoch();  // 0 = sin hora: el servidor usa la de llegada
        if (!online || !devToken.length() || !postPhoto(buf, len, ts, n)) enqueuePhoto(buf, len, ts, n);
        free(buf);
      }
      continue;
    }
    // Entre fotos en vivo se va vaciando la cola.
    if (online && devToken.length() && queueCount > 0 && !sendOldestQueued()) {
      vTaskDelay(pdMS_TO_TICKS(3000));
    }
  }
}

void startUploader() {
  uint64_t mac = ESP.getEfuseMac();
  snprintf(devId, sizeof devId, "TX-%02X%02X%02X", (uint8_t)(mac >> 24), (uint8_t)(mac >> 32), (uint8_t)(mac >> 40));
  srvUrl = prefs.getString("srv", "");
  devToken = prefs.getString("tok", "");
  if (srvUrl.length()) snprintf(srvState, sizeof srvState, "conectando…");
  if (fatOk) {
    FFat.mkdir("/q");
    File dir = FFat.open("/q");
    for (File f = dir.openNextFile(); f; f = dir.openNextFile()) queueCount++;
    dir.close();
  }
  Serial.printf("# camara %s · servidor: %s · %u fotos en cola\n", devId,
                srvUrl.length() ? srvUrl.c_str() : "(ninguno)", (unsigned)queueCount);
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
  cfg.max_uri_handlers = 12;
  cfg.stack_size = 8192;
  if (httpd_start(&server, &cfg) != ESP_OK) return;
  httpd_uri_t uris[] = {
      {"/", HTTP_GET, handlePage, nullptr},
      {"/frame", HTTP_GET, handleFrame, nullptr},
      {"/status", HTTP_GET, handleStatus, nullptr},
      {"/wifi", HTTP_GET, handleSetup, nullptr},
      {"/save", HTTP_POST, handleSave, nullptr},
      {"/set", HTTP_GET, handleSet, nullptr},
      {"/fotos", HTTP_GET, handlePhotos, nullptr},
      {"/foto", HTTP_GET, handlePhoto, nullptr},
  };
  for (auto &u : uris) httpd_register_uri_handler(server, &u);
}

void startWifi() {
  String ssid = prefs.getString("ssid", ""), pass = prefs.getString("pass", "");
  if (ssid.length()) {
    WiFi.mode(WIFI_STA);
    WiFi.setSleep(false);
    // Algunos routers usan WPA (no WPA2); por defecto el ESP32 los ignora.
    WiFi.setMinSecurity(WIFI_AUTH_WPA_PSK);
    // Motivo exacto de cada desconexión (código del estándar 802.11).
    WiFi.onEvent([](WiFiEvent_t e, WiFiEventInfo_t info) {
      Serial.printf("\n# router rechazo la conexion, motivo %d\n",
                    info.wifi_sta_disconnected.reason);
    }, ARDUINO_EVENT_WIFI_STA_DISCONNECTED);
    // Redes con varios puntos de acceso (malla, 2,4 + 5 GHz): se busca la red
    // y se conecta al punto de 2,4 GHz con mejor señal. Hasta 3 intentos.
    for (int attempt = 1; attempt <= 3 && WiFi.status() != WL_CONNECTED; attempt++) {
      int best = -1;
      int n = WiFi.scanNetworks();
      for (int i = 0; i < n; i++) {
        if (WiFi.SSID(i) == ssid && (best < 0 || WiFi.RSSI(i) > WiFi.RSSI(best))) best = i;
      }
      if (best >= 0) {
        Serial.printf("# Conectando a %s (canal %d, %d dBm, seguridad %d), intento %d", ssid.c_str(),
                      WiFi.channel(best), WiFi.RSSI(best), (int)WiFi.encryptionType(best), attempt);
        WiFi.begin(ssid.c_str(), pass.c_str(), WiFi.channel(best), WiFi.BSSID(best));
      } else {
        Serial.printf("# %s no aparece en la busqueda, intento %d", ssid.c_str(), attempt);
        WiFi.begin(ssid.c_str(), pass.c_str());
      }
      for (int i = 0; i < 30 && WiFi.status() != WL_CONNECTED; i++) {
        delay(500);
        Serial.print(".");
      }
      Serial.println();
      if (WiFi.status() != WL_CONNECTED) {
        Serial.printf("# intento %d fallido, estado %d\n", attempt, WiFi.status());
        WiFi.disconnect();
        delay(500);
      }
    }
  }
  if (WiFi.status() == WL_CONNECTED) {
    MDNS.begin("taxiff-cam");
    configTzTime("<-05>5", "pool.ntp.org", "time.google.com");  // hora de Ecuador
    Serial.printf("# WiFi OK: abre http://%s o http://taxiff-cam.local\n",
                  WiFi.localIP().toString().c_str());
  } else {
    if (ssid.length()) {
      // Diagnóstico: por qué no conectó y qué redes ve el ESP32.
      int st = WiFi.status();
      Serial.printf("# No conecto a %s. Estado %d (%s)\n", ssid.c_str(), st,
                    st == WL_NO_SSID_AVAIL ? "no ve la red" :
                    st == WL_CONNECT_FAILED ? "clave incorrecta o rechazada" :
                    st == WL_DISCONNECTED ? "desconectado (clave incorrecta?)" : "otro");
      int n = WiFi.scanNetworks();
      for (int i = 0; i < n && i < 12; i++) {
        Serial.printf("#   red: %s  canal %d  %d dBm  %s\n", WiFi.SSID(i).c_str(),
                      WiFi.channel(i), WiFi.RSSI(i),
                      WiFi.encryptionType(i) == WIFI_AUTH_OPEN ? "abierta" : "con clave");
      }
    }
    apMode = true;
    WiFi.mode(WIFI_AP);
    WiFi.softAP(AP_SSID, AP_PASS);
    Serial.printf("# Sin WiFi: conectate a la red %s (clave %s) y abre http://192.168.4.1/wifi\n",
                  AP_SSID, AP_PASS);
  }
}

void setup() {
  Serial.begin(115200);
  delay(1500);
  bootReason = resetReason();
  // Historial de reinicios (sobrevive a los reinicios): para saber si las
  // desconexiones son por falta de corriente (brownout) o por un fallo.
  prefs.begin("taxiff", false);
  String key = String("rst") + (int)esp_reset_reason();
  prefs.putUInt(key.c_str(), prefs.getUInt(key.c_str(), 0) + 1);
  bootHistory = "";
  for (int r = 0; r <= 15; r++) {
    uint32_t n = prefs.getUInt((String("rst") + r).c_str(), 0);
    if (n) bootHistory += String(bootHistory.length() ? ", " : "") + rstName(r) + " x" + n;
  }
  Serial.printf("# Arranque: %s | historial: %s\n", bootReason.c_str(), bootHistory.c_str());
  lock = xSemaphoreCreateMutex();
  // La primera vez formatea la partición de 9 MB (tarda unos segundos).
  fatOk = FFat.begin(true);
  if (!fatOk) Serial.println("# ERROR: no se pudo abrir la memoria de fotos");
  Serial.printf("# memoria de fotos: %u KB libres\n", fatOk ? (unsigned)(FFat.freeBytes() / 1024) : 0);
  loadConfig();
  // Cuando se pierde una foto (WiFi, escritura en memoria, 640x480) la tarea
  // de la cámara imprime "EV-EOF-OVF" y su pila es tan pequeña que imprimir la
  // desborda y reinicia la placa. Perder una foto no importa: se silencia.
  esp_log_level_set("cam_hal", ESP_LOG_NONE);
  if (!initCamera()) Serial.println("# ERROR: no se pudo iniciar la camara");
  startWifi();
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
      prefs.putString("ssid", ssid);
      prefs.putString("pass", pass);
      Serial.printf("# WiFi guardada: %s. Reiniciando...\n", ssid.c_str());
      delay(500);
      ESP.restart();
    } else if (line.startsWith("SERVER ")) {
      setServer(line.substring(7));
      Serial.printf("# servidor: %s\n", srvUrl.c_str());
    } else if (line == "SCAN") {
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
  static uint32_t lastT = 0;
  serialCommands();
  if (restartPending) {
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
        delay(200);
        ESP.restart();
      }
      camReinits++;
      Serial.printf("# reiniciando la camara (%u)\n", camReinitsInRow);
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
    if (!hot && temp >= HOT_ON) hot = true;
    if (hot && temp <= HOT_OFF) hot = false;
    sendKBs = sentBytes / 1024.0f / ((now - lastTemp) / 1000.0f);
    sentBytes = 0;
    lastTemp = now;
  }
  if (now - lastInfo > 10000) {
    lastInfo = now;
    Serial.printf("# %s · %s · %.1f fps · %.1f C · CPU %d%% · RAM %u KB · %s\n",
                  apMode ? "AP 192.168.4.1" : WiFi.localIP().toString().c_str(),
                  camFailSince ? "SIN IMAGEN" : "camara ok", fps, temp,
                  (int)busy, ESP.getFreeHeap() / 1024, bootReason.c_str());
  }
}
