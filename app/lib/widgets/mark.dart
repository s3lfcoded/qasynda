import 'dart:math' as math;

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
  const MarkPainter(this.color, {this.ring = 1, this.needleTurn = 0, this.needleScale = 1, this.needleOpacity = 1});
  final Color color;

  /// Доля прорисованного кольца (0..1), от острия стрелки по часовой.
  final double ring;

  /// Поворот стрелки в градусах вокруг центра; 0 — северо-восток.
  final double needleTurn;
  final double needleScale;
  final double needleOpacity;

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

    if (ring > 0) {
      canvas.saveLayer(const Rect.fromLTWH(-8, -8, 64, 64), Paint());
      final stroke = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..color = color;
      if (ring >= 1) {
        canvas.drawCircle(const Offset(24, 24), 17, stroke);
      } else {
        canvas.drawArc(Rect.fromCircle(center: const Offset(24, 24), radius: 17), -math.pi / 4, 2 * math.pi * ring, false, stroke);
      }
      // Зазор у острия статичен: вырезается там, где стрелка в покое.
      canvas.drawPath(_north(), Paint()..blendMode = BlendMode.clear);
      canvas.drawPath(
        _north(),
        Paint()
          ..blendMode = BlendMode.clear
          ..style = PaintingStyle.stroke
          ..strokeWidth = 5
          ..strokeJoin = StrokeJoin.round,
      );
      canvas.restore();
    }

    if (needleOpacity > 0) {
      canvas.save();
      canvas.translate(24, 24);
      canvas.rotate(needleTurn * math.pi / 180);
      canvas.scale(needleScale);
      canvas.translate(-24, -24);
      final a = (color.a * needleOpacity).clamp(0.0, 1.0);
      canvas.drawPath(_north(), Paint()..color = color.withValues(alpha: a));
      canvas.drawPath(_south(), Paint()..color = color.withValues(alpha: a * 0.35));
      canvas.restore();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(MarkPainter old) =>
      old.color != color ||
      old.ring != ring ||
      old.needleTurn != needleTurn ||
      old.needleScale != needleScale ||
      old.needleOpacity != needleOpacity;
}

/// Появление знака (около 860 мс): кольцо прорисовывается от острия, стрелка влетает вращением
/// с пружинным доводом, затем проявляется [label] и поднимается на 4 pt. Нажатие на знак повторяет.
/// [once] — проигрывать один раз за запуск приложения (экран номера). При «уменьшить движение» — сразу целиком.
class AnimatedMark extends StatefulWidget {
  const AnimatedMark({
    super.key,
    this.size = 32,
    this.color = Q.accent,
    this.label,
    this.vertical = false,
    this.gap = 8,
    this.once = false,
  });
  final double size;
  final Color color;
  final Widget? label;
  final bool vertical;
  final double gap;
  final bool once;

  static bool _played = false;

  @override
  State<AnimatedMark> createState() => _AnimatedMarkState();
}

class _AnimatedMarkState extends State<AnimatedMark> with SingleTickerProviderStateMixin {
  static const _total = 860;
  static const _ringCurve = Cubic(0.65, 0, 0.35, 1);
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: _total));
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (reduced || (widget.once && AnimatedMark._played)) {
      _c.value = 1;
    } else {
      if (widget.once) AnimatedMark._played = true;
      _c.forward();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _replay() {
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) return;
    _c.forward(from: 0);
  }

  /// Пружина: stiffness 220, damping ratio 0.75, mass 1 — перелёт около 6°, без дрожания.
  static double _spring(double seconds) {
    final w = math.sqrt(220);
    const z = 0.75;
    final wd = w * math.sqrt(1 - z * z);
    return 1 - math.exp(-z * w * seconds) * (math.cos(wd * seconds) + z * w / wd * math.sin(wd * seconds));
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final ms = _c.value * _total;
        final done = _c.value >= 1;
        final ring = done ? 1.0 : _ringCurve.transform((ms / 520).clamp(0.0, 1.0));
        final p = ((ms - 200) / 600).clamp(0.0, 1.0);
        final v = done ? 1.0 : _spring(p * 0.6);
        final mark = GestureDetector(
          onTap: _replay,
          child: SizedBox.square(
            dimension: widget.size,
            child: CustomPaint(
              painter: MarkPainter(
                widget.color,
                ring: ring,
                needleTurn: -200 + 200 * v,
                needleScale: 0.6 + 0.4 * math.min(1, p * 2.5),
                needleOpacity: math.min(1, p * 5),
              ),
            ),
          ),
        );
        final label = widget.label;
        if (label == null) return mark;
        final w = done ? 1.0 : const Cubic(0.33, 1, 0.68, 1).transform(((ms - 560) / 300).clamp(0.0, 1.0));
        final shown = Opacity(opacity: w, child: Transform.translate(offset: Offset(0, 4 * (1 - w)), child: label));
        return widget.vertical
            ? Column(mainAxisSize: MainAxisSize.min, children: [mark, SizedBox(height: widget.gap), shown])
            : Row(mainAxisSize: MainAxisSize.min, children: [mark, SizedBox(width: widget.gap), shown]);
      },
    );
  }
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
