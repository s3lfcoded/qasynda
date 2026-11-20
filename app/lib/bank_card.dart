import 'package:material_ui/material_ui.dart';

import 'theme.dart';

/// Плоская карта клиента: чёрная, с лаймовыми деталями, без объёма и теней.
/// Дуги справа повторяют знак приложения: волны от того, кто рядом.
/// Раз в несколько секунд по дугам проходит перелив — узкая полоса света, как на голограмме карты.
class BankCard extends StatefulWidget {
  const BankCard({super.key, required this.holder, required this.last4, this.business});
  final String holder;
  final String last4;
  final String? business;

  static const _face = Color(0xFF131315);
  static const _arc = Color(0xFF232327);

  @override
  State<BankCard> createState() => _BankCardState();
}

class _BankCardState extends State<BankCard> with SingleTickerProviderStateMixin {
  late final _shimmer = AnimationController(vsync: this, duration: const Duration(milliseconds: 5200));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Если в системе отключены анимации, карта остаётся неподвижной.
    if (MediaQuery.of(context).disableAnimations) {
      _shimmer.stop();
    } else if (!_shimmer.isAnimating) {
      _shimmer.repeat();
    }
  }

  @override
  void dispose() {
    _shimmer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final business = widget.business;
    final holder = widget.holder;
    final last4 = widget.last4;
    return AspectRatio(
      aspectRatio: 1.586, // пропорции настоящей банковской карты
      child: DecoratedBox(
        // Рамка рисуется поверх, чтобы дуги не выходили за скруглённые углы.
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(Q.radius),
          border: Border.all(color: Q.line),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(Q.radius),
          child: CustomPaint(
            // Перерисовывается только фон карты, текст поверх него не трогается.
            painter: _CardPainter(_shimmer),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 20, 22, 20),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  const Text('Qasynda',
                      style: TextStyle(color: Q.text, fontSize: 19, fontWeight: FontWeight.w900, letterSpacing: -0.4)),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                    decoration: BoxDecoration(
                      border: Border.all(color: Q.accent, width: 1.4),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(business == null ? 'DEBIT' : 'BUSINESS',
                        style: const TextStyle(
                            color: Q.accent, fontSize: 10.5, fontWeight: FontWeight.w800, letterSpacing: 1.2)),
                  ),
                ]),
                const Spacer(),
                const Row(children: [
                  _Chip(),
                  SizedBox(width: 12),
                  Icon(Icons.contactless_outlined, color: Q.muted, size: 26),
                ]),
                const Spacer(),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text('••••  ••••  ••••  $last4',
                      style: const TextStyle(
                          color: Q.text,
                          fontSize: 21,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.6,
                          fontFeatures: Q.tabular)),
                ),
                const SizedBox(height: 10),
                Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Expanded(
                    child: Text((business ?? holder).toUpperCase(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Q.muted, fontSize: 12.5, fontWeight: FontWeight.w700, letterSpacing: 0.9)),
                  ),
                  const SizedBox(width: 12),
                  const Text('KZT',
                      style: TextStyle(color: Q.muted, fontSize: 12.5, fontWeight: FontWeight.w800, letterSpacing: 1.4)),
                ]),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// Контактная площадка чипа: лаймовый прямоугольник с тёмными дорожками.
class _Chip extends StatelessWidget {
  const _Chip();

  @override
  Widget build(BuildContext context) =>
      const SizedBox(width: 46, height: 34, child: CustomPaint(painter: _ChipPainter()));
}

class _ChipPainter extends CustomPainter {
  const _ChipPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = Q.onAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;
    final body = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(7));
    canvas.drawRRect(body, Paint()..color = Q.accent);
    final w = size.width, h = size.height;
    // центральная площадка и дорожки к краям
    final pad = RRect.fromRectAndRadius(Rect.fromLTWH(w * 0.34, h * 0.28, w * 0.32, h * 0.44), const Radius.circular(3));
    canvas.drawRRect(pad, line);
    canvas.drawLine(Offset(0, h * 0.36), Offset(w * 0.34, h * 0.36), line);
    canvas.drawLine(Offset(0, h * 0.64), Offset(w * 0.34, h * 0.64), line);
    canvas.drawLine(Offset(w * 0.66, h * 0.36), Offset(w, h * 0.36), line);
    canvas.drawLine(Offset(w * 0.66, h * 0.64), Offset(w, h * 0.64), line);
    canvas.drawLine(Offset(w * 0.5, 0), Offset(w * 0.5, h * 0.28), line);
    canvas.drawLine(Offset(w * 0.5, h * 0.72), Offset(w * 0.5, h), line);
  }

  @override
  bool shouldRepaint(_ChipPainter oldDelegate) => false;
}

class _CardPainter extends CustomPainter {
  _CardPainter(this.shimmer) : super(repaint: shimmer);
  final Animation<double> shimmer;

  /// Доля цикла, за которую полоса проходит карту; остальное время карта спокойна.
  static const _sweep = 0.42;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = BankCard._face);

    final origin = Offset(size.width * 0.86, size.height * 0.5);
    void arcs(Paint paint) {
      for (var i = 1; i <= 7; i++) {
        canvas.drawCircle(origin, size.height * 0.16 * i, paint);
      }
    }

    arcs(Paint()
      ..color = BankCard._arc
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4);

    final t = shimmer.value;
    if (shimmer.isAnimating && t < _sweep) {
      // Полоса шириной в половину карты едет слева направо под наклоном.
      final progress = Curves.easeInOut.transform(t / _sweep);
      final band = size.width * 0.55;
      final x = -band + (size.width + band) * progress;
      final bandRect = Rect.fromLTWH(x, -size.height * 0.3, band, size.height * 1.6);

      // Свет на самой поверхности: едва заметный.
      canvas.drawRect(
        rect,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0x00FFFFFF), Color(0x0DFFFFFF), Color(0x00FFFFFF)],
          ).createShader(bandRect),
      );
      // Дуги под полосой загораются и меняют оттенок: лайм → мята → холодный голубой.
      arcs(Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0x00C9F24B), Color(0xE6C9F24B), Color(0xF07DF0C0), Color(0xE67FB0FF), Color(0x007FB0FF)],
          stops: [0.0, 0.3, 0.5, 0.7, 1.0],
        ).createShader(bandRect));
    }

    // единственная постоянная лаймовая точка рисунка — «вы здесь»
    canvas.drawCircle(origin, 4, Paint()..color = Q.accent);
  }

  @override
  bool shouldRepaint(_CardPainter oldDelegate) => oldDelegate.shimmer != shimmer;
}
