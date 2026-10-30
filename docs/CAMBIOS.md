# Registro de cambios

Lo más nuevo arriba. La seguridad y el cifrado se explican en detalle en [SEGURIDAD.md](SEGURIDAD.md).

---

## Arreglos en el detalle de una carrera (publicado el 28/10/2026)

- **Los km de la carrera no aparecían** en el detalle (solo decía "≈ km"). La cifra "gasto por km" de la pestaña Dinero usaba el mismo identificador y se quedaba con el valor. Ahora cada una tiene el suyo.
- **Mapa con GPS:**
  - el recorrido se centra en la parte del mapa que se ve siempre (antes, en el celular, un recorrido largo de norte a sur salía cortado en una esquina);
  - de fondo lleva una cuadrícula en vez de las calles de ejemplo, que no coincidían con el recorrido.

## Firmware 4.5: reloj DS3231 con pila (28/10/2026, cargado por USB en TX-4E1E98, aún no publicado)

- **Conexión:** módulo DS3231 (ZS-042) con 4 cables: VCC a **3V3**, GND a GND, SDA a **GPIO 41**, SCL a **GPIO 42**. 32K y SQW quedan sin conectar.
- **Al arrancar** la cámara toma la hora del reloj. Sin internet, las fotos y el registro ya salen con su hora y no hay que recalcularla después.
- **Cuando llega la hora de internet** se guarda en el reloj (en UTC). Así se corrige si se atrasó o si perdió la hora por quedarse sin pila.
- **Sin el módulo**, todo sigue igual que antes.
- **I2C:** se maneja a mano en esos dos pines, para no chocar con el I2C de la cámara.
- **Salida de 32 kHz:** se apaga, para gastar menos pila.
- **Dónde se ve el estado:** en la página de la cámara (línea de almacenamiento), en el registro y por el USB al arrancar.
- **Pila:** con VCC a 3V3 el circuito de carga del módulo prácticamente no carga la pila, así que una CR2032 común no corre riesgo. A 5V sí intentaría cargarla: ahí hace falta una LIR2032, o quitar la resistencia de carga.

## Página del dueño más fácil en el celular (publicado el 27/10/2026)

Varios dueños probaron la página y no sabían dónde tocar. Cambios, probados en un celular chico (360 px), en modo claro y oscuro:
- **Barra de abajo:** cada sección con su color (Inicio azul, Carreras verde, Dinero naranja, Taxi morado, Ajustes gris). Íconos y nombres más grandes; la sección elegida queda rellena con su color.
- **Título de color** arriba de cada sección, para saber dónde se está.
- **Letra y botones más grandes** en toda la página; los campos, a 16 px para que el celular no haga zoom al escribir.
- **Inicio:** se ven los 2 avisos más urgentes (rojos primero) y un botón "Ver N avisos más". El estado de la cámara sale solo en Inicio. En el celular, "Salir" queda arriba a la derecha.
- **Carreras:** el día se elige con un selector grande; la descarga para Excel pasa al final como botón.
- **Formularios más cortos:**
  - "Agregar chofer" queda plegado si ya hay choferes;
  - el odómetro pide solo los km (la fecha y la nota, en "Otra fecha o una nota");
  - la tarifa va en dos columnas.
- **Textos más cortos** en Turnos, Km vacíos, Velocidad y Calibración. Los gastos muestran los 5 últimos.

## Página del dueño: Dinero, pagos que vencen, informe Word y navegación más clara (publicado el 27/10/2026)

Se tomó como modelo el control en Excel que lleva un dueño de taxi en Loja: entrega diaria del chofer, gasolina, gastos, mantenimientos y resumen mensual. El préstamo del vehículo no se incluye: no es parte de Taxiff.

**Pestaña nueva "Dinero" (por mes)**
- **Arriba:** lo que entregaron los choferes, los gastos, **lo que queda** (en rojo si el taxi pierde plata) y el gasto por km.
- **Choferes:** la cuenta pactada × las jornadas trabajadas = lo que debía entregar, contra lo que entregó y lo que falta.
- **Gastos:**
  - botones rápidos (Gasolina, Aceite, Repuesto, Arreglo, Llantas, Lavado, Cooperativa, Otro);
  - fecha, detalle, lugar, forma de pago y odómetro;
  - "¿deja hecho un mantenimiento?": un gasto de aceite propone marcar hecho el cambio de aceite;
  - totales por grupo: Combustible, Mantenimiento y repuestos, Pagos fijos y trámites, Otros;
  - se muestran los 8 últimos, con "Ver todos".
