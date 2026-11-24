/// Exportación glTF 2.0 binaria (GLB) sin dependencias.
///
/// Una malla (node) por categoría, con material de color plano. Los supuestos de
/// visualización y la procedencia se guardan en `asset.extras` para que ningún
/// consumidor confunda alturas de visualización con medidas.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'mesh.dart';

const Map<String, List<double>> categoryColors = {
  'floor': [0.16, 0.18, 0.21, 1],
  'wall': [0.86, 0.87, 0.89, 1],
  'door': [0.24, 0.70, 0.29, 1],
  'window': [0.45, 0.70, 0.95, 0.5],
  'column': [0.96, 0.75, 0.20, 1],
  'stairs': [0.67, 0.31, 0.75, 1],
};

class GlbWriter {
  const GlbWriter();

  Uint8List write(BuildingMesh mesh, {Map<String, Object?> extras = const {}}) {
    final bin = BytesBuilder(copy: false);
    final bufferViews = <Map<String, Object?>>[];
    final accessors = <Map<String, Object?>>[];
    final meshes = <Map<String, Object?>>[];
    final materials = <Map<String, Object?>>[];
    final nodes = <Map<String, Object?>>[];

    int addView(Uint8List bytes, int target) {
      _pad(bin);
      final offset = bin.length;
      bin.add(bytes);
      bufferViews.add({'buffer': 0, 'byteOffset': offset, 'byteLength': bytes.length, 'target': target});
      return bufferViews.length - 1;
    }

    for (final part in mesh.parts.values) {
      if (part.triangleCount == 0) continue;
      final (mn, mx) = part.bounds();
      final pos = addView(part.positionsF32().buffer.asUint8List(), 34962);
      final nor = addView(part.normalsF32().buffer.asUint8List(), 34962);
      final idx = addView(part.indicesU32().buffer.asUint8List(), 34963);
      accessors.add({'bufferView': pos, 'componentType': 5126, 'count': part.vertexCount, 'type': 'VEC3', 'min': mn, 'max': mx});
      final posAcc = accessors.length - 1;
      accessors.add({'bufferView': nor, 'componentType': 5126, 'count': part.vertexCount, 'type': 'VEC3'});
      final norAcc = accessors.length - 1;
      accessors.add({'bufferView': idx, 'componentType': 5125, 'count': part.indices.length, 'type': 'SCALAR'});
      final idxAcc = accessors.length - 1;
      final color = categoryColors[part.category] ?? const [0.8, 0.8, 0.8, 1.0];
      materials.add({
        'name': part.category,
        'pbrMetallicRoughness': {'baseColorFactor': color, 'metallicFactor': 0.0, 'roughnessFactor': 0.9},
        if (color[3] < 1) 'alphaMode': 'BLEND',
        'doubleSided': color[3] < 1,
      });
      meshes.add({
        'name': part.category,
        'primitives': [
          {'attributes': {'POSITION': posAcc, 'NORMAL': norAcc}, 'indices': idxAcc, 'material': materials.length - 1, 'mode': 4}
        ],
      });
      nodes.add({'name': part.category, 'mesh': meshes.length - 1});
    }
    _pad(bin);
    final binBytes = bin.takeBytes();
    final gltf = {
      'asset': {
        'version': '2.0',
        'generator': 'STRUCTURA Geometry Engine 0.1',
        'extras': {'display_assumptions': mesh.assumptions.toJson(), ...extras},
      },
      'scene': 0,
      'scenes': [
        {'nodes': List.generate(nodes.length, (i) => i)}
      ],
      'nodes': nodes,
      'meshes': meshes,
      'materials': materials,
      'accessors': accessors,
      'bufferViews': bufferViews,
      'buffers': [
        {'byteLength': binBytes.length}
      ],
    };
    var jsonBytes = utf8.encode(jsonEncode(gltf));
    final jsonPad = (4 - jsonBytes.length % 4) % 4;
    jsonBytes = Uint8List.fromList([...jsonBytes, ...List.filled(jsonPad, 0x20)]);
    final total = 12 + 8 + jsonBytes.length + 8 + binBytes.length;
    final out = BytesBuilder(copy: false);
    final header = ByteData(12)
      ..setUint32(0, 0x46546C67, Endian.little) // 'glTF'
      ..setUint32(4, 2, Endian.little)
      ..setUint32(8, total, Endian.little);
    out.add(header.buffer.asUint8List());
    out.add((ByteData(8)
          ..setUint32(0, jsonBytes.length, Endian.little)
          ..setUint32(4, 0x4E4F534A, Endian.little)) // 'JSON'
        .buffer
        .asUint8List());
    out.add(jsonBytes);
    out.add((ByteData(8)
          ..setUint32(0, binBytes.length, Endian.little)
          ..setUint32(4, 0x004E4942, Endian.little)) // 'BIN\0'
        .buffer
        .asUint8List());
    out.add(binBytes);
    return out.takeBytes();
  }

  static void _pad(BytesBuilder b) {
    final pad = (4 - b.length % 4) % 4;
    if (pad > 0) b.add(Uint8List(pad));
  }
}

/// Lector mínimo para validar GLB (tests e integridad al abrir proyectos).
class GlbInfo {
  final Map<String, Object?> json;
  final Uint8List bin;
  GlbInfo(this.json, this.bin);

  static GlbInfo parse(Uint8List data) {
    final bd = ByteData.sublistView(data);
    if (data.length < 20 || bd.getUint32(0, Endian.little) != 0x46546C67) {
      throw const FormatException('No es un archivo GLB');
    }
    if (bd.getUint32(4, Endian.little) != 2) throw const FormatException('Versión glTF no soportada');
    if (bd.getUint32(8, Endian.little) != data.length) throw const FormatException('Longitud GLB inconsistente');
    final jsonLen = bd.getUint32(12, Endian.little);
    if (bd.getUint32(16, Endian.little) != 0x4E4F534A) throw const FormatException('Falta chunk JSON');
    final json = jsonDecode(utf8.decode(data.sublist(20, 20 + jsonLen))) as Map<String, Object?>;
    final off = 20 + jsonLen;
    final binLen = bd.getUint32(off, Endian.little);
    if (bd.getUint32(off + 4, Endian.little) != 0x004E4942) throw const FormatException('Falta chunk BIN');
    return GlbInfo(json, data.sublist(off + 8, off + 8 + binLen));
  }
}
