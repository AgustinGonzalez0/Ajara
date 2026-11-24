package com.structura.structura_mobile

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.Executors
import kotlin.math.roundToInt

/**
 * Rasterización de PDF con android.graphics.pdf.PdfRenderer (sistema, sin dependencias).
 * render(path, page 0-based, dpi, out, maxPixels) -> {width, height, page_width_pt, page_height_pt}.
 * El fondo se pinta blanco antes de renderizar (papel), igual que structura-data.
 */
class PdfBridge : MethodChannel.MethodCallHandler {
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pageCount" -> background(result) {
                withRenderer(call.argument<String>("path")!!) { it.pageCount }
            }
            "render" -> background(result) {
                val path = call.argument<String>("path")!!
                val index = call.argument<Int>("page") ?: 0
                val dpi = call.argument<Double>("dpi") ?: 200.0
                val out = call.argument<String>("out")!!
                val maxPixels = (call.argument<Number>("maxPixels") ?: 60_000_000).toLong()
                withRenderer(path) { renderer ->
                    require(index in 0 until renderer.pageCount) { "pagina fuera de rango" }
                    val page = renderer.openPage(index)
                    try {
                        // PdfRenderer expresa el tamaño de página en puntos (1/72 de pulgada).
                        val w = (page.width * dpi / 72.0).roundToInt()
                        val h = (page.height * dpi / 72.0).roundToInt()
                        require(w > 0 && h > 0) { "pagina vacia" }
                        require(w.toLong() * h.toLong() <= maxPixels) {
                            "la pagina a ${dpi.toInt()} DPI tendria ${w.toLong() * h / 1_000_000} MP; reducir DPI"
                        }
                        val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
                        bmp.eraseColor(Color.WHITE)
                        page.render(bmp, null, null, PdfRenderer.Page.RENDER_MODE_FOR_PRINT)
                        File(out).parentFile?.mkdirs()
                        FileOutputStream(out).use { bmp.compress(Bitmap.CompressFormat.PNG, 100, it) }
                        bmp.recycle()
                        mapOf("width" to w, "height" to h, "page_width_pt" to page.width, "page_height_pt" to page.height)
                    } finally {
                        page.close()
                    }
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun <T> withRenderer(path: String, block: (PdfRenderer) -> T): T {
        val fd = ParcelFileDescriptor.open(File(path), ParcelFileDescriptor.MODE_READ_ONLY)
        try {
            val renderer = PdfRenderer(fd)
            try {
                return block(renderer)
            } finally {
                renderer.close()
            }
        } finally {
            fd.close()
        }
    }

    private fun background(result: MethodChannel.Result, block: () -> Any?) {
        worker.execute {
            try {
                val v = block()
                main.post { result.success(v) }
            } catch (e: Throwable) {
                main.post { result.error("PDF_ERROR", e.message ?: e.javaClass.simpleName, null) }
            }
        }
    }

    fun shutdown() = worker.shutdown()
}
