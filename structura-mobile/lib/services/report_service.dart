/// Informe PDF de la evaluación preliminar, generado en el dispositivo (sin red).
///
/// Es el documento que el profesional comparte con clientes y equipos. Deja trazable
/// qué se evaluó (plano, motor de detección, escala, datos declarados), con qué método
/// y con qué resultado, y repite en cada página que NO es un cálculo estructural.
///
/// Diseño: el contenido (filas, textos) se arma con funciones puras testeables; el
/// PDF se compone con el paquete `pdf` (Dart puro), así que corre en un isolate.
library;

import 'dart:convert';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:structura_model/structura_model.dart';
import 'package:structura_sim/structura_sim.dart';

import '../app/heat_scale.dart' show heatNoData;
import '../data/project_models.dart';
import '../data/project_store.dart';
import 'takeoff_service.dart';

const reportFileName = 'informe_evaluacion.pdf';

class ReportFonts {
  final Uint8List regular;
  final Uint8List bold;
  const ReportFonts(this.regular, this.bold);
}

/// Todo lo necesario para componer el informe (tipos enviables a un isolate).
class ReportJob {
  final String projectName;
  final String projectDescription;
  final String buildingType;
  final String planName;
  final String planSourceType;
  final String planSha256;
  final int planWidth;
  final int planHeight;
  final String analysisId;
  final DateTime analysisAt;
  final Map<String, Object?> engine;
  final Map<String, Object?> screening;
  final Map<String, Object?> buildingModel;
  final Uint8List? planImage;

  /// Cómputo métrico (`QuantityTakeoff.toJson`) o null si no se pudo calcular.
  final Map<String, Object?>? takeoff;
  final ReportFonts fonts;
  final DateTime generatedAt;
  final String appVersion;

  const ReportJob({
    required this.projectName,
    this.projectDescription = '',
    required this.buildingType,
    required this.planName,
    required this.planSourceType,
    required this.planSha256,
    required this.planWidth,
    required this.planHeight,
    required this.analysisId,
    required this.analysisAt,
    required this.engine,
    required this.screening,
    required this.buildingModel,
    this.planImage,
    this.takeoff,
    required this.fonts,
    required this.generatedAt,
    this.appVersion = '0.1.0',
  });
}

// ---------------------------------------------------------------------------
// Contenido (funciones puras)
// ---------------------------------------------------------------------------

/// Roboto no tiene flechas: se reemplazan por texto equivalente.
String pdfSafe(String s) => s
    .replaceAll('→', '->')
    .replaceAll('←', '<-')
    .replaceAll('↑', 'hacia arriba')
    .replaceAll('↓', 'hacia abajo')
    .replaceAll('∝', 'proporcional a');

String _n(num v, int d) => v.toStringAsFixed(d).replaceAll('.', ',');

String _date(DateTime t) {
  final l = t.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(l.day)}/${two(l.month)}/${l.year} ${two(l.hour)}:${two(l.minute)}';
}

const _statusText = {
  'ok': 'Dentro de lo esperable',
  'attention': 'Revisar',
  'critical': 'Demanda supera capacidad estimada',
  'notApplicable': 'Informativo',
};

const _hazardText = {'seismic': 'Sismo / terremoto', 'tsunami': 'Tsunami', 'wind': 'Viento'};

String statusText(String status) => _statusText[status] ?? status;
String hazardText(String hazard) => _hazardText[hazard] ?? hazard;

/// Valor de un indicador tal como se muestra en la app ("> 10 ×" si es muy alto).
String indicatorValueText(Map<String, Object?> i) {
  final v = i['value'] as num?;
  final unit = (i['unit'] as String?) ?? '';
  if (v == null) return 'sin capacidad';
  if (unit.isEmpty && v >= 10) return '> 10 ×';
  return unit.isEmpty ? _n(v, 2) : '${_n(v, 2)} $unit';
}

T? _byName<T extends Enum>(List<T> values, Object? name) {
  for (final v in values) {
    if (v.name == name) return v;
  }
  return null;
}

/// Fila del resumen: peligro, resultado y la relación demanda/capacidad más alta.
class SummaryRow {
  final String hazard;
  final String status;
  final String worst;
  const SummaryRow(this.hazard, this.status, this.worst);
}

