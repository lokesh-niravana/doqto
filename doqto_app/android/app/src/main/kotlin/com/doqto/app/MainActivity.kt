package com.doqto.app

import android.content.ActivityNotFoundException
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.media.AudioManager
import android.media.MediaMetadataRetriever
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.provider.MediaStore
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.Executors

// No FLAG_SECURE (owner's decision, 2026-09-25). It blanked every screenshot,
// so Play review's capture saw only the launch screen and rejected the app as
// "does not load" (2026-09-13). iOS has no equivalent. If screenshot blocking
// becomes a requirement, add it back on the chat screens only.
class MainActivity : FlutterActivity() {
    // PdfRenderer allows one open page at a time and is not thread-safe, so
    // every PDF call runs on this one thread.
    private val pdfThread = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var renderer: PdfRenderer? = null
    private var descriptor: ParcelFileDescriptor? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "doqto/documents")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openExternal" -> openExternal(call, result)
                    "pdfOpen" -> onPdfThread(result) { pdfOpen(call.argument<String>("path")!!) }
                    "pdfPage" -> onPdfThread(result) {
                        pdfPage(call.argument<Int>("index")!!, call.argument<Int>("width")!!)
                    }
                    "pdfClose" -> onPdfThread(result) { pdfClose() }
                    else -> result.notImplemented()
                }
            }
        // Batch 5 media (lib/data/services/media_native.dart): posters via
        // MediaMetadataRetriever, Save to Photos via MediaStore, radio type
        // via ConnectivityManager, earpiece via AudioManager + the proximity
        // sensor. No document scanner on Android (the app offers the camera).
        mediaChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "doqto/media").also { ch ->
            ch.setMethodCallHandler { call, result ->
                when (call.method) {
                    "videoPoster" -> {
                        val path = call.argument<String>("path")!!
                        val maxSide = call.argument<Int>("maxSide") ?: 720
                        mediaThread.execute {
                            val poster = videoPoster(path, maxSide)
                            main.post { result.success(poster) }
                        }
                    }
                    "saveToPhotos" -> {
                        val path = call.argument<String>("path")!!
                        mediaThread.execute {
                            val ok = saveToPhotos(path)
                            main.post { result.success(ok) }
                        }
                    }
                    "scanDocument" -> result.success(null)
                    "networkType" -> result.success(networkType())
                    "setEarpiece" -> { setEarpiece(call.argument<Boolean>("earpiece") ?: false); result.success(null) }
                    "proximityStart" -> { proximity(true); result.success(null) }
                    "proximityStop" -> { proximity(false); result.success(null) }
                    else -> result.notImplemented()
                }
            }
        }
    }

    private val mediaThread = Executors.newSingleThreadExecutor()
    private var mediaChannel: MethodChannel? = null
    private var proximityListener: SensorEventListener? = null

    private fun videoPoster(path: String, maxSide: Int): Map<String, Any>? {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(path)
            val durationMs = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
            val at = minOf(100_000L, durationMs * 500) // µs: 0.1 s in, or half of a tiny clip
            val frame = retriever.getFrameAtTime(at, MediaMetadataRetriever.OPTION_CLOSEST_SYNC) ?: return null
            val scale = minOf(1f, maxSide.toFloat() / maxOf(frame.width, frame.height))
            val scaled = if (scale < 1f) {
                Bitmap.createScaledBitmap(frame, (frame.width * scale).toInt(), (frame.height * scale).toInt(), true)
            } else frame
            val out = ByteArrayOutputStream()
            scaled.compress(Bitmap.CompressFormat.JPEG, 80, out)
            mapOf(
                "jpeg" to out.toByteArray(),
                "width" to scaled.width,
                "height" to scaled.height,
                "durationMs" to durationMs.toInt(),
            )
        } catch (_: Exception) {
            null
        } finally {
            try { retriever.release() } catch (_: Exception) {}
        }
    }

    private fun saveToPhotos(path: String): Boolean {
        val file = File(path)
        if (!file.exists()) return false
        val ext = file.extension.lowercase()
        val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: "application/octet-stream"
        val isVideo = mime.startsWith("video/")
        val collection = if (isVideo) MediaStore.Video.Media.EXTERNAL_CONTENT_URI else MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, file.name)
            put(MediaStore.MediaColumns.MIME_TYPE, mime)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                put(MediaStore.MediaColumns.RELATIVE_PATH, (if (isVideo) "Movies/" else "Pictures/") + "Doqto")
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
        }
        val resolver = contentResolver
        val uri = resolver.insert(collection, values) ?: return false
        return try {
            resolver.openOutputStream(uri)!!.use { out -> file.inputStream().use { it.copyTo(out) } }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                values.clear()
                values.put(MediaStore.MediaColumns.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
            }
            true
        } catch (_: Exception) {
            resolver.delete(uri, null, null)
            false
        }
    }

    private fun networkType(): String {
        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val caps = cm.getNetworkCapabilities(cm.activeNetwork) ?: return "none"
        return when {
            !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) -> "none"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
            else -> "wifi"
        }
    }

    private fun setEarpiece(earpiece: Boolean) {
        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        if (earpiece) {
            am.mode = AudioManager.MODE_IN_COMMUNICATION
            @Suppress("DEPRECATION")
            am.isSpeakerphoneOn = false
        } else {
            am.mode = AudioManager.MODE_NORMAL
            @Suppress("DEPRECATION")
            am.isSpeakerphoneOn = true
        }
    }

    private fun proximity(enabled: Boolean) {
        val sm = getSystemService(Context.SENSOR_SERVICE) as SensorManager
        val sensor = sm.getDefaultSensor(Sensor.TYPE_PROXIMITY) ?: return
        if (enabled && proximityListener == null) {
            val listener = object : SensorEventListener {
                override fun onSensorChanged(event: SensorEvent) {
                    val near = event.values.firstOrNull()?.let { it < sensor.maximumRange } ?: false
                    main.post { mediaChannel?.invokeMethod("proximity", near) }
                }
                override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
            }
            proximityListener = listener
            sm.registerListener(listener, sensor, SensorManager.SENSOR_DELAY_NORMAL)
        } else if (!enabled) {
            proximityListener?.let { sm.unregisterListener(it) }
            proximityListener = null
        }
    }

    /** Hands one file to another app, with a read grant for that file only. */
    private fun openExternal(call: MethodCall, result: MethodChannel.Result) {
        val file = File(call.argument<String>("path")!!)
        val uri = FileProvider.getUriForFile(this, "$packageName.documents", file)
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, call.argument<String>("mime"))
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        try {
            startActivity(intent)
            result.success(true)
        } catch (_: ActivityNotFoundException) {
            result.success(false)
        }
    }

    private fun onPdfThread(result: MethodChannel.Result, work: () -> Any?) {
        pdfThread.execute {
            try {
                val value = work()
                main.post { result.success(value) }
            } catch (e: Exception) {
                // Encrypted or corrupt PDFs land here.
                main.post { result.error("pdf_failed", e.message, null) }
            }
        }
    }

    private fun pdfOpen(path: String): List<Map<String, Int>> {
        pdfClose()
        val fd = ParcelFileDescriptor.open(File(path), ParcelFileDescriptor.MODE_READ_ONLY)
        descriptor = fd
        val pdf = PdfRenderer(fd)
        renderer = pdf
        return (0 until pdf.pageCount).map { i ->
            pdf.openPage(i).use { mapOf("w" to it.width, "h" to it.height) }
        }
    }

    private fun pdfPage(index: Int, width: Int): ByteArray {
        val pdf = renderer ?: error("no pdf open")
        pdf.openPage(index).use { page ->
            val height = (page.height.toDouble() * width / page.width).toInt().coerceAtLeast(1)
            val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            try {
                bitmap.eraseColor(Color.WHITE)
                page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                return ByteArrayOutputStream().use {
                    bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)
                    it.toByteArray()
                }
            } finally {
                bitmap.recycle()
            }
        }
    }

    private fun pdfClose() {
        renderer?.close()
        renderer = null
        descriptor?.close()
        descriptor = null
    }

    override fun onDestroy() {
        pdfThread.execute { pdfClose() }
        pdfThread.shutdown()
        super.onDestroy()
    }
}
