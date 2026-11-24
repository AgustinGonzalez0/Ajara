/// Registro de modelos instalados.
///
/// Los modelos se distribuyen como `<id>.onnx` + `<id>.model.json`
/// (formato structura-model/1). Al instalarse se copian al directorio de soporte
/// de la app y se verifica el SHA-256 declarado: un modelo alterado no se carga.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:structura_pipeline/structura_pipeline.dart';

class InstalledModel {
  final ModelDescriptor descriptor;
  final String path;
  final int bytes;
  final bool hashVerified;
  final String origin; // 'bundled'
  const InstalledModel(this.descriptor, this.path, this.bytes, this.hashVerified, this.origin);
}

class ModelRegistry {
  final Directory modelsDir;
  final AssetBundle bundle;
  ModelRegistry(this.modelsDir, this.bundle);

  /// Instala (si hace falta) y devuelve los modelos empaquetados con la app.
  Future<List<InstalledModel>> installedModels() async {
    final manifest = await AssetManifest.loadFromAssetBundle(bundle);
    final descriptors = manifest.listAssets().where((a) => a.startsWith('assets/models/') && a.endsWith('.model.json'));
    await modelsDir.create(recursive: true);
    final out = <InstalledModel>[];
    for (final asset in descriptors) {
      final d = ModelDescriptor.fromJson(jsonDecode(await bundle.loadString(asset)) as Map<String, Object?>);
      final target = File(p.join(modelsDir.path, d.file));
      var verified = false;
      if (await target.exists()) verified = await _matches(target, d.sha256);
      if (!verified) {
        final data = await bundle.load('assets/models/${d.file}');
        await target.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
        verified = await _matches(target, d.sha256);
      }
      out.add(InstalledModel(d, target.path, await target.length(), verified, 'bundled'));
    }
    return out;
  }

  static Future<bool> _matches(File f, String? expected) async {
    if (expected == null) return false;
    return sha256.convert(await f.readAsBytes()).toString() == expected;
  }
}