List<SummaryRow> summaryRows(Map<String, Object?> screening) {
  final rows = <SummaryRow>[];
  for (final r in (screening['results'] as List).cast<Map>()) {
    Map<String, Object?>? worst;
    for (final i in (r['indicators'] as List).cast<Map>()) {
      final ind = i.cast<String, Object?>();
      if ((ind['unit'] as String? ?? '').isNotEmpty || ind['status'] == 'notApplicable') continue;
      final v = ind['value'] as num?;
      final w = worst?['value'] as num?;
      if (worst == null || v == null || (w != null && v > w)) worst = ind;
      if (v == null) break; // "sin capacidad" domina
    }
    rows.add(
      SummaryRow(
        hazardText(r['hazard'] as String),
        r['overall'] as String,
        worst == null ? '—' : '${worst['label']}: ${indicatorValueText(worst)}',
      ),
    );
  }
  return rows;
}

/// Datos declarados por el profesional (edificio y peligros) en filas legibles.
List<List<String>> declaredRows(Map<String, Object?> screening) {
  final b = (screening['building'] as Map).cast<String, Object?>();
  final inputs = (screening['inputs'] as Map).cast<String, Object?>();
  final mat = _byName(WallMaterial.values, b['material']);
  final props = (b['material_props'] as Map?)?.cast<String, Object?>() ?? const {};
  final t = b['wall_thickness_m'] as num?;
  final rows = <List<String>>[
    ['Pisos', '${b['floors']}'],
    ['Altura de piso', '${_n(b['story_height_m'] as num, 2)} m'],
    ['Material de muros', mat?.label ?? '${b['material']}'],
    [
      'Propiedades del material (indicativas)',
      'γ ${_n(props['unit_weight_kn_m3'] as num? ?? 0, 0)} kN/m³ · τ ${_n(props['shear_strength_mpa'] as num? ?? 0, 2)} MPa · '
          'f ${_n(props['flexural_strength_mpa'] as num? ?? 0, 2)} MPa · R ${_n(props['response_factor_r'] as num? ?? 0, 1)}',
    ],
    ['Espesor de muros', t == null ? 'el detectado en el plano (no declarado)' : '${_n(t * 100, 0)} cm (declarado)'],
    ['Carga de losa', '${_n(b['slab_load_kpa'] as num, 1)} kPa'],
  ];
  final s = (inputs['seismic'] as Map?)?.cast<String, Object?>();
  if (s != null) {
    final soil = _byName(SoilClass.values, s['soil']);
    rows.add(['Sismo: aceleración del suelo (PGA)', '${_n(s['pga_g'] as num, 2)} g']);
    rows.add(['Sismo: suelo', '${soil?.label ?? s['soil']} (S = ${_n(s['soil_factor'] as num, 2)})']);
  }
  final ts = (inputs['tsunami'] as Map?)?.cast<String, Object?>();
  if (ts != null) {
    final dir = _byName(FlowDirection.values, ts['direction']);
    final u = ts['flow_velocity_ms'] as num?;
    rows.add(['Tsunami: profundidad de inundación', '${_n(ts['inundation_depth_m'] as num, 2)} m']);
    rows.add(['Tsunami: velocidad del flujo', u == null ? 'estimada como √(g·h)' : '${_n(u, 1)} m/s (declarada)']);
    rows.add(['Tsunami: dirección del agua', pdfSafe(dir?.label ?? '${ts['direction']}')]);
  } else {
    rows.add(['Tsunami', 'no evaluado']);
  }
  final w = (inputs['wind'] as Map?)?.cast<String, Object?>();
  if (w != null) {
    final dir = _byName(FlowDirection.values, w['direction']);
    rows.add(['Viento: velocidad', '${_n(w['speed_ms'] as num, 0)} m/s']);
    rows.add(['Viento: dirección', pdfSafe(dir?.label ?? '${w['direction']}')]);
  } else {
    rows.add(['Viento', 'no evaluado']);
  }
  return rows;
}

/// Origen del plano, motor de detección, elementos y escala.
List<List<String>> provenanceRows(ReportJob job, BuildingModel model) {
  final e = job.engine;
  final classic = e['engine'] == 'classic';
  final counts = <String, int>{};
  for (final el in model.allElements) {
    counts[el.kind.name] = (counts[el.kind.name] ?? 0) + 1;
  }
  String c(String k) => '${counts[k] ?? 0}';
  final scale = model.scale;
  return [
    ['Plano', pdfSafe(job.planName)],
    [
      'Origen',
      job.planSourceType == 'photo' ? 'Foto (perspectiva corregida en el dispositivo)' : job.planSourceType.toUpperCase(),
    ],
    ['Resolución', '${job.planWidth} × ${job.planHeight} px'],
    [
      'Detección',
      classic
          ? 'Motor clásico de visión por computadora (sin IA)'
          : 'Vision AI ${e['id'] ?? ''} ${e['version'] ?? ''} (datos: ${e['training_data'] ?? '?'})',
    ],
    if (e['production_ready'] != true)
      ['Validación del detector', pdfSafe('${e['trust_label'] ?? 'sin validación con planos reales'}')],
    [
      'Elementos detectados',
      'muros ${c('wall')} · puertas ${c('door')} · ventanas ${c('window')} · columnas ${c('column')} · escaleras ${c('stairs')}',
    ],
    [
      'Escala',
      scale == null || !scale.verified
          ? 'sin escala verificada'
          : '${_n(scale.pxPerUnit, 1)} px/m, verificada por el usuario${scale.source.note == null ? '' : ' (${pdfSafe(scale.source.note!)})'}',
    ],
  ];
}

