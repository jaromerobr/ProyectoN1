# Guía rápida: levantar el servidor y conectar la cámara

Todo se escribe en **PowerShell**. En VS Code: *Terminal → New Terminal*.
Las rutas son de esta PC (`C:\Users\ASUS Vivobook\Desktop\taxiff`). En otra PC, cámbialas por donde esté el repositorio.

---

## 1. Levantar el servidor

```powershell
cd "C:\Users\ASUS Vivobook\Desktop\taxiff\servidor"
powershell -ExecutionPolicy Bypass -File .\iniciar_pc.ps1 -Tunel
```

A los ~15 segundos aparece:

```
Servidor:  http://localhost:8000   (en la misma WiFi: http://192.168.x.x:8000)
Pública:   https://palabras-al-azar.trycloudflare.com
Ctrl+C para detener.
```

- **Copia la dirección `Pública`.** Es la que usa la cámara, y cambia cada vez que arrancas.
- **No cierres esa terminal.** Cerrarla o presionar `Ctrl+C` apaga el servidor y el túnel.
- **Panel:** http://localhost:8000. Usuario `admin`, clave `taxiff`. Desde el celular, abre la dirección `Pública`.

> **Primera vez en otra PC:** antes hay que crear el entorno de Python. Ver [servidor/README.md](../servidor/README.md#probar-en-la-pc).

---

## 2. Conectar la cámara a una WiFi (por cable, lo más fácil)

1. Conecta la cámara a la PC por el puerto **UART** de la placa (no el OTG).
2. Abre **otra** terminal (la del servidor sigue abierta) y entra a la carpeta de herramientas:

```powershell
cd "C:\Users\ASUS Vivobook\Desktop\taxiff\esp32\herramientas"
```

3. Ve qué redes ve la cámara. Solo puede usar redes de **2.4 GHz**:

```powershell
powershell -ExecutionPolicy Bypass -File .\camara.ps1 redes
```

4. Conéctala. Escribe el nombre de la red **exactamente** como aparece en la lista:

```powershell
powershell -ExecutionPolicy Bypass -File .\camara.ps1 wifi "NOMBRE_RED" 'CLAVE'
```

> Escribe la clave entre comillas **simples** (`'…'`). Si la clave lleva `$`, con comillas dobles PowerShell la cambia.

Al final dice `CONECTADA. IP de la cámara: 192.168.x.x`. Esa es su página: `http://192.168.x.x`.

### Sin cable (desde el celular)

Si la cámara no encuentra ninguna red conocida, a los 1–2 minutos crea su propia red:

1. En el celular, conéctate a la red **`Taxiff-Cam`** (clave `taxiff123`).
2. Abre **http://192.168.4.1/wifi**.
3. Escribe la red y la clave, y guarda. La cámara se reinicia y se conecta.

`192.168.4.1` **solo funciona** mientras estés conectado a la red `Taxiff-Cam`.

---

## 3. Saber la IP de la cámara

| Cómo | Comando o lugar |
|---|---|
| Por cable | `powershell -ExecutionPolicy Bypass -File .\camara.ps1 ip` |
| Por nombre (misma red) | http://taxiff-cam.local |
| Hotspot del celular | *Ajustes → Zona Wi-Fi → Dispositivos conectados* → `esp32s3-…` |
| Router de la casa | Lista de dispositivos conectados → `esp32s3-…` |

La PC o el celular tienen que estar **en la misma red** que la cámara para abrir su página.

---

## 4. Decirle a la cámara a dónde enviar las fotos

Usa la dirección **`Pública`** del paso 1. Hay dos formas:

**Por cable:**

```powershell
powershell -ExecutionPolicy Bypass -File .\camara.ps1 servidor "https://palabras-al-azar.trycloudflare.com"
```

**Desde su página:** abre `http://<ip-de-la-cámara>`, ve a la sección **Servidor Taxiff**, pega la dirección y presiona **Guardar servidor**.

En unos segundos la cámara dice **"conectada"** y aparece en el panel.

**Atajo:** si ya sabes la IP de la cámara, arranca el servidor así y la configura sola:

```powershell
powershell -ExecutionPolicy Bypass -File .\iniciar_pc.ps1 -Tunel -Esp 192.168.x.x
```

---

## 5. Probar en el taxi

1. En la PC: paso 1 (servidor con `-Tunel`). La PC puede quedarse en casa con internet.
2. Celular en **hotspot de 2.4 GHz**.
3. Cámara: paso 2 con la red del hotspot, y paso 4 con la dirección `Pública`.
4. Alimenta la cámara con un cargador de auto o power bank de **2 A o más** y un cable corto y bueno.
5. En el panel, desde el celular con la dirección `Pública`:
   - abre el taxi;
   - **dibuja la jaula** (las esquinas de la cabina);
   - mira el conteo y las carreras.

Si la cámara pierde internet, guarda las fotos y las sube cuando vuelve.

---

## 6. Cargar un firmware nuevo en la cámara

**Por cable** (compila y carga):

```powershell
cd "C:\Users\ASUS Vivobook\Desktop\taxiff\esp32\herramientas"
powershell -ExecutionPolicy Bypass -File .\cargar_firmware.ps1
```

**Por internet** (todas las cámaras a la vez):

1. Sube el número en `FW_VERSION` de `esp32/firmware/taxiff_cam/taxiff_cam.ino`, por ejemplo de `"2.8"` a `"2.9"`.
2. Compila:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\cargar_firmware.ps1 -SoloCompilar
   ```
3. En el panel, sección **Firmware de las cámaras**, escribe la versión, elige `build_esp32\taxiff_cam.ino.bin` y presiona **Subir firmware**. Las cámaras se actualizan solas en menos de un minuto.

---

## 7. Ver qué está pasando en la cámara

```powershell
powershell -ExecutionPolicy Bypass -File .\camara.ps1 mensajes 30
```

Muestra lo que dice la cámara durante 30 s: conexión, fotos por segundo, temperatura, envíos y errores.

---

## 8. Problemas frecuentes

| Problema | Qué hacer |
|---|---|
| `camara.ps1` dice "No hay ninguna cámara conectada" | Usa el puerto **UART**. Prueba otro cable USB (muchos solo cargan) u otro puerto de la PC. |
| No conecta: "no encuentra la red" | La red es solo de 5 GHz o el nombre está mal. Mira `camara.ps1 redes`. En el celular, pon el hotspot en 2.4 GHz. |
| No conecta: "clave incorrecta" | Revisa la clave. Escríbela con comillas simples `'…'`. |
| No abre `192.168.4.1` | Solo funciona conectado a la red `Taxiff-Cam`, y solo si la cámara no encontró ninguna red conocida. |
| No abre `http://<ip-de-la-cámara>` | La PC o el celular tienen que estar en la misma red que la cámara. Usa `camara.ps1 ip`. |
| La cámara dice "sin internet" | El servidor está apagado, o cambió la dirección del túnel. Repite los pasos 1 y 4. |
| La cámara se reinicia o se desconecta sola | Casi siempre es la alimentación. Usa un cargador de 2 A o más y un cable corto. Mira `camara.ps1 mensajes`. |
| El panel no carga | ¿Está abierta la terminal del paso 1? Ábrelo en http://localhost:8000. |
| Al cambiar de WiFi la PC | Cambia la IP de la PC. Usa siempre `-Tunel`, que no depende de la red. |

---

## 9. Guardar cambios en GitHub

Git está instalado en versión portátil. Desde la carpeta del proyecto:

```powershell
cd "C:\Users\ASUS Vivobook\Desktop\taxiff"
$git = "$env:LOCALAPPDATA\Programs\MinGit\cmd\git.exe"
& $git add -A
& $git commit -m "Describe aquí el cambio"
& $git push
```

Datos, fotos, videos, claves y el entorno de Python **no** se suben (están en `.gitignore`).