- **Pagos que vencen:**
  - cooperativa, seguro, matrícula, revisión técnica, permiso de operación…, cada mes, cada año o una vez;
  - avisan 5 días antes en el Inicio, y en rojo si vencieron;
  - "Pagado" lo anota como gasto de hoy y pasa al próximo vencimiento.
- **Informe del mes (Word):** un .docx ordenado con:
  - el resumen ("este mes el taxi dejó o perdió $X");
  - los choferes y los gastos, por categoría y en detalle;
  - el día por día;
  - el mantenimiento (qué toca y cuánto falta);
  - los próximos pagos.

**Liquidación del día** (Carreras)
- Ahora tiene **"Te entregó ($)"**, el ingreso del dueño, comparado con la cuenta pactada ("faltan $5").
- Aparte, y opcional, **"Cobró en total"**: lo que dijo el chofer o la lectura del taxímetro.
- Se pliega en una línea: "Luis entregó $30 ✓ · Pedro: sin anotar".
- La **cuenta pactada** va en cada turno (Ajustes → Turnos). Si no hay turnos, hay una cuenta diaria del taxi.

**Más fácil de usar**
- **Barra de abajo con íconos y nombres:** Inicio, Carreras, Dinero, Taxi y Ajustes. La elegida va en azul con su ícono resaltado. Antes los botones casi no se veían.
- **Cada carrera** tiene al pie **"🗺️ Ver recorrido y detalle ›"**, y arriba de la lista hay una pista: "Toca una carrera para ver su recorrido en el mapa".
- "Kilometraje" pasa a llamarse **"Taxi"** (kilometraje, mantenimiento y km vacíos).

**Servidor:**
- tablas `gastos` y `recordatorios`;
- columnas `turnos.cuenta` y `reportes.entregado`;
- `python-docx` en `requirements.txt`;
- el informe se genera en `informe.py`.

**Pruebas automáticas:** 61, todas pasan. Las nuevas comprueban:
- los gastos y las validaciones;
- lo que deben los choferes y lo que queda;
- los pagos por fecha y su aviso;
- el gasto que deja hecho un mantenimiento;
- el informe Word.

---

## Firmware 4.3 y 4.4: redes WiFi de la cámara desde el panel

**Por qué `Taxiff-Cam` "solo sale una vez":** al guardar una red, la cámara se reinicia. Si encuentra esa WiFi, se conecta y ya no abre `Taxiff-Cam`, para que no quede una red visible todo el día en el taxi. Se vuelve a abrir:
- manteniendo BOOT 3 s;
- con `camara.ps1 portal`;
- ahora también desde el panel.

**Panel → taxi → Ajustes → "Redes WiFi de la cámara"**
- Muestra las redes que la cámara tiene guardadas y con cuál está conectada ahora.
- **Quitar** una red, con confirmación. Si es la única, o la que está en uso, avisa qué va a pasar. Se puede **Cancelar** mientras no se haya hecho.
- **Abrir Taxiff-Cam por 10 min** a distancia, sin tocar el botón. La cámara sigue enviando mientras está abierta.
- Las órdenes viajan con la respuesta al próximo envío de la cámara, así que necesita estar con internet.

**Cámara (4.3)**
- En cada envío informa sus redes guardadas (cabecera `X-Redes`, en formato URL) y la conectada (`X-Red`).
- Cumple las órdenes del panel:
  - **quitar la red en uso:** se desconecta y busca otra guardada;
  - **quitar la última:** deja `Taxiff-Cam` abierta hasta que la configuren.

**Cámara (4.4): corrección**
- **Problema:** con 4.3, quitar la red en uso dejaba a la cámara sin internet antes de poder avisar. El servidor repetía la orden y, si alguien volvía a agregar esa red, la cámara la quitaba otra vez.
- **Cambio:** ahora cada orden lleva un número. La cámara guarda el de la última que cumplió y lo informa siempre (`X-Wifi-Orden`), así el servidor no la repite.

**Probado en la placa con 4.3 (27/10/2026):**
- la cámara informó sus dos redes guardadas;
- abrió `Taxiff-Cam` desde el panel en 18 s;
- quitó las dos redes pedidas desde el panel y se quedó con `Taxiff-Cam` abierta.