/// Filas del cómputo métrico preliminar para el informe.
List<List<String>> takeoffRows(Map<String, Object?> t) {
  double d(Object? v) => (v as num?)?.toDouble() ?? 0;
  final rooms = (t['rooms'] as List? ?? const []).cast<Map>();
  final walls = (t['walls'] as List? ?? const []).cast<Map>();
  final openings = (t['openings'] as List? ?? const []).cast<Map>();
  final params = (t['params'] as Map?)?.cast<String, Object?>() ?? const {};
  return [
    ['Superficie cubierta', '${_n(d(t['covered_area_m2']), 2)} m²${t['contour_closed'] == false ? ' (contorno abierto: rectángulo envolvente)' : ''}'],
    if (rooms.isNotEmpty) ['Superficie útil', '${_n(d(t['useful_area_m2']), 2)} m² en ${rooms.length} ambientes'],
    if (rooms.isNotEmpty) ['Ambientes', rooms.map((r) => '${r['name']} ${_n(d(r['area_m2']), 2)} m²').join(' · ')],
    for (final w in walls)
      [
        'Muro ${_n(d(w['thickness_m']) * 100, 0)} cm',
        '${_n(d(w['length_m']), 2)} m · ${_n(d(w['net_area_m2']), 2)} m² netos · ${_n(d(w['volume_m3']), 2)} m³',
      ],
    ['Revoque (2 caras)', '${_n(d(t['plaster_area_m2']), 2)} m²'],
    if (openings.isNotEmpty)
      [
        'Aberturas',
        openings
            .map((o) => '${o['count']} ${o['type'] == 'door' ? 'puerta' : 'ventana'}${o['count'] == 1 ? '' : 's'} de ${_n(d(o['width_m']), 2)} m')
            .join(' · '),
      ],
    ['Densidad de muros', 'X ${_n(d(t['wall_density_x_pct']), 2)} % · Y ${_n(d(t['wall_density_y_pct']), 2)} % de la superficie cubierta'],
    [
      'Alturas declaradas',
      'muros ${_n(d(params['wall_height_m']), 2)} m · puertas ${_n(d(params['door_height_m']), 2)} m · ventanas ${_n(d(params['window_height_m']), 2)} m',
    ],
  ];
}

const methodNotes = [
  'Sismo: fuerza lateral estática equivalente. Sa = 2,5·PGA·S, Cs = Sa/R, V = Cs·W, T ≈ 0,05·H^0,75. '
      'Capacidad τ·ΣA de los muros por dirección; torsión con diafragma rígido y excentricidad accidental de ±5 %.',
  'Tsunami (FEMA P-646 simplificado): presión hidrodinámica ½·ρs·Cd·u² (ρs = 1100 kg/m³, Cd = 2) más hidrostática; '
      'flexión fuera del plano de los muros perpendiculares al flujo, corte de los paralelos y deslizamiento F/(μ·W). '
      'Excluye impacto de escombros, socavación y subpresión.',
  'Viento: q = 0,613·V² con coeficiente neto 1,3 sobre fachadas; flexión de muros exteriores y corte basal. '
      'Sin factores normativos de exposición, topografía ni ráfaga.',
  'Semáforo de demanda/capacidad: < 0,7 dentro de lo esperable · 0,7 a 1,0 revisar · > 1,0 la demanda supera la '
      'capacidad estimada. Valores ≥ 10 se informan como "> 10 ×".',
];

// ---------------------------------------------------------------------------
// Composición del PDF
// ---------------------------------------------------------------------------

final _ink = PdfColor.fromInt(0xFF1B2230);
final _muted = PdfColor.fromInt(0xFF5B6575);
final _line = PdfColor.fromInt(0xFFD5DAE1);
final _accent = PdfColor.fromInt(0xFF2F6FDB);
final _warnBg = PdfColor.fromInt(0xFFFFF4DC);
final _warnBorder = PdfColor.fromInt(0xFFE0A030);

