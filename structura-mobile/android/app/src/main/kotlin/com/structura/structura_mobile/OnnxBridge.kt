package com.structura.structura_mobile

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.FloatBuffer
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/**
 * Puente ONNX Runtime (CPU) para STRUCTURA.
 *
 * Métodos: load(path, threads) -> {session, provider, inputs, outputs};
 * run(session, input: FloatArray, shape) -> FloatArray (logits); close(session).
 * La inferencia corre en un hilo de fondo; la respuesta vuelve al hilo principal.
 * No se usa NNAPI ni NPU: la compatibilidad de los operadores del modelo con el
 * NPU del dispositivo no está verificada (ver docs/DECISIONES.md).
 */
class OnnxBridge : MethodChannel.MethodCallHandler {
    private val env: OrtEnvironment = OrtEnvironment.getEnvironment()
    private val sessions = ConcurrentHashMap<Int, OrtSession>()
    private val nextId = AtomicInteger(1)
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "load" -> background(result) {
                val path = call.argument<String>("path") ?: throw IllegalArgumentException("path requerido")
                val threads = call.argument<Int>("threads") ?: 4
                val opts = OrtSession.SessionOptions().apply {
                    setIntraOpNumThreads(threads)
                    setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT)
                }
                val session = env.createSession(path, opts)
                val id = nextId.getAndIncrement()
                sessions[id] = session
                mapOf(
                    "session" to id,
                    "provider" to "CPU",
                    "inputs" to session.inputNames.toList(),
                    "outputs" to session.outputNames.toList(),
                )
            }
            "run" -> background(result) {
                val id = call.argument<Int>("session") ?: throw IllegalArgumentException("session requerida")
                val session = sessions[id] ?: throw IllegalStateException("sesion $id inexistente")
                val input = call.argument<FloatArray>("input") ?: throw IllegalArgumentException("input requerido")
                val shape = (call.argument<List<Int>>("shape") ?: listOf(1, 3, 512, 512)).map { it.toLong() }.toLongArray()
                val expected = shape.fold(1L) { a, b -> a * b }
                require(input.size.toLong() == expected) { "input con ${input.size} valores; se esperaban $expected" }
                val inputName = session.inputNames.first()
                OnnxTensor.createTensor(env, FloatBuffer.wrap(input), shape).use { tensor ->
                    session.run(mapOf(inputName to tensor)).use { out ->
                        val value = out.get(0) as OnnxTensor
                        val buf = value.floatBuffer
                        val arr = FloatArray(buf.remaining())
                        buf.get(arr)
                        arr
                    }
                }
            }
            "close" -> background(result) {
                val id = call.argument<Int>("session")
                sessions.remove(id)?.close()
                null
            }
            else -> result.notImplemented()
        }
    }

    private fun background(result: MethodChannel.Result, block: () -> Any?) {
        worker.execute {
            try {
                val value = block()
                main.post { result.success(value) }
            } catch (e: Throwable) {
                main.post { result.error("ONNX_ERROR", e.message ?: e.javaClass.simpleName, null) }
            }
        }
    }

    fun closeAll() {
        sessions.values.forEach { it.close() }
        sessions.clear()
        worker.shutdown()
    }
}
