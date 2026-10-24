# Registro de cambios

Lo más nuevo arriba. La seguridad y el cifrado se explican en detalle en [SEGURIDAD.md](SEGURIDAD.md).

---

## Firmware 3.9 (compilado, falta probarlo en la placa)

**Seguridad**
- **La página de la cámara pide clave.** Es la de imagen en vivo, ajustes y fotos. Usuario `admin` y la clave de `secretos.h`, que no se sube a GitHub y que `cargar_firmware.ps1` crea sola la primera vez.
- **El dueño del taxi solo puede elegir la WiFi**, y solo conectado a la red `Taxiff-Cam`. Desde su casa no puede abrir nada de la cámara.
- **Fotos cifradas en la tarjeta SD** (AES-128-CTR, con una clave propia de cada cámara). Si sacan la tarjeta, no se ven.
- **Comando `CLAVESD`** (`camara.ps1 clavesd`): muestra la clave de cifrado, solo por cable. Con ella, `descifrar_sd.ps1` recupera las fotos de una tarjeta en la PC.
- `iniciar_pc.ps1 -Esp` usa la clave para pasarle a la cámara la dirección del servidor.

**Página de WiFi nueva (la que ve el dueño)**
- Diseño para celular:
  - redes con barras de señal;
  - "Buscando redes…" animado mientras busca;
  - la red elegida se abre en una hoja desde abajo, con "Mostrar contraseña".
- **Aviso del último intento:** "Conectada a CASA" o "No se pudo conectar a CASA: revisa la contraseña".
- **Al guardar,** una pantalla clara de "Guardado" que explica qué pasa después.
- **Ya no tiene "Ver la cámara".**

## Firmware 3.8

- **Corregido:** con cientos de fotos guardadas de varios encendidos, la subida quedaba casi detenida. Para calcular la hora de cada foto, la cámara releía toda la cola por cada una. Ahora la lee una sola vez.

## Firmware 3.7

- **La tarjeta SD ya no falla en silencio.**
  - Al encender, intenta 3 veces.
  - Si deja de responder mientras funciona, la vuelve a conectar sola; si no puede, sigue en la memoria interna.
  - Al volver la tarjeta, le pasa lo guardado en la memoria interna.
- **Corregido un error grave:** si la SD fallaba un momento, la cámara creía que estaba llena y borraba la cola entera.
- **Hora de las fotos tomadas sin internet:**
  - la cámara anota cuánto dura cada encendido y calcula la hora hacia atrás;
  - las fotos quedan en orden, marcadas como "hora aproximada" (≈);
  - espera a tener la hora de internet antes de subirlas.
- **Comandos de prueba:**
  - `SINWIFI` / `CONWIFI` (`camara.ps1 sinwifi`): funciona como si no hubiera WiFi, hasta 3 encendidos;
  - `SDTEST` (`camara.ps1 probarsd`): prueba la tarjeta;
  - `SDFALLA`: desconecta la tarjeta a propósito, para pruebas.
- **La hora del registro** ya no sale 5 h adelantada después de un reinicio.
- **El rescate de la memoria interna** se hace antes de encender la cámara, porque copiar con la cámara andando la trababa.
- **`cargar_firmware.ps1`:**
  - escribe el firmware en los dos espacios;
  - exige la confirmación de todas las partes. Antes, una carga cortada se daba por buena y la placa arrancaba una versión vieja.

## Firmware 3.6

- **Varias redes WiFi** (hasta 5): se conecta a la de mejor señal.
- **Red `Taxiff-Cam` con portal cautivo** (la página se abre sola), y botón BOOT 3 s para abrirla.
- **Ritmo de fotos:**
  - 1 por segundo cuando cambia el número de pasajeros;
  - cada 4 s en carrera;
  - cada 15 s con la cabina vacía.

---

## Servidor y panel

**Pestaña Fotos**
- **Orden:** de temprano a tarde, o de tarde a temprano. También en el detalle de cada carrera. El panel recuerda la elección.

**Estado de la cámara en vivo**
- Arriba en cada taxi y en el inicio:
  - "Recibiendo fotos", con cuántas por minuto;
  - "Subiendo fotos guardadas · quedan N", con barra de avance;
  - "Conectada, pero no está enviando fotos";
  - "Sin conexión desde hace X".
- El servidor ahora cuenta **cualquier** contacto de la cámara, no solo las fotos.

**Carga más agradable**
- Las fotos muestran un brillo mientras cargan y aparecen suavemente.
- "Buscando fotos…" con un indicador que gira.
- El visor muestra el brillo hasta que llega la foto grande.

**Pestaña Registro**
- **Al tocar una línea se abre** con:
  - qué significa;
  - la posible causa;
  - qué hacer;
  - sus valores, con los malos en rojo;
  - las fotos de ese momento;
  - lo anotado justo antes y después.
- **"Qué revisar":** los problemas de las últimas 24 h con un consejo. Tocar uno filtra la lista.
- **Clasificación corregida:** muchas líneas normales salían como error. Al arrancar, el servidor reclasifica las viejas.

**Fotos sin hora**
- Si la cámara estima la hora (marca en el bit más alto), el servidor la respeta y la marca como aproximada.
- Antes se usaba la hora de llegada, y las fotos quedaban mezcladas.

**Ritmo y estado de las carreras**
- El ritmo de fotos se ajusta según la actividad.
- El estado de la carrera se guarda en la base: sobrevive a un reinicio del servidor.

**Pruebas automáticas:** 35, todas pasan.
