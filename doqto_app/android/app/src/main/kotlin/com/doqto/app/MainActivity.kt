package com.doqto.app

import android.content.ActivityNotFoundException
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
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