**Pendiente:** cargar el 4.4 por cable (el USB se desconectó durante la carga) y después publicarlo en el servidor.

**Pruebas automáticas:** 58, todas pasan.

---

## Alertas de sabotaje, difuminar personas y pedido del odómetro (publicado el 26/10/2026)

**Cámara tapada**
- **Qué se mide:** cada foto guarda su **brillo** (de 0, negro, a 255).
- **Cuándo avisa:** si de día (de 7:00 a 17:59) llegan fotos casi negras (brillo menor a 18) y sin personas durante **10 minutos seguidos**, salta la alerta **"Cámara tapada u oscura de día"**.
- **De noche no avisa:** sin luz infrarroja, que todo esté negro es normal.
- **No se repite:** una misma racha avisa una sola vez.

**Carreras cortadas en ráfaga**
- 5 o más carreras descartadas (menos de 30 s) en una hora disparan **"Muchas carreras cortadas"**. Puede ser alguien que tapa y destapa la cámara, o algo en la cabina que confunde al detector.
- Avisa como mucho una vez cada 3 horas.

**Dónde se ven las alertas**
- En la página del dueño, en rojo y primero (las de los últimos 3 días).
- En el registro de la cámara ("ALERTA …").
- Se guardan en la tabla `alertas`.

**Difuminar a las personas** (panel del admin, sección **Privacidad**; viene **apagado**)
- Si se activa, cada persona detectada se desenfoca antes de guardar la foto en el servidor (Ley de Protección de Datos Personales).
- El conteo, la jaula y el reanálisis siguen funcionando, porque usan dónde estaba cada persona y no la imagen.
- **Costo:**
  - ya no se puede comprobar en la foto si era una persona;
  - esas fotos no sirven para entrenar el modelo. Las fotos de entrenamiento que guarda la cámara no cambian.
- Las fotos ya guardadas no cambian.

**Pedido del odómetro**
- Si no hay lectura, o la última es de hace más de 7 días, la página del dueño la pide al entrar.
- "Recordarme mañana" lo pospone 24 horas en ese celular.
- Al admin que mira la página del dueño no se le pide.

**Base de datos en modo WAL:** escribir no frena a quien lee.

**Lo que no se cambió, y por qué:**
- **YOLO ya no frena al servidor:** cada foto se analiza en otro hilo.
- **SQLite no se bloquea:** todo pasa por un solo proceso con un candado.
- **El límite real es la CPU:** unas 5 fotos por segundo, suficiente para unos 20 taxis. Más adelante: un servidor en la nube con más CPU, o contar en la cámara y mandar menos fotos.

**Pruebas automáticas:** 56, todas pasan. Usan fotos JPEG reales y comprueban que:
- el difuminado borra el detalle solo donde está la persona;
- la cámara tapada se detecta de día y no de noche;
- la ráfaga de carreras cortadas avisa una sola vez.

---

## Página del dueño: turnos, calibración con el taxímetro, carreras atípicas y km vacíos (publicado el 26/10/2026)

**Calibración con el taxímetro (antes "ajuste con lo reportado")**
- **El riesgo:** si los estimados se ajustaran con lo que dice el chofer, un chofer que reporta siempre de menos quedaría escondido.
- **Ahora cada liquidación dice de dónde sale el monto:**
  - **"Lo que dijo el chofer":** se compara con lo estimado y avisa si falta plata. **Nunca cambia los estimados.**
  - **"Lectura del taxímetro":** **solo esas** calibran la tarifa (tráfico, recorridos) si el dueño activa la calibración. Una lectura baja del taxímetro no genera aviso.
- **Para comparar,** la página muestra cuánto suele decir el chofer frente a la tarifa, sin corregir nada con eso.

**Turnos y choferes** (pestaña **Ajustes**, antes "Tarifa")
- El dueño carga los turnos, por ejemplo Luis de 6 a 18 y Pedro de 18 a 6. No pueden pisarse.
- **Un turno de noche que pasa la medianoche cuenta para el día en que empezó (su "jornada").** La carrera de las 2 a. m. es de la jornada de Pedro del día anterior.
- **Por chofer:**
  - en Carreras, una liquidación por turno, y cada carrera dice su chofer;
  - en el Resumen, el período separado por chofer;
  - en "Cuándo trabaja más", un filtro por chofer;
  - el aviso de liquidación baja dice de quién es;
  - el Excel trae la columna "chofer".

