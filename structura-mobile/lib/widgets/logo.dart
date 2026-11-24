
import 'package:flutter/material.dart';

import '../app/theme.dart';

/// Marca STRUCTURA: una planta mínima (muros, vano y columna) que se dibuja
/// trazo a trazo y se eleva en isométrico. [progress] 0..1.
class StructuraLogo extends StatelessWidget {
  final double progress;
  const StructuraLogo({super.key, this.progress = 1});
  @override
  Widget build(BuildContext context) => CustomPaint(painter: _LogoPainter(progress));
}

class _LogoPainter extends CustomPainter {
  final double t;
  _LogoPainter(this.t);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final plan = Path()
      ..moveTo(0.15 * s, 0.25 * s)
      ..lineTo(0.42 * s, 0.25 * s)
      ..moveTo(0.58 * s, 0.25 * s) // vano
      ..lineTo(0.85 * s, 0.25 * s)
      ..lineTo(0.85 * s, 0.75 * s)
      ..lineTo(0.15 * s, 0.75 * s)
      ..lineTo(0.15 * s, 0.25 * s)
      ..moveTo(0.5 * s, 0.75 * s)
      ..lineTo(0.5 * s, 0.48 * s);
    final paint = Paint()
      ..color = StructuraColors.accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.045
      ..strokeCap = StrokeCap.square;
    final metrics = plan.computeMetrics().toList();
    final total = metrics.fold<double>(0, (a, m) => a + m.length);
    var remaining = total * t;
    for (final m in metrics) {
      if (remaining <= 0) break;
      canvas.drawPath(m.extractPath(0, remaining.clamp(0, m.length)), paint);
      remaining -= m.length;
    }
    // Columna
    if (t > 0.85) {
      final a = ((t - 0.85) / 0.15).clamp(0.0, 1.0);
      canvas.drawRect(
        Rect.fromCenter(center: Offset(0.72 * s, 0.6 * s), width: 0.08 * s, height: 0.08 * s),
        Paint()..color = StructuraColors.column.withValues(alpha: a),
      );
    }
    // Arco de puerta
    if (t > 0.7) {
      final a = ((t - 0.7) / 0.3).clamp(0.0, 1.0);
      canvas.drawArc(Rect.fromCircle(center: Offset(0.42 * s, 0.25 * s), radius: 0.16 * s), 0, 1.5708 * a, false,
          Paint()
            ..color = StructuraColors.teal.withValues(alpha: 0.8)
            ..style = PaintingStyle.stroke
            ..strokeWidth = s * 0.015);
    }
  }

  @override
  bool shouldRepaint(_LogoPainter old) => old.t != t;
}