PdfColor statusColor(String s) => switch (s) {
  'ok' => PdfColor.fromInt(0xFF2E9D64),
  'attention' => PdfColor.fromInt(0xFFD99A1E),
  'critical' => PdfColor.fromInt(0xFFD93C44),
  _ => PdfColor.fromInt(0xFF8A93A3),
};

/// En el informe impreso el mapa usa las tres clases del semáforo (no un degradé):
/// se lee igual en papel y coincide con los indicadores. null = sin capacidad.
String ratioStatus(double? r) => r == null || r > 1.0 ? 'critical' : (r > 0.7 ? 'attention' : 'ok');

/// Reduce el raster del plano para el informe (JPEG, lado mayor ≤ [maxSide]).
Uint8List? thumbnailForReport(Uint8List? png, {int maxSide = 1400}) {
  if (png == null) return null;
  final im = img.decodeImage(png);
  if (im == null) return null;
  final s = math.max(im.width, im.height);
  final out = s > maxSide
      ? img.copyResize(im, width: im.width >= im.height ? maxSide : null, height: im.height > im.width ? maxSide : null)
      : im;
  return img.encodeJpg(out, quality: 82);
}

/// Dibuja la planta (vectores del Building Model) coloreada por relación demanda/capacidad.
pw.Widget _heatPlan(BuildingModel model, Map<String, double?> ratios, {String? flowDirection}) {
  final walls = model.allElements.whereType<Wall>().toList();
  final cols = model.allElements.whereType<ColumnElement>().toList();
  final openings = model.allElements.whereType<Opening>().toList();
  var minX = double.infinity, minY = double.infinity, maxX = -double.infinity, maxY = -double.infinity;
  for (final e in [...walls, ...cols, ...openings]) {
    final b = e.bounds;
    minX = math.min(minX, b.left);
    minY = math.min(minY, b.top);
    maxX = math.max(maxX, b.right);
    maxY = math.max(maxY, b.bottom);
  }
  if (!minX.isFinite) return pw.Text('Sin elementos para dibujar.');
  final w = math.max(1.0, maxX - minX), h = math.max(1.0, maxY - minY);
  const boxW = 240.0;
  final boxH = math.min(240.0, math.max(90.0, boxW * h / w));
  const pad = 18.0; // espacio para la flecha de dirección
  final noData = PdfColor.fromInt(heatNoData);

  return pw.CustomPaint(
    size: PdfPoint(boxW, boxH),
    painter: (canvas, size) {
      final s = math.min((size.x - 2 * pad) / w, (size.y - 2 * pad) / h);
      final ox = (size.x - w * s) / 2, oy = (size.y - h * s) / 2;
      double px(double x) => ox + (x - minX) * s;
      double py(double y) => size.y - (oy + (y - minY) * s); // PDF: origen abajo

      void quad(List<(double, double)> p, PdfColor fill, {PdfColor? stroke}) {
        canvas.moveTo(px(p[0].$1), py(p[0].$2));
        for (final q in p.skip(1)) {
          canvas.lineTo(px(q.$1), py(q.$2));
        }
        canvas.closePath();
        canvas.setFillColor(fill);
        if (stroke != null) {
          canvas
            ..setStrokeColor(stroke)
            ..setLineWidth(0.4)
            ..fillAndStrokePath();
        } else {
          canvas.fillPath();
        }
      }

      PdfColor colorFor(String id) {
        if (!ratios.containsKey(id)) return noData;
        return statusColor(ratioStatus(ratios[id]));
      }

      for (final wall in walls) {
        final dx = wall.end.x - wall.start.x, dy = wall.end.y - wall.start.y;
        final len = math.sqrt(dx * dx + dy * dy);
        if (len == 0) continue;
        final t = math.max(wall.thicknessPx, 1.5 / s) / 2;
        final nx = -dy / len * t, ny = dx / len * t;
        final ex = dx / len * t, ey = dy / len * t; // extiende en las uniones
        quad([
          (wall.start.x - ex + nx, wall.start.y - ey + ny),
          (wall.end.x + ex + nx, wall.end.y + ey + ny),
          (wall.end.x + ex - nx, wall.end.y + ey - ny),
          (wall.start.x - ex - nx, wall.start.y - ey - ny),
        ], colorFor(wall.id));
      }
      for (final c in cols) {
        final b = c.footprint;
        quad([(b.left, b.top), (b.right, b.top), (b.right, b.bottom), (b.left, b.bottom)], colorFor(c.id), stroke: _ink);
      }
      for (final o in openings) {
        final b = o.footprint;
        quad(
          [(b.left, b.top), (b.right, b.top), (b.right, b.bottom), (b.left, b.bottom)],
          o.type == OpeningType.window ? PdfColor.fromInt(0xFFDCEBFA) : PdfColors.white,
          stroke: _muted,
        );
      }

      // Flecha de la dirección del agua o del viento (en ejes del plano: y hacia abajo).
      if (flowDirection != null) {
        final (vx, vy) = switch (flowDirection) {
          'plusX' => (1.0, 0.0),
          'minusX' => (-1.0, 0.0),
          'plusY' => (0.0, 1.0),
          _ => (0.0, -1.0),
        };
        // Arranca en el borde de entrada, centrada. En el PDF la y crece hacia arriba.
        final ux = vx, uy = -vy;
        final cx = size.x / 2 - ux * (size.x / 2 - 3), cy = size.y / 2 - uy * (size.y / 2 - 3);
        final tx = cx + ux * 10, ty = cy + uy * 10;
        canvas
          ..setStrokeColor(_accent)
          ..setLineWidth(1.6)
          ..moveTo(cx, cy)
          ..lineTo(tx, ty)
          ..strokePath()
          ..setFillColor(_accent)
          ..moveTo(tx + ux * 5, ty + uy * 5)
          ..lineTo(tx - uy * 3.5, ty + ux * 3.5)
          ..lineTo(tx + uy * 3.5, ty - ux * 3.5)
          ..closePath()
          ..fillPath();
      }
    },
  );
}