**Carreras atípicas**
- **Cuándo es atípica:** dura más de 40 min y más de 2,5 veces lo normal de ese taxi (mediana de los últimos 30 días).
- **Cómo se ve:** borde naranja y "atípica" en la tarjeta, y el día dice cuántas hay.
- **En el detalle:** explica por qué ("muy larga: lo normal es menos de X min").

**Km vacíos (antifraude)**
- En Kilometraje, entre cada par de lecturas del odómetro, se compara lo que marcó el odómetro con los km de las carreras que vio la cámara.
- Se muestra:
  - el **% con pasajeros**;
  - los **km vacíos**.
- **Avisos:**
  - menos del 35 % con pasajeros: "Muchos km vacíos". Puede ser uso personal, carreras con la cámara tapada o apagada, o mucho tiempo buscando clientes;
  - 30 km o más sin ninguna carrera: aviso rojo.

**Base de datos:** las liquidaciones pasan a ser por día y turno, con su fuente. Las que ya había se migran solas al arrancar, como "lo que dijo el chofer" y sin turno.

**Pruebas automáticas:** 53, todas pasan. Las nuevas comprueban:
- los turnos y las jornadas de noche;
- la calibración solo con el taxímetro;
- las carreras atípicas;
- los km vacíos.

**WhatsApp:** se queda el botón de compartir.
- No conviene pagar la API de WhatsApp Business todavía.
- No se usan librerías no oficiales (whatsapp-web.js, baileys): van contra las reglas de WhatsApp y suelen terminar con el número bloqueado.
- Para avisos automáticos, la opción gratis y oficial sería un bot de Telegram.

---

## Página del dueño: liquidación, avisos, mantenimiento y mejores horas (publicado el 26/10/2026)

**Liquidación del día** (pestaña Carreras)
- El dueño anota cuánto le reportó el chofer que cobró ese día. Taxiff lo compara con lo estimado:
  - "casi igual";
  - "13 % menos, dentro de lo normal (±20 %)";
  - "bastante menos de lo esperado: revisa las carreras de este día".
- En el resumen, "Últimos 7 días" muestra debajo del estimado lo que se reportó, en naranja si es mucho menos.

**Ajuste con lo reportado** (pestaña Tarifa)
- Con 3 días o más con liquidación, Taxiff calcula cuánto reporta el chofer comparado con la tarifa. Usa la mediana de los últimos 60 días, así que un día raro no la mueve.
- **Viene apagado.** Si el dueño lo activa, los estimados se corrigen con ese valor.
- **Por qué apagado:** si el chofer reportara siempre de menos, el ajuste escondería justo eso. Apagado, cada día se compara contra la tarifa y la diferencia se nota.

**Avisos** (arriba del resumen; al tocar uno, lleva a donde se resuelve)
- Un día con liquidación 20 % o más por debajo de lo estimado.
- Mantenimiento vencido, o a punto (menos de 300 km o del 10 %).
- "Ayer hubo pocas carreras": menos de la mitad de lo normal en las últimas 2 semanas.
- Cámara sin subir datos hace más de un día, o que nunca se conectó.
- Odómetro sin anotar hace más de un mes.

**Mantenimiento** (pestaña Kilometraje)
- Tareas con "cada X km" y "la última vez a los Y km", más sugerencias de un toque:
  - aceite cada 5.000 km;
  - filtro de aire cada 10.000 km;
  - llantas cada 10.000 km;
  - frenos cada 20.000 km.
- Muestra cuánto falta según el kilometraje estimado. "Hecho hoy" la anota al kilometraje estimado de hoy.

**Cuándo trabaja más** (resumen)
- Barras de los últimos 30 días, de dos formas:
  - por hora: carreras que empezaron en cada hora;
  - por día de la semana: promedio de carreras por día.
- Al tocar una barra se ve su detalle. Sin tocar nada, se muestra la mejor.

**Compartir por WhatsApp:** un botón arma el resumen del período elegido y abre WhatsApp (o el menú de compartir del celular). No usa ninguna API ni tiene costo.

