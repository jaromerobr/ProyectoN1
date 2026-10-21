package com.taxiff.taxiff

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Size
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.resolutionselector.AspectRatioStrategy
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleService
import java.util.concurrent.Executors

/**
 * Servicio en primer plano (tipo cámara) que mantiene vivo el conteo cuando
 * el conductor sale de la app (p. ej. a Ktaxi) o apaga la pantalla.
 *
 * Mientras la app está visible, la cámara la usa el plugin `camera` (con vista
 * previa). Al pasar a segundo plano, Dart llama a [startCapture]: el servicio
 * abre la cámara con CameraX sin vista previa y guarda el último fotograma en
 * RGBA, que Dart recoge con [takeFrame] y analiza con el mismo pipeline.
 */
class CaptureService : LifecycleService() {

    class Frame(
        val rgba: ByteArray,
        val width: Int,
        val height: Int,
        val rotation: Int,
        val timestamp: Long,
    )

    companion object {
        const val CHANNEL_ID = "taxiff_live"
        const val NOTIFICATION_ID = 42

        @Volatile var instance: CaptureService? = null
            private set

        /** Petición de captura recibida antes de que el servicio arrancara. */
        @Volatile var pendingFront: Boolean? = null
        @Volatile var pendingWide: Boolean = true

        @Volatile private var latest: Frame? = null
        @Volatile private var lastTaken = 0L

        /** Último fotograma si es más nuevo que el anterior entregado. */
        fun takeFrame(): Frame? {
            val f = latest ?: return null
            if (f.timestamp == lastTaken) return null
            lastTaken = f.timestamp
            return f
        }

        fun start(context: Context) {
            ContextCompat.startForegroundService(
                context, Intent(context, CaptureService::class.java))
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, CaptureService::class.java))
        }
    }

    private val analyzerExecutor = Executors.newSingleThreadExecutor()
    private var provider: ProcessCameraProvider? = null
    private var analysis: ImageAnalysis? = null
    private var lastCopyMs = 0L
    private var title = "Taxiff activo"
    private var text = "Contando pasajeros"

    override fun onCreate() {
        super.onCreate()
        instance = this
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        super.onStartCommand(intent, flags, startId)
        val n = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // Ubicación solo si el permiso ya está concedido (si no, Android
            // rechaza el servicio). Así el GPS de la carrera sigue en 2.º plano.
            var types = ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
            if (checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) ==
                PackageManager.PERMISSION_GRANTED) {
                types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION
            }
            startForeground(NOTIFICATION_ID, n, types)
        } else {
            startForeground(NOTIFICATION_ID, n)
        }
        pendingFront?.let { startCapture(it, pendingWide) }
        pendingFront = null
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent): IBinder? {
        super.onBind(intent)
        return null
    }

    override fun onDestroy() {
        stopCapture()
        instance = null
        latest = null
        analyzerExecutor.shutdown()
        super.onDestroy()
    }

    fun startCapture(front: Boolean, wide: Boolean = true) {
        val future = ProcessCameraProvider.getInstance(this)
        future.addListener({
            val p = future.get()
            provider = p
            analysis?.let { p.unbind(it) }

            // Mismo aspecto que la vista de la app (el plugin usa 16:9 en
            // "high"); si no, los asientos calibrados no coincidirían.
            val selector = ResolutionSelector.Builder()
                .setAspectRatioStrategy(
                    if (wide) AspectRatioStrategy.RATIO_16_9_FALLBACK_AUTO_STRATEGY
                    else AspectRatioStrategy.RATIO_4_3_FALLBACK_AUTO_STRATEGY)
                .setResolutionStrategy(
                    ResolutionStrategy(
                        if (wide) Size(640, 360) else Size(640, 480),
                        ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER))
                .build()
            val a = ImageAnalysis.Builder()
                .setResolutionSelector(selector)
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_RGBA_8888)
                .build()
            a.setAnalyzer(analyzerExecutor) { img ->
                try {
                    // Dart analiza ~2-5 fps: no hace falta copiar cada fotograma.
                    val now = System.currentTimeMillis()
                    if (now - lastCopyMs >= 150) {
                        lastCopyMs = now
                        val plane = img.planes[0]
                        val w = img.width
                        val h = img.height
                        val rowBytes = w * 4
                        val out = ByteArray(rowBytes * h)
                        val buf = plane.buffer
                        buf.rewind()
                        if (plane.rowStride == rowBytes) {
                            buf.get(out, 0, out.size)
                        } else {
                            for (y in 0 until h) {
                                buf.position(y * plane.rowStride)
                                buf.get(out, y * rowBytes, rowBytes)
                            }
                        }
                        latest = Frame(out, w, h, img.imageInfo.rotationDegrees, now)
                    }
                } finally {
                    img.close()
                }
            }
            val cam = if (front) CameraSelector.DEFAULT_FRONT_CAMERA
                      else CameraSelector.DEFAULT_BACK_CAMERA
            try {
                p.bindToLifecycle(this, cam, a)
                analysis = a
            } catch (e: Exception) {
                android.util.Log.e("Taxiff", "No se pudo abrir la cámara en segundo plano", e)
            }
        }, ContextCompat.getMainExecutor(this))
    }

    fun stopCapture() {
        analysis?.let { a ->
            a.clearAnalyzer()
            provider?.unbind(a) // solo lo nuestro: el plugin usa el mismo proveedor
        }
        analysis = null
        latest = null
    }

    fun updateNotification(title: String, text: String) {
        this.title = title
        this.text = text
        getSystemService(NotificationManager::class.java)
            .notify(NOTIFICATION_ID, buildNotification())
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val ch = NotificationChannel(
                CHANNEL_ID, "Conteo en curso", NotificationManager.IMPORTANCE_LOW)
            ch.description = "Aviso fijo mientras Taxiff cuenta pasajeros"
            ch.setShowBadge(false)
            getSystemService(NotificationManager::class.java).createNotificationChannel(ch)
        }
    }

    private fun buildNotification() =
        NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_taxi)
            .setContentTitle(title)
            .setContentText(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setColor(0xFFFF9F0A.toInt())
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .setContentIntent(
                PendingIntent.getActivity(
                    this, 0,
                    Intent(this, MainActivity::class.java)
                        .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))
            .build()
}