pw.Widget _legend() => pw.Row(
  children: [
    for (final (st, label) in [
      ('ok', '≤ 0,7 esperable'),
      ('attention', '0,7 – 1,0 revisar'),
      ('critical', '> 1,0 supera la capacidad estimada'),
    ]) ...[
      pw.Container(width: 9, height: 9, color: statusColor(st)),
      pw.SizedBox(width: 3),
      pw.Text(label, style: pw.TextStyle(fontSize: 7.5, color: _muted)),
      pw.SizedBox(width: 10),
    ],
    pw.Container(width: 9, height: 9, color: PdfColor.fromInt(heatNoData)),
    pw.SizedBox(width: 3),
    pw.Text('sin relación calculada', style: pw.TextStyle(fontSize: 7.5, color: _muted)),
  ],
);

pw.Widget _kvTable(List<List<String>> rows, {double keyWidth = 170}) => pw.Table(
  columnWidths: {0: pw.FixedColumnWidth(keyWidth), 1: const pw.FlexColumnWidth()},
  border: pw.TableBorder(horizontalInside: pw.BorderSide(color: _line, width: 0.5)),
  children: [
    for (final r in rows)
      pw.TableRow(
        children: [
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(vertical: 3.5),
            child: pw.Text(r[0], style: pw.TextStyle(color: _muted, fontSize: 9)),
          ),
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(vertical: 3.5),
            child: pw.Text(r[1], style: const pw.TextStyle(fontSize: 9)),
          ),
        ],
      ),
  ],
);

pw.Widget _section(String title) => pw.Padding(
  padding: const pw.EdgeInsets.only(top: 14, bottom: 6),
  child: pw.Text(
    title.toUpperCase(),
    style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold, color: _accent, letterSpacing: 0.8),
  ),
);

pw.Widget _statusChip(String status) => pw.Container(
  padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 2),
  decoration: pw.BoxDecoration(color: statusColor(status), borderRadius: pw.BorderRadius.circular(3)),
  child: pw.Text(
    statusText(status).toUpperCase(),
    style: pw.TextStyle(fontSize: 7.5, color: PdfColors.white, fontWeight: pw.FontWeight.bold),
  ),
);

