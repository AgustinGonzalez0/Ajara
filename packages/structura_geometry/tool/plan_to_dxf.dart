/// Convierte un building_model.json en DXF (y cómputo CSV si hay escala).
///
/// Uso: dart run tool/plan_to_dxf.dart modelo.json salida.dxf [px_por_metro]
library;

import 'dart:convert';
import 'dart:io';

import 'package:structura_geometry/structura_geometry.dart';
import 'package:structura_model/structura_model.dart';

void main(List<String> args) {
  if (args.length < 2) {
    stderr.writeln('Uso: dart run tool/plan_to_dxf.dart modelo.json salida.dxf [px_por_metro]');
    exit(64);
  }
  var model = BuildingModel.fromJson(jsonDecode(File(args[0]).readAsStringSync()) as Map<String, Object?>);
  if (args.length > 2) {
    model = model.copyWith(
        scale: PlanScale(
            pxPerUnit: double.parse(args[2]),
            unit: LengthUnit.m,
            verified: true,
            source: const Source(Provenance.userCreated, note: 'línea de comandos')));
  }
  final d = buildDxf(model, title: 'STRUCTURA AI');
  File(args[1]).writeAsStringSync(d.content);
  stdout.writeln('${d.entities} entidades, ${d.inMeters ? 'metros' : 'píxeles'} → ${args[1]}');
  if (model.hasVerifiedScale) {
    final t = computeTakeoff(model);
    File(args[1].replaceAll(RegExp(r'\.dxf$'), '.csv')).writeAsStringSync(t.toCsv());
    stdout.writeln(const JsonEncoder.withIndent(' ').convert({
      'covered': t.coveredAreaM2, 'useful': t.usefulAreaM2, 'rooms': [for (final r in t.rooms) r.areaM2],
      'walls': [for (final w in t.walls) w.toJson()], 'density': [t.wallDensityXPct, t.wallDensityYPct]}));
  }
}
