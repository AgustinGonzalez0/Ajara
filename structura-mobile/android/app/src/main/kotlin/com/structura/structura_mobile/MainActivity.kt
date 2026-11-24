package com.structura.structura_mobile

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var onnx: OnnxBridge? = null
    private var pdf: PdfBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        onnx = OnnxBridge().also { MethodChannel(messenger, "structura/onnx").setMethodCallHandler(it) }
        pdf = PdfBridge().also { MethodChannel(messenger, "structura/pdf").setMethodCallHandler(it) }
    }

    override fun onDestroy() {
        onnx?.closeAll()
        pdf?.shutdown()
        super.onDestroy()
    }
}