List<pw.Widget> _hazardSection(Map<String, Object?> r, BuildingModel model, Map<String, Object?> inputs) {
  final hazard = r['hazard'] as String;
  final ratios = <String, double?>{
    for (final e in (r['element_ratios'] as Map).entries) e.key as String: (e.value as num?)?.toDouble(),
  };
  final dir = ((inputs[hazard] as Map?)?['direction']) as String?;
  final indicators = (r['indicators'] as List).cast<Map>().map((m) => m.cast<String, Object?>()).toList();
  final assumptions = (r['assumptions'] as List).cast<String>();
  return [
    pw.Inseparable(
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          _section(hazardText(hazard)),
          pw.Row(children: [_statusChip(r['overall'] as String)]),
          pw.SizedBox(height: 8),
          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Expanded(
                child: pw.Table(
                  columnWidths: {0: const pw.FlexColumnWidth(), 1: const pw.FixedColumnWidth(62)},
                  border: pw.TableBorder(horizontalInside: pw.BorderSide(color: _line, width: 0.5)),
                  children: [
                    for (final i in indicators)
                      pw.TableRow(
                        verticalAlignment: pw.TableCellVerticalAlignment.top,
                        children: [
                          pw.Padding(
                            padding: const pw.EdgeInsets.symmetric(vertical: 4),
                            child: pw.Row(
                              crossAxisAlignment: pw.CrossAxisAlignment.start,
                              children: [
                                pw.Container(
                                  margin: const pw.EdgeInsets.only(top: 2.5, right: 5),
                                  width: 6,
                                  height: 6,
                                  decoration: pw.BoxDecoration(
                                    color: statusColor(i['status'] as String),
                                    shape: pw.BoxShape.circle,
                                  ),
                                ),
                                pw.Expanded(
                                  child: pw.Column(
                                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                                    children: [
                                      pw.Text(pdfSafe(i['label'] as String), style: const pw.TextStyle(fontSize: 8.5)),
                                      if ((i['explanation'] as String? ?? '').isNotEmpty)
                                        pw.Text(
                                          pdfSafe(i['explanation'] as String),
                                          style: pw.TextStyle(fontSize: 7.5, color: _muted),
                                        ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                          pw.Padding(
                            padding: const pw.EdgeInsets.symmetric(vertical: 4),
                            child: pw.Text(
                              indicatorValueText(i),
                              textAlign: pw.TextAlign.right,
                              style: pw.TextStyle(
                                fontSize: 9,
                                fontWeight: pw.FontWeight.bold,
                                color: statusColor(i['status'] as String),
                              ),
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
              pw.SizedBox(width: 14),
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  _heatPlan(model, ratios, flowDirection: hazard == 'seismic' ? null : dir),
                  pw.SizedBox(height: 4),
                  pw.Text(
                    hazard == 'seismic'
                        ? 'Relación demanda/capacidad por muro'
                        : 'Flecha: dirección del ${hazard == 'tsunami' ? 'agua' : 'viento'}',
                    style: pw.TextStyle(fontSize: 7, color: _muted),
                  ),
                ],
              ),
            ],
          ),
          pw.SizedBox(height: 6),
          pw.Text('Supuestos', style: pw.TextStyle(fontSize: 8.5, fontWeight: pw.FontWeight.bold)),
        ],
      ),
    ),
    for (final a in assumptions)
      pw.Padding(
        padding: const pw.EdgeInsets.only(top: 1.5, left: 6),
        child: pw.Text('• ${pdfSafe(a)}', style: pw.TextStyle(fontSize: 7.5, color: _muted)),
      ),
  ];
}

/// Compone el PDF completo. Puro Dart: se puede ejecutar en un isolate.
Future<Uint8List> buildScreeningPdf(ReportJob job) async {
  final model = BuildingModel.fromJson(job.buildingModel);
  final screening = job.screening;
  final inputs = (screening['inputs'] as Map).cast<String, Object?>();
  final disclaimer = pdfSafe(screening['disclaimer'] as String? ?? screeningDisclaimer);
  final base = pw.Font.ttf(ByteData.sublistView(job.fonts.regular));
  final bold = pw.Font.ttf(ByteData.sublistView(job.fonts.bold));
  final doc = pw.Document(
    title: 'Evaluación preliminar — ${job.projectName}',
    author: 'STRUCTURA AI',
    creator: 'STRUCTURA AI ${job.appVersion} (generado en el dispositivo)',
    subject: 'Evaluación preliminar de sismo, tsunami y viento. No es un cálculo estructural.',
    theme: pw.ThemeData.withFont(base: base, bold: bold),
  );
  final created = DateTime.tryParse(screening['created_at'] as String? ?? '') ?? job.generatedAt;
  final rows = summaryRows(screening);

  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(40, 36, 40, 36),
      maxPages: 40,
      header: (ctx) => ctx.pageNumber == 1
          ? pw.SizedBox()
          : pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 8),
              child: pw.Text(
                'STRUCTURA AI · ${pdfSafe(job.projectName)} · evaluación preliminar',
                style: pw.TextStyle(fontSize: 7.5, color: _muted),
              ),
            ),
      footer: (ctx) => pw.Container(
        padding: const pw.EdgeInsets.only(top: 6),
        decoration: pw.BoxDecoration(
          border: pw.Border(top: pw.BorderSide(color: _line, width: 0.5)),
        ),
        child: pw.Row(
          children: [
            pw.Expanded(
              child: pw.Text(
                'Evaluación preliminar: no es un cálculo estructural ni certifica la seguridad de la estructura.',
                style: pw.TextStyle(fontSize: 7, color: _muted),
              ),
            ),
            pw.Text('Página ${ctx.pageNumber} de ${ctx.pagesCount}', style: pw.TextStyle(fontSize: 7, color: _muted)),
          ],
        ),
      ),
      build: (ctx) => [
        // Encabezado
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.end,
          children: [
            pw.Expanded(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(
                    'STRUCTURA AI',
                    style: pw.TextStyle(fontSize: 9, color: _accent, fontWeight: pw.FontWeight.bold, letterSpacing: 1.2),
                  ),
                  pw.SizedBox(height: 2),
                  pw.Text(
                    'Evaluación preliminar de sismo, tsunami y viento',
                    style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold, color: _ink),
                  ),
                  pw.SizedBox(height: 2),
                  pw.Text(pdfSafe(job.projectName), style: pw.TextStyle(fontSize: 11, color: _ink)),
                ],
              ),
            ),
            pw.Text(
              'Evaluado: ${_date(created)}\nInforme: ${_date(job.generatedAt)}',
              textAlign: pw.TextAlign.right,
              style: pw.TextStyle(fontSize: 8, color: _muted),
            ),
          ],
        ),
        pw.SizedBox(height: 10),
        pw.Container(
          padding: const pw.EdgeInsets.all(8),
          decoration: pw.BoxDecoration(
            color: _warnBg,
            border: pw.Border.all(color: _warnBorder, width: 0.8),
            borderRadius: pw.BorderRadius.circular(4),
          ),
          child: pw.Text(disclaimer, style: pw.TextStyle(fontSize: 8.5, color: _ink)),
        ),

        _section('Resumen'),
        pw.Table(
          columnWidths: {0: const pw.FixedColumnWidth(92), 1: const pw.FixedColumnWidth(178), 2: const pw.FlexColumnWidth()},
          border: pw.TableBorder(horizontalInside: pw.BorderSide(color: _line, width: 0.5)),
          children: [
            for (final r in rows)
              pw.TableRow(
                verticalAlignment: pw.TableCellVerticalAlignment.middle,
                children: [
                  pw.Padding(
                    padding: const pw.EdgeInsets.symmetric(vertical: 5),
                    child: pw.Text(r.hazard, style: pw.TextStyle(fontSize: 9.5, fontWeight: pw.FontWeight.bold)),
                  ),
                  pw.Padding(
                    padding: const pw.EdgeInsets.symmetric(vertical: 5),
                    child: pw.Row(children: [_statusChip(r.status)]),
                  ),
                  pw.Padding(
                    padding: const pw.EdgeInsets.fromLTRB(6, 5, 0, 5),
                    child: pw.Text(pdfSafe(r.worst), style: const pw.TextStyle(fontSize: 8.5)),
                  ),
                ],
              ),
          ],
        ),

        _section('Plano y detección'),
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Expanded(child: _kvTable(provenanceRows(job, model), keyWidth: 110)),
            if (job.planImage != null) ...[
              pw.SizedBox(width: 14),
              pw.Container(
                width: 170,
                decoration: pw.BoxDecoration(border: pw.Border.all(color: _line, width: 0.5)),
                child: pw.Image(pw.MemoryImage(job.planImage!), fit: pw.BoxFit.contain, height: 170),
              ),
            ],
          ],
        ),

        _section('Datos declarados por el profesional'),
        _kvTable(declaredRows(screening)),

        _section('Cómo leer los resultados'),
        pw.Text(
          'En cada peligro, el plano muestra cada muro con el color de su relación demanda/capacidad estimada.',
          style: pw.TextStyle(fontSize: 8, color: _muted),
        ),
        pw.SizedBox(height: 4),
        _legend(),

        for (final r in (screening['results'] as List).cast<Map>()) ..._hazardSection(r.cast<String, Object?>(), model, inputs),

        if (job.takeoff != null) ...[
          _section('Cómputo métrico preliminar'),
          _kvTable(takeoffRows(job.takeoff!), keyWidth: 120),
          pw.SizedBox(height: 4),
          pw.Text(
            'Largos por eje de muro y superficies aproximadas desde el plano detectado. Sirve para pre-dimensionar; '
            'no reemplaza el cómputo sobre el proyecto definitivo.',
            style: pw.TextStyle(fontSize: 7.5, color: _muted),
          ),
        ],

        _section('Métodos'),
        for (final m in methodNotes)
          pw.Padding(
            padding: const pw.EdgeInsets.only(bottom: 3),
            child: pw.Text(pdfSafe(m), style: pw.TextStyle(fontSize: 8, color: _ink)),
          ),

        _section('Revisión profesional'),
        pw.Text('Observaciones:', style: pw.TextStyle(fontSize: 8.5, color: _muted)),
        for (var i = 0; i < 3; i++)
          pw.Container(
            height: 18,
            decoration: pw.BoxDecoration(
              border: pw.Border(bottom: pw.BorderSide(color: _line, width: 0.6)),
            ),
          ),
        pw.SizedBox(height: 14),
        pw.Row(
          children: [
            pw.Expanded(
              child: pw.Text('Revisó (nombre y matrícula): ______________________', style: const pw.TextStyle(fontSize: 8.5)),
            ),
            pw.Text('Fecha: ____ / ____ / ______', style: const pw.TextStyle(fontSize: 8.5)),
          ],
        ),

        _section('Trazabilidad'),
        _kvTable([
          [
            'Proyecto',
            '${pdfSafe(job.projectName)}${job.projectDescription.isEmpty ? '' : ' — ${pdfSafe(job.projectDescription)}'}',
          ],
          ['Tipo de edificio', job.buildingType],
          ['Análisis', '${job.analysisId} (${_date(job.analysisAt)})'],
          ['SHA-256 del plano', job.planSha256],
          ['Formato de la evaluación', '${screening['format']}'],
          ['Generado por', 'STRUCTURA AI ${job.appVersion}, en el dispositivo y sin conexión'],
        ], keyWidth: 120),
      ],
    ),
  );
  return doc.save();
}

