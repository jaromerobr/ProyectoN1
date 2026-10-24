# Seguridad y cifrado

Qué está protegido en Taxiff, cómo y quién puede ver qué. Vigente desde el **firmware 3.9**.

---

## 1. Quién puede ver qué

| Quién | Qué puede hacer | Cómo |
|---|---|---|
| **Empresa (tú)** | Todo: panel, fotos, carreras, registro, ajustes. En la cámara: imagen en vivo, ajustes y fotos | Panel: usuario `admin` y clave del panel. Cámara: usuario `admin` y la **clave de administración** |
| **Dueño del taxi** | Solo elegir la WiFi de la cámara | Conectado a la red `Taxiff-Cam`. Desde su WiFi de casa **no** puede abrir nada |
| **Cualquier otra persona** | Nada | Todo pide clave |

### Clave de administración de la cámara

- Está en `esp32/firmware/taxiff_cam/secretos.h`. Ese archivo **no se sube a GitHub** (está en `.gitignore`).
- La primera vez la crea sola `cargar_firmware.ps1`: 14 caracteres al azar.
- Se graba dentro del firmware, así que todas las cámaras cargadas desde esta PC usan la misma.
- `iniciar_pc.ps1 -Esp` la lee de ese archivo para pasarle a la cámara la dirección del servidor.
- **Guárdala en un lugar seguro.** Si pierdes el archivo y compilas de nuevo, se crea otra clave. Las cámaras con firmware viejo seguirán con la clave anterior hasta que las actualices.

**Para cambiarla:**
1. Borra `secretos.h`.
2. Ejecuta `cargar_firmware.ps1`, que crea una clave nueva.
3. Actualiza todas las cámaras, por cable o desde el panel.

### Qué pide clave en la cámara

| Página | Quién entra |
|---|---|
| `/` (imagen en vivo y ajustes), `/frame`, `/status`, `/set`, `/fotos`, `/foto` | Solo `admin` con clave |
| `/wifi`, `/redes`, `/save`, `/wifi_borrar` (configurar WiFi) | `admin` con clave, **o** un teléfono conectado a la red `Taxiff-Cam` |

**Cómo sabe la cámara si el pedido viene de `Taxiff-Cam`:** mira la dirección IP de quien pregunta. Si es de la red `192.168.4.x` (su red propia) y esa red está abierta, lo deja pasar.

Un teléfono en `Taxiff-Cam` que intenta abrir otra página es enviado a la página de WiFi; los demás ven el pedido de clave.

### Red `Taxiff-Cam`

- **Clave:** `taxiff123`, la misma en todas las cámaras.
- **Cuándo se abre:**
  - si la cámara no tiene redes guardadas;
  - si no encuentra ninguna de sus redes (10 min);
  - con el botón BOOT apretado 3 s (10 min).
- **Qué puede hacer quien se conecta:** solo agregar o quitar redes WiFi. No ve fotos ni cambia ajustes.
- **Pendiente:** una clave distinta por cámara, impresa en una etiqueta.

---

## 2. Cifrado

### Fotos en la tarjeta SD: AES-128-CTR

Las fotos que esperan subir (la cola, `/q/XXX/YYY.JPG`) se guardan **cifradas**. Si alguien saca la tarjeta, solo ve datos sin sentido.

| | |
|---|---|
| Algoritmo | AES-128 en modo CTR (mbedTLS, con aceleración por hardware del ESP32-S3) |
| Clave | 16 bytes al azar (`esp_fill_random`), **distinta en cada cámara** |
| Dónde está la clave | En la memoria interna de la cámara (NVS, clave `aesk`). **No** está en la tarjeta ni en el servidor |
| Contador inicial (nonce) | `[arranque (4 bytes) | ms desde el arranque (4 bytes) | 8 bytes en 0]`. Cada foto tiene el suyo y nunca se repite |
| Formato del archivo | Cabecera de 24 bytes, sin cifrar, y después el JPEG cifrado |

**La cabecera (24 bytes, little-endian):**

| Bytes | Campo |
|---|---|
| 0–3 | Marca: `TXQ3` = cifrada · `TXQ2` = sin cifrar (versiones anteriores) |
| 4–7 | Número de arranque |
| 8–15 | Hora en ms desde 1970 (0 = la cámara no sabía la hora) |
| 16–19 | ms desde que arrancó |
| 20–23 | Pasajeros que contó la cámara |

**Cómo se descifra en la cámara:** al subir cada foto, la cámara lee el archivo, la descifra en su memoria y la envía por HTTPS. En CTR, cifrar y descifrar son la misma operación: la función `cifrar()` del firmware.

**Fotos viejas:** las que quedaron sin cifrar (`TXQ2`) se siguen subiendo normal.

**Cómo descifrar una tarjeta en la PC** (por ejemplo, si la cámara se dañó):

```powershell
cd "C:\Users\ASUS Vivobook\Desktop\taxiff\esp32\herramientas"
.\camara.ps1 clavesd        # con la cámara conectada por cable: muestra la clave (32 caracteres)
.\descifrar_sd.ps1 -Tarjeta E:\ -Clave <la clave>
```

- Las fotos quedan en `fotos_descifradas`, con nombre `fecha_hora_Npax.jpg`.
- La clave solo se puede leer **por cable**, con la cámara en la mano. Anótala al instalar cada cámara si quieres poder recuperar sus tarjetas.
- Si se borra la memoria interna de la cámara, la clave se pierde y las fotos que no se subieron ya no se pueden recuperar.

### De la cámara al servidor: HTTPS (TLS)

- Fotos, registro y ajustes viajan **cifrados con HTTPS**. Nadie en la WiFi o en la red del celular puede verlos.
- Cada cámara se identifica con un **token** propio. El servidor guarda solo su hash, no el token.
- **Pendiente:** hoy la cámara **no comprueba el certificado** del servidor (`setInsecure`). Alguien con mucho acceso a la red podría hacerse pasar por el servidor. Se corrige cuando haya un **dominio fijo**: la cámara podrá comprobar el certificado, lo que hoy no se puede porque la dirección `trycloudflare.com` cambia cada vez.

### Panel web

- Por el túnel de Cloudflare, el panel va siempre por HTTPS.
- Pide usuario y clave (`admin` / `TAXIFF_CLAVE_PANEL`). **Cambia la clave por defecto `taxiff`** antes de usarlo fuera de casa: variable `TAXIFF_CLAVE_PANEL` en `servidor/.env`.

### Lo que todavía NO está cifrado

| Qué | Riesgo | Cómo se resolvería |
|---|---|---|
| Memoria interna de la cámara: claves WiFi, clave AES, token | Alguien con la cámara en la mano y herramientas podría leerla | *Flash encryption* del ESP32. Es **irreversible** (quema eFuses): solo para la versión final |
| Fotos de entrenamiento (`/fotos` de la cámara, desactivadas por defecto) | Se ven si se saca la tarjeta | Desactivadas por defecto; borrarlas después de usarlas |
| Fotos en el servidor | Quien entre al servidor las ve | Disco cifrado del proveedor, y acceso al servidor solo con llave SSH |
| Página de la cámara en la red local (HTTP) | La clave viaja sin cifrar dentro de esa WiFi | Usar el panel en vez de la página de la cámara. HTTPS en el ESP32 es posible pero pesado |
