# Pasar el servidor a internet

## Lo elegido (25/10/2026): la PC de la casa + `taxiff.site` con túnel fijo de Cloudflare

Oracle gratis no dio lugar en Bogotá (217 intentos en 2 días), así que el servidor sigue en la PC, pero con dirección fija:

```
Cámara / celular ──HTTPS──► taxiff.site (Cloudflare) ──túnel fijo──► esta PC (servidor Taxiff, puerto 8000)
```

| Pieza | Dónde | Qué hace |
|---|---|---|
| `servidor/.env` | Solo en la PC (no va a GitHub) | Clave del panel. Las cámaras nuevas quedan pendientes hasta aprobarlas |
| `despliegue/tunel_fijo.ps1` | Se corre una vez | Crea el túnel `taxiff` y apunta `taxiff.site` y `www` a esta PC |
| `despliegue/servidor_siempre.ps1` | Corre siempre | Mantiene prendidos el servidor y el túnel (si se caen, los levanta) y no deja que la PC se suspenda |
| `despliegue/instalar_arranque.ps1` | Se corre una vez | Tarea programada "Taxiff servidor": todo arranca solo al iniciar sesión en Windows (`-Quitar` la borra) |

**Requisitos:**
- La PC prendida, con sesión iniciada y con internet.
- Si se reinicia, hay que iniciar sesión para que todo arranque.
- Registro de lo que pasa: `servidor/datos/logs/siempre.log`.

El resto de este documento queda como referencia por si más adelante se pasa a un servidor en internet.

---

# Opciones de servidor en internet (referencia)

Plan para las pruebas con 1 o 2 taxis. Todavía **no se compró nada**: primero se elige la opción.

Los precios son de octubre de 2026 y varían según la fuente. **Confírmalos en la página del proveedor antes de pagar.**

---

## Qué necesita el servidor

- **Un programa que corre todo el día** (FastAPI). Recibe fotos, cierra carreras solo y borra fotos viejas cada hora.
- **Disco que no se borre:** fotos y base de datos.
  - Unos 15 KB por foto.
  - Una cámara manda, como mucho, unas 10 000 fotos por día: unos 150 MB.
  - Con 72 h guardadas, más la evidencia de las carreras, alcanzan unos pocos GB.
- **El modelo YOLO en CPU:** 2 núcleos y 4 GB de RAM alcanzan para 1 o 2 cámaras.

## Por qué no Vercel

Vercel es muy bueno para páginas web, pero **no sirve para este servidor**:

- **Es "serverless":** el programa se prende y se apaga solo con cada pedido. No puede quedarse corriendo para cerrar carreras o limpiar fotos.
- **No tiene disco que dure:** las fotos y la base de datos se perderían. Habría que pagar almacenamiento aparte y reescribir el servidor.
- **YOLO y PyTorch pesan mucho** para sus funciones y tardarían en arrancar en cada pedido.

Lo que sirve es un **VPS**: una computadora virtual en internet, prendida siempre, con su disco. Es como tu PC, pero en un centro de datos.

## Opciones

| Opción | Costo | A favor | En contra |
|---|---|---|---|
| **A. Hetzner (VPS)** | Unos €4–9 al mes. Un blog de oct-2026 dice ~€4,35 el CX22 (o €4,29 el CX23 que lo reemplaza); otro dice que tras la subida de abril-2026 cuesta ~€8,39 | Simple y confiable; buen rendimiento; se cobra por hora y se puede borrar cuando quieras | Hay que pagarlo con tarjeta |
| **B. Oracle Cloud "Always Free"** | $0 | Gratis para siempre: un servidor ARM. La documentación indexada dice 4 núcleos y 24 GB; artículos de 2026 dicen que bajó a 2 núcleos y 12 GB | Piden tarjeta para verificar; en algunas regiones no hay lugar ("Out of capacity"); es ARM (funciona, pero la instalación tarda más) |
| **C. Tu PC + dominio fijo** | Solo el dominio | Lo más barato; ya funciona | La PC tiene que quedar prendida, que es justo lo que quieres evitar |

**Recomendación para probar:** la **A (Hetzner)**, con un dominio y un túnel de Cloudflare.
- Si quieres $0, prueba primero la **B (Oracle)**.
- Si Oracle no da lugar o se complica, pasa a Hetzner.

## Dominio

| Dominio | Primer año | Renovación | Para qué |
|---|---|---|---|
| `.com` en Cloudflare | ~$10,46 (sube a ~$11,17 en noviembre de 2026) | Igual que el primer año | Para quedarse. Cloudflare cobra lo que le cuesta a él, sin recargo |
| `.xyz` (Porkbun, Spaceship) | ~$1 | ~$11–13 | Para una prueba barata ("momentáneo") |

- El dominio se maneja desde **Cloudflare (plan gratis)**: da HTTPS automático y el **túnel con nombre fijo**. Por ejemplo, `panel.tudominio.com` no cambia nunca, a diferencia de `trycloudflare.com`.
- Con un dominio comprado en otro lado, igual se puede: basta con apuntarlo a Cloudflare.

## Costo de una prueba de un mes

| | Hetzner | Oracle gratis |
|---|---|---|
| Servidor | ~€4–9 | $0 |
| Dominio `.xyz` (primer año) | ~$1 | ~$1 |
| Cloudflare (DNS, HTTPS, túnel) | $0 | $0 |
| **Total del primer mes** | **~$6–11** | **~$1** |

Para seguir con un `.com`, después: ~$10,46 al año más el servidor.

## Cómo quedaría

```
Cámara ──HTTPS──► Cloudflare (panel.tudominio.com) ──túnel cifrado──► VPS (servidor Taxiff + YOLO)
Tu celular / PC ──HTTPS──► el mismo dominio ──► panel
```

**Ventajas de la seguridad con el túnel:**
- El VPS **no abre ningún puerto a internet**: solo sale el túnel hacia Cloudflare.
- Nadie puede atacarlo directo.

## Pasos (cuando elijas)

1. **Compras el dominio** y lo agregas a Cloudflare (gratis).
2. **Creas el VPS** con Ubuntu 24.04 y me pasas el acceso SSH, o lo hacemos juntos.
3. **Lo instalo:**
   - Python, el servidor y el modelo;
   - un servicio que arranca solo si el VPS se reinicia;
   - el túnel con nombre fijo;
   - copias de seguridad de `datos/`.
4. **Le cambio la clave del panel** (`TAXIFF_CLAVE_PANEL`).
5. **Les pongo a las cámaras la dirección fija** (`https://panel.tudominio.com`), una sola vez y para siempre.
6. **Firmware con verificación del certificado:** la cámara comprueba que habla con tu servidor de verdad. Ver [SEGURIDAD.md](SEGURIDAD.md).
7. **Paso las fotos y carreras actuales** de tu PC al VPS, si quieres conservarlas.
