package com.taxiff.taxiff

import android.Manifest
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioManager
import android.media.ToneGenerator
import android.os.BatteryManager
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.net.Uri
import android.os.PowerManager
import android.provider.Settings
import android.graphics.Matrix
import android.media.MediaMetadataRetriever
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.util.concurrent.Executors

/**
 * Canal "taxiff/video_frames": extrae fotogramas RGBA de un vídeo local con
 * MediaMetadataRetriever para el modo simulación (video_player no da acceso
 * a los píxeles).
 */
class MainActivity : FlutterActivity() {
    private val executor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var retriever: MediaMetadataRetriever? = null
    private var rotation = 0

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Conteo en segundo plano (ver CaptureService).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "taxiff/background")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startService" -> {
                        if (Build.VERSION.SDK_INT >= 33 &&
                            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
                            PackageManager.PERMISSION_GRANTED) {
                            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 7)
                        }
                        try {
                            CaptureService.start(this)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("SERVICE", e.message, null)
                        }
                    }
                    "stopService" -> { CaptureService.stop(this); result.success(null) }
                    "startCapture" -> {
                        val front = call.argument<Boolean>("front") ?: false
                        val wide = call.argument<Boolean>("wide") ?: true
                        val s = CaptureService.instance
                        if (s != null) s.startCapture(front, wide) else {
                            CaptureService.pendingFront = front
                            CaptureService.pendingWide = wide
                        }
                        result.success(null)
                    }
                    "stopCapture" -> {
                        CaptureService.pendingFront = null
                        CaptureService.instance?.stopCapture()
                        result.success(null)
                    }
                    "frame" -> {
                        val f = CaptureService.takeFrame()
                        result.success(f?.let {
                            mapOf("rgba" to it.rgba, "width" to it.width,
                                  "height" to it.height, "rotation" to it.rotation)
                        })
                    }
                    "notify" -> {
                        CaptureService.instance?.updateNotification(
                            call.argument<String>("title") ?: "Taxiff",
                            call.argument<String>("text") ?: "")
                        result.success(null)
                    }
                    "batteryUnrestricted" -> {
                        val pm = getSystemService(PowerManager::class.java)
                        result.success(pm.isIgnoringBatteryOptimizations(packageName))
                    }
                    "requestBatteryUnrestricted" -> {
                        try {
                            startActivity(Intent(
                                Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                                Uri.parse("package:$packageName")))
                        } catch (_: Exception) {
                            startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        // Brillo de la ventana para la "pantalla negra" (valor < 0 = el del sistema).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "taxiff/screen")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setBrightness" -> {
                        val v = call.argument<Number>("value")!!.toFloat()
                        window.attributes = window.attributes.apply {
                            screenBrightness = if (v < 0) -1f else v.coerceIn(0.01f, 1f)
                        }
                        result.success(null)
                    }
                    // Pitido corto para avisos (inicio / fin / alerta).
                    "beep" -> {
                        val tone = when (call.argument<String>("kind")) {
                            "end" -> ToneGenerator.TONE_PROP_ACK
                            "warn" -> ToneGenerator.TONE_CDMA_ALERT_CALL_GUARD
                            else -> ToneGenerator.TONE_PROP_BEEP2
                        }
                        try {
                            val tg = ToneGenerator(AudioManager.STREAM_NOTIFICATION, 80)
                            tg.startTone(tone, 250)
                            Handler(Looper.getMainLooper()).postDelayed({ tg.release() }, 600)
                        } catch (_: Exception) {}
                        result.success(null)
                    }
                    // Estado térmico de Android (0 = normal … 6 = apagado) y
                    // temperatura de la batería en °C.
                    "thermal" -> {
                        val pm = getSystemService(PowerManager::class.java)
                        val status = if (Build.VERSION.SDK_INT >= 29) pm.currentThermalStatus else 0
                        val bat = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
                        val temp = (bat?.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, 0) ?: 0) / 10.0
                        result.success(mapOf("status" to status, "batteryTemp" to temp))
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "taxiff/video_frames")
            .setMethodCallHandler { call, result ->
                executor.execute {
                    try {
                        val value: Any? = when (call.method) {
                            "open" -> open(call.argument<String>("path")!!)
                            "frame" -> frame(
                                call.argument<Number>("timeMs")!!.toLong(),
                                call.argument<Number>("maxSide")!!.toInt(),
                                call.argument<Boolean>("fast") ?: false,
                            )
                            "close" -> { close(); null }
                            else -> { main.post { result.notImplemented() }; return@execute }
                        }
                        main.post { result.success(value) }
                    } catch (e: Exception) {
                        main.post { result.error("VIDEO_ERROR", e.message, null) }
                    }
                }
            }
    }

    private fun open(path: String): Map<String, Any> {
        close()
        val r = MediaMetadataRetriever()
        // Vídeos de la galería llegan como content://: se leen directamente,
        // sin copiar el archivo (un vídeo de 3 h puede ocupar varios GB).
        if (path.startsWith("content://")) r.setDataSource(this, Uri.parse(path))
        else r.setDataSource(path)
        retriever = r
        fun meta(key: Int) = r.extractMetadata(key)?.toIntOrNull() ?: 0
        rotation = meta(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)
        val w = meta(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)
        val h = meta(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)
        val swap = rotation == 90 || rotation == 270
        return mapOf(
            "durationMs" to (r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?.toLongOrNull() ?: 0L),
            "width" to if (swap) h else w,
            "height" to if (swap) w else h,
            // Fecha de grabación (p. ej. "20261015T143000.000Z"), si existe.
            "date" to (r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DATE) ?: ""),
        )
    }

    private fun frame(timeMs: Long, maxSide: Int, fast: Boolean): Map<String, Any>? {
        val r = retriever ?: throw IllegalStateException("Vídeo no abierto")
        val us = timeMs * 1000
        // fast: fotograma clave más cercano (mucho más rápido en vídeos
        // largos; desfase de ~1 s, irrelevante para cronometrar carreras).
        val opt = if (fast) MediaMetadataRetriever.OPTION_CLOSEST_SYNC
                  else MediaMetadataRetriever.OPTION_CLOSEST
        var bmp: Bitmap = (if (Build.VERSION.SDK_INT >= 27) {
            r.getScaledFrameAtTime(us, opt, maxSide, maxSide)
        } else {
            r.getFrameAtTime(us, opt)
        }) ?: return null

        // Algunos dispositivos devuelven el fotograma sin aplicar la rotación.
        val expectPortrait = rotation == 90 || rotation == 270
        if (rotation != 0 && (bmp.height > bmp.width) != expectPortrait) {
            val m = Matrix().apply { postRotate(rotation.toFloat()) }
            bmp = Bitmap.createBitmap(bmp, 0, 0, bmp.width, bmp.height, m, true)
        }
        val longest = maxOf(bmp.width, bmp.height)
        if (longest > maxSide) {
            val s = maxSide.toFloat() / longest
            bmp = Bitmap.createScaledBitmap(
                bmp, (bmp.width * s).toInt(), (bmp.height * s).toInt(), true)
        }
        if (bmp.config != Bitmap.Config.ARGB_8888) {
            bmp = bmp.copy(Bitmap.Config.ARGB_8888, false)
        }
        // ARGB_8888 se copia en memoria como R,G,B,A.
        val buf = ByteBuffer.allocate(bmp.byteCount)
        bmp.copyPixelsToBuffer(buf)
        return mapOf("width" to bmp.width, "height" to bmp.height, "rgba" to buf.array())
    }

    private fun close() {
        retriever?.release()
        retriever = null
    }

    override fun onDestroy() {
        executor.execute { close() }
        executor.shutdown()
        super.onDestroy()
    }
}
