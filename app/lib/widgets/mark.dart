import 'package:material_ui/material_ui.dart';

import '../theme.dart';

/// Знак Qasynda — компас радиуса. Кольцо — радиус, в котором вас видят; стрелка на северо-восток —
/// к тому, кому переводите. Северная половина прорезает кольцо, южная — 35% цвета. Сетка 48×48.
class QasyndaMark extends StatelessWidget {
  const QasyndaMark({super.key, this.size = 32, this.color = Q.accent});
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox.square(
        dimension: size,
        child: CustomPaint(painter: MarkPainter(color)),
      );
}

class MarkPainter extends CustomPainter {
  const MarkPainter(this.color);
  final Color color;

  static Path _north() => Path()
    ..moveTo(38.85, 9.15)
    ..lineTo(27.89, 27.89)
    ..lineTo(20.11, 20.11)
    ..close();

  static Path _south() => Path()
    ..moveTo(14.81, 33.19)
    ..lineTo(27.89, 27.89)
    ..lineTo(20.11, 20.11)
    ..close();

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.shortestSide / 48;
    canvas.save();
    canvas.translate((size.width - 48 * k) / 2, (size.height - 48 * k) / 2);
    canvas.scale(k);

    canvas.saveLayer(const Rect.fromLTWH(0, 0, 48, 48), Paint());
    canvas.drawCircle(
      const Offset(24, 24),
      17,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..color = color,
    );
    final cut = Paint()..blendMode = BlendMode.clear;
    canvas.drawPath(_north(), cut);
    canvas.drawPath(
      _north(),
      Paint()
        ..blendMode = BlendMode.clear
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.restore();

    canvas.drawPath(_north(), Paint()..color = color);
    canvas.drawPath(_south(), Paint()..color = color.withValues(alpha: color.a * 0.35));
    canvas.restore();
  }

  @override
  bool shouldRepaint(MarkPainter oldDelegate) => oldDelegate.color != color;
}

/// Значок Face ID из макета (32×32, линия 2.2). На Android вместо него — отпечаток.
class FaceIdIcon extends StatelessWidget {
  const FaceIdIcon({super.key, this.size = 32, this.color = Q.accent});
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) =>
      SizedBox.square(dimension: size, child: CustomPaint(painter: _FaceIdPainter(color)));
}

class _FaceIdPainter extends CustomPainter {
  const _FaceIdPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.shortestSide / 32;
    canvas.scale(k);
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    const r = Radius.circular(3.5);
    final corners = Path()
      ..moveTo(4, 10)
      ..lineTo(4, 7.5)
      ..arcToPoint(const Offset(7.5, 4), radius: r)
      ..lineTo(10, 4)
      ..moveTo(22, 4)
      ..lineTo(24.5, 4)
      ..arcToPoint(const Offset(28, 7.5), radius: r)
      ..lineTo(28, 10)
      ..moveTo(28, 22)
      ..lineTo(28, 24.5)
      ..arcToPoint(const Offset(24.5, 28), radius: r)
      ..lineTo(22, 28)
      ..moveTo(10, 28)
      ..lineTo(7.5, 28)
      ..arcToPoint(const Offset(4, 24.5), radius: r)
      ..lineTo(4, 22);
    final face = Path()
      ..moveTo(11, 12)
      ..lineTo(11, 14.5)
      ..moveTo(21, 12)
      ..lineTo(21, 14.5)
      ..moveTo(16.5, 12)
      ..lineTo(16.5, 17.5)
      ..lineTo(15, 17.5)
      ..moveTo(11.5, 21.5)
      ..quadraticBezierTo(16, 24.5, 20.5, 21.5);
    canvas.drawPath(corners, p);
    canvas.drawPath(face, p);
  }

  @override
  bool shouldRepaint(_FaceIdPainter oldDelegate) => oldDelegate.color != color;
}