// ---------------------------------------------------------------------------
// Servicio
// ---------------------------------------------------------------------------

Future<Uint8List> _buildInIsolate(ReportJob job) => Isolate.run(() => buildScreeningPdf(job));

class ReportService {
  final ProjectStore store;
  final Future<ReportFonts> Function() loadFonts;
  final String appVersion;
  const ReportService(this.store, {required this.loadFonts, this.appVersion = '0.1.0'});

  /// Genera el informe de la última evaluación y lo guarda en el proyecto.
  /// Devuelve la ruta absoluta del PDF.
  Future<String> exportScreeningReport(ProjectManifest p, {bool useIsolate = true}) async {
    final a = p.activeAnalysis;
    final plan = p.activePlan;
    if (a == null || plan == null) throw const SimulationException('Primero ejecutá el análisis del plano.');
    final rep = store.resolve(p.id, '${a.dir}/screening.json');
    if (!await rep.exists()) throw const SimulationException('Primero ejecutá la evaluación.');
    final screening = (jsonDecode(await rep.readAsString()) as Map).cast<String, Object?>();
    final bm = (jsonDecode(await store.resolve(p.id, '${a.dir}/building_model.json').readAsString()) as Map)
        .cast<String, Object?>();
    final raster = store.resolve(p.id, plan.rasterFile);
    final png = await raster.exists() ? await raster.readAsBytes() : null;
    final fonts = await loadFonts();
    final thumb = useIsolate ? await Isolate.run(() => thumbnailForReport(png)) : thumbnailForReport(png);
    Map<String, Object?>? takeoff;
    try {
      takeoff = (await TakeoffService(store).compute(p)).$1.toJson();
    } on Object {
      takeoff = null; // sin escala o modelo ilegible: el informe sale sin cómputo
    }
    final job = ReportJob(
      projectName: p.name,
      projectDescription: p.description,
      buildingType: p.buildingType.label,
      planName: plan.originalName,
      planSourceType: plan.sourceType,
      planSha256: plan.rasterSha256,
      planWidth: plan.width,
      planHeight: plan.height,
      analysisId: a.id,
      analysisAt: a.createdAt,
      engine: a.model,
      screening: screening,
      buildingModel: bm,
      planImage: thumb,
      takeoff: takeoff,
      fonts: fonts,
      generatedAt: DateTime.now(),
      appVersion: appVersion,
    );
    final bytes = useIsolate ? await _buildInIsolate(job) : await buildScreeningPdf(job);
    final rel = '${a.dir}/$reportFileName';
    await store.writeBytes(p.id, rel, bytes);
    await store.appendHistory(p.id, 'report_exported', {'file': rel, 'bytes': bytes.length});
    return store.resolve(p.id, rel).path;
  }
}
