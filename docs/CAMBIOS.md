# Registro de cambios

Lo más nuevo arriba. La seguridad y el cifrado se explican en detalle en [SEGURIDAD.md](SEGURIDAD.md).

---

## Firmware 4.2: subida estable con WiFi floja (cargado en la cámara y publicado)

**El problema:** al subir muchas fotos guardadas, el panel mostraba de a ratos "Conectada, pero no está enviando fotos".
- **Lo que pasaba:** los envíos se cortaban a mitad de camino (código -3). Cada lote podía pesar hasta 300 KB; con la señal de la casa (-60 a -68 dBm, ~33 KB/s) tardaba ~10 s y se cortaba.
- **Por qué se repetía:** después de cada envío bueno el lote se duplicaba hasta volver a fallar. Tras cada corte, la cámara esperaba 15 s.

**Cambios**
- **Lotes de hasta 96 KB** (antes 300 KB). El tamaño se ajusta a lo que tardó el envío anterior, apuntando a unos 3 s por envío.
- **Después de un corte, reintenta a los 3 s.** Solo tras más de 3 cortes seguidos espera 15 s.
- **Panel:** mientras sube lo guardado, una pausa de hasta 3 min se muestra como **"Subiendo fotos guardadas · reintentando"**, no como error. El aviso de "no está enviando fotos" queda para pausas de más de 3 min.
- **Registro:** una cola grande ya no cuenta como aviso, porque es normal al volver a tener internet. Solo cuenta si pasa de 6000 fotos.

## Firmware 4.1: página de la cámara con el estilo del panel

- **Mismo diseño que el panel**, en modo claro u oscuro.
- **En el celular:** una columna, y las secciones plegables (servidor, ajustes, temperatura, carreras, fotos de entrenamiento, sistema).
- **En la PC:** dos columnas.

## Panel: diseño para celular y PC

- **Visor:** la foto se agranda hasta llenar la pantalla, con un borde para que se vean las fotos de noche.
- **Detalle de carrera:** en el celular ocupa toda la pantalla, con el título y "Cerrar" siempre arriba.
- **Inicio:** "Últimas carreras" se muestra como tarjetas en el celular. Si un taxi no tiene fotos, dice "Todavía sin fotos" en vez de mostrar una imagen rota.
- **Filtros de Fotos:** más compactos.
- **Registro:** cada línea en 2 renglones y los contadores en una fila.
- **Versión en los archivos del panel**, para que el celular no siga mostrando el diseño viejo guardado en su memoria.

---

## Firmware 4.0 y servidor: carreras "por revisar" y fotos sin hora (probado y publicado)

**Problema 1 — fotos mezcladas en la galería**
- Algunas fotos viejas llegaban **sin ninguna hora**, porque la cuenta de los encendidos se cortaba si uno de ellos había durado tan poco que no alcanzó a anotarse.
- El servidor les ponía la hora de llegada, así que quedaban intercaladas con las fotos reales de ese momento y podían armar carreras falsas.

**Problema 2 — carreras falsas en la casa del dueño**
- Con WiFi, la cámara suele estar en la casa del dueño subiendo lo grabado, y la gente de la casa contaba como carrera.

**Cambios**
- **Cámara:**
  - un encendido sin anotar ya no corta la cuenta de la hora;
  - cada encendido se anota apenas arranca;
  - cada foto lleva la marca **"tomada con WiFi"** (un bit en el conteo de la cámara).
- **Servidor, fotos sin hora:** van al filtro **"Sin hora"** de la pestaña Fotos, con su hora de llegada. No se mezclan en la línea del tiempo ni cuentan para carreras.
- **Servidor, carreras con WiFi:** quedan **"por revisar"** y no cuentan. En la pestaña Carreras aparecen arriba, con **"Sí, fue una carrera"** / **"No era carrera"**. El inicio muestra cuántas hay por taxi.
- **Ajuste por taxi** (pestaña Ajustes): "El conductor usa internet en el taxi (hotspot)". Si se activa, esas carreras cuentan sin revisar.
- **Reanalizar un día conserva las decisiones** tomadas sobre carreras con WiFi.
- **Datos existentes:** 1625 fotos que estaban mezcladas (22 y 23 de octubre) pasaron a "sin hora", y se rearmaron las carreras de esos días.
  - El **22** quedó con **12** válidas; antes tenía **10**.
  - El **23** quedó con **2** válidas; antes tenía **6**.

---

## Firmware 3.9 (probado en la placa y publicado en el servidor)

**Probado el 23/10/2026:**
- **Desde la WiFi de la casa:** la página de la cámara da 401 (acceso negado) sin clave o con clave mala, y 200 con la clave.
- **Desde `Taxiff-Cam`:** la página de WiFi se abre sin clave. Todo lo demás, incluidas las pruebas de "¿hay internet?" de Android y de iPhone, va a la página de WiFi.
- **Cifrado:** en la tarjeta la foto está cifrada (`TXQ3`). `descifrar_sd.ps1` la recupera con la clave correcta y falla con una equivocada. La cámara la descifra y la sube sin errores.
- **Cola:** subieron las 1091 fotos atascadas, a unas 140 por minuto.

**Búsqueda de redes de la página de WiFi:** buscar redes apaga un momento la red `Taxiff-Cam` (el ESP32 tiene una sola radio), y el teléfono del dueño se desconectaba.
- Ahora la cámara busca en segundo plano, **solo cuando no hay ningún teléfono conectado**, cada 30 s.
- Cuando el dueño entra, la lista ya está lista.
- "Actualizar" igual busca, y avisa que el teléfono puede desconectarse un momento.
- Comando de diagnóstico `QHEX`: primeros bytes de la última foto de la cola, tal como están en la SD.

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