**Servidor siempre encendido**
- **Problema:** al reiniciar el servidor, una vez tardó 5 minutos en volver. El lanzador del `.venv` quedó vivo con el servidor real ya muerto, y el supervisor solo miraba el lanzador.
- **Cambio:** `servidor_siempre.ps1` también revisa que haya alguien escuchando en el puerto. Si pasa 1 minuto sin nadie, reinicia.
- **Prueba:** al matar el servidor, volvió en 14 s.

**Pruebas automáticas:** 50, todas pasan. Las 3 nuevas comprueban:
- la liquidación y el ajuste;
- el mantenimiento;
- las mejores horas y el aviso de día flojo.

---

## Servidor: cuentas para los dueños de los taxis (publicado en taxiff.site el 26/10/2026)

**Para qué:** el dueño ve cuánto trabajó su taxi, pero no a los pasajeros. Ve sus carreras, cuánto se cobró más o menos, los km y su kilometraje, sin ninguna foto.

**Entrar**
- Página propia `/entrar` en vez de la ventanita del navegador. El administrador entra con `admin` y la clave del panel, y tiene **Salir** arriba.
- Cuentas de dueño: las crea el admin en el panel, sección **Dueños**. Ahí también:
  - asigna taxis (un dueño puede tener varios);
  - cambia la clave o desactiva la cuenta, lo que cierra sus sesiones abiertas;
  - abre **Ver su página**, para ver lo mismo que el dueño.
- La seguridad se explica en [SEGURIDAD.md](SEGURIDAD.md#panel-web).

**Página del dueño (`/dueno`)**
- **Estado de la cámara** en palabras simples: funcionando, poniéndose al día, sin conexión. También **"En carrera ahora"**, con cuántos van a bordo.
- **Resumen:** hoy, esta semana, este mes y desde el inicio. Muestra carreras, ≈ cobrado, ≈ km con pasajeros, tiempo con pasajeros y pasajeros.
- **Últimos 7 días:** tocar un día abre sus carreras.
- **Carreras de un día:** cada una con hora, duración, pasajeros, ≈ cobro y ≈ km, y quién subió y bajó.
  - Al tocarla, el detalle explica cómo se calculó el cobro.
  - Excel del mes, con el cobro y los km.
- **Las carreras por revisar no se le muestran:** solo ve cuántas están "en revisión".
- **Kilometraje:**
  - el dueño anota lo que marca el odómetro (la primera lectura es "desde que empezó");
  - Taxiff estima el kilometraje de hoy y calcula, de cada 10 km, cuántos son con pasajeros;
  - el odómetro no puede bajar: una lectura menor que una anterior se rechaza.
- **Tarifa:** de día y de noche (arranque, valor por km, mínima, horario) y velocidad promedio.
  - Trae valores de referencia de Loja, y cada dueño la ajusta a su taxímetro.
  - Muestra un ejemplo en vivo mientras se cambian los valores.

**Cómo se estima** (el ESP32 no tiene GPS)
- **Km de una carrera** = duración × velocidad promedio (18 km/h por defecto).
- **Cobro** = arranque + km × valor por km, nunca menos que la mínima. Es diurna o nocturna según la hora en que empezó.
- **Kilometraje de hoy** = última lectura + km con pasajeros desde entonces × factor.
  - El factor se calcula con dos lecturas separadas por 3 días o más.
  - Mientras no las haya, se usa 1,5: medio km vacío por cada km con pasajeros.

**El hueco del mapa (para cuando haya GPS)**
- El detalle de cada carrera tiene el lugar del mapa con el aviso "Recorrido: próximamente".
- Ya existe `POST /api/v1/posiciones` (`[[ts, lat, lon], …]`, con el token de la cámara) y la tabla `posiciones`.
- En cuanto lleguen puntos, sin cambiar nada más:
  - los km de esa carrera salen del recorrido real (se descartan los saltos de más de 150 km/h);
  - el mapa dibuja el recorrido, de la subida (verde) a la bajada (rojo).

**Admin**
- El Excel de todas las carreras trae también los km y el cobro estimados.

**Pruebas automáticas:** 47, todas pasan. Las 9 nuevas comprueban:
- que un dueño no ve taxis ajenos, ni el panel, ni fotos;
- las páginas según el rol;
- el bloqueo por intentos;
- que cambiar la clave cierra la sesión;
- las cuentas inválidas;
- la tarifa nocturna y la mínima;
- el odómetro;
- los km desde el GPS.

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
