# Plan y estado del proyecto

## Estado actual

### App Android — funcional
- Cuenta pasajeros con YOLO en el teléfono.
- Sigue funcionando en segundo plano.
- Jaula y calibración de asientos.
- Fotos de evidencia.
- Modo dueño.
- Exporta a Excel y PDF.

### Cámara ESP32 — funcional, probada en el escritorio y en un auto
- Detección de cabezas en la propia placa (FOMO, unas 2 fotos por segundo).
- Envío de fotos al servidor, con cola sin internet probada: se cortó el servidor y las fotos llegaron después.
- Actualización por internet. Se protege de reintentos infinitos.
- Se recupera sola si se cuelga la cámara. Protección térmica. Diagnóstico de reinicios.

### Servidor — funcional en la PC
- Registro de cámaras.
- Conteo con YOLO y jaula por taxi.
- Carreras y fotos de evidencia.
- Panel web y exportación a CSV.
- Publicación de firmware.
- 18 pruebas automáticas.
- Listo para Docker con HTTPS.

## Para salir a producción (en orden)

1. **Prueba en un taxi real con la PC como servidor** (`iniciar_pc.ps1 -Tunel`). Medir:
   - si el conteo del servidor coincide con la realidad: asientos de atrás, de noche, gente afuera;
   - cuántos MB por turno gasta el hotspot;
   - cómo se comporta en zonas sin señal.
2. **Contratar el VPS y el dominio** y desplegar con `docker compose` (ver `servidor/README.md`). Poner `TAXIFF_AUTO_APROBAR=0` y una clave fuerte.
3. **Copia de seguridad diaria** de `servidor/datos/`.
4. **Monitoreo:** un servicio gratuito (UptimeRobot) que consulte `https://<dominio>/api/salud` cada 5 minutos.
5. **Instalación física de cada equipo:**
   - convertidor 12 V → 5 V de 2 A con fusible, conectado a la línea de la llave (ACC);
   - caja ventilada;
   - montaje en el techo, cerca del retrovisor, sin sol directo;
   - aviso visible de "vehículo con cámara" (Ley Orgánica de Protección de Datos Personales).
6. **Piloto con 3 a 5 taxis** durante 2 a 4 semanas antes de crecer.

## Mejoras recomendadas

### Precisión
- **Fotos reales para entrenar.** Juntar fotos de taxis reales con la cámara (de día, de noche, todos los asientos, varias personas), etiquetarlas en Roboflow y reentrenar el modelo de cabezas. Es lo que más mejora el conteo.
- **Usar esas mismas fotos en YOLO.** Etiquetar personas en ellas y reentrenar también el YOLO del servidor (`modelos/best.pt`).
- **Luz de noche.** Agregar LED infrarrojo con una cámara sin filtro IR, o una luz tenue en la cabina.

### Servidor
- **Usuarios del panel.** Pasar de una clave única a usuarios con roles (dueño de flota, supervisor) y que cada dueño vea solo sus taxis.
- **Escala.**
  - SQLite aguanta decenas de taxis. Para cientos, PostgreSQL y fotos en almacenamiento de objetos (S3, Cloudflare R2).
  - Para la carga de YOLO: cola de trabajos (Redis + workers) o un servidor con GPU.
  - Referencia: 100 taxis con pasajeros a 1 foto/s son unas 100 inferencias por segundo.
- **Reportes:** carreras por taxi y por día, horas pico, pasajeros por turno, alertas (cámara desconectada, temperatura alta, muchas carreras descartadas).
- **Notificaciones:** aviso al dueño si una cámara lleva más de X minutos sin conexión en horario de trabajo.

### Cámara
- **Reducir el envío.** Dejar de enviar en vivo cuando la cámara está segura de que la cabina está vacía y nada se mueve (detección de movimiento). Hoy envía una foto cada 5 s igual.
- **Conexión.** Varias redes WiFi guardadas (hotspot del conductor + WiFi de la base), y módulo 4G propio (SIM7600) para no depender del teléfono del conductor.
- **Seguridad.**
  - Verificar el certificado HTTPS del servidor (hoy acepta cualquiera).
  - Firmar el firmware publicado.
  - Activar la reversión automática si una versión nueva no arranca bien.
- **Hora sin internet.** Un reloj RTC con pila, para que las fotos de la cola tengan hora real aunque la cámara arranque sin internet.

### App
- **Cámara ESP32 como fuente.** Usar la cámara del ESP32 como cámara externa (por WiFi) y que la app solo muestre y reporte.

## Riesgos conocidos

- **Hotspot del conductor:** si lo apaga, el ESP32 no tiene internet. La cola guarda unas 800–1000 fotos (≈ 1–3 h con pasajeros). Pasado eso, borra las más viejas.
- **Calor:** dentro de un auto al sol se pueden superar los 70 °C. Ubicación y ventilación importan más que el consumo del ESP32.
- **640×480 en la cámara:** es menos estable que 320×240. Usar 320×240 en producción.
- **Túnel gratuito de pruebas:** la dirección cambia en cada arranque. Solo sirve para pruebas.
