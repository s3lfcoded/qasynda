import 'package:material_ui/material_ui.dart';

import 'theme.dart';

/// Плоская карта клиента: без объёма, теней и градиентов — только цвет, линии и текст.
/// Дуги справа повторяют знак приложения: волны от того, кто рядом.
class BankCard extends StatelessWidget {
  const BankCard({super.key, required this.holder, required this.last4, this.business});
  final String holder;
  final String last4;
  final String? business;

  @override
  Widget build(BuildContext context) {
    const ink = Q.onAccent;
    return AspectRatio(
      aspectRatio: 1.586, // пропорции настоящей банковской карты
      child: ClipRRect(
        borderRadius: BorderRadius.circular(Q.radius),
        child: CustomPaint(
          painter: const _CardPainter(),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 20, 22, 20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Text('Qasynda',
                    style: TextStyle(color: ink, fontSize: 19, fontWeight: FontWeight.w900, letterSpacing: -0.4)),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                  decoration: BoxDecoration(
                    border: Border.all(color: ink, width: 1.4),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(business == null ? 'DEBIT' : 'BUSINESS',
                      style: const TextStyle(color: ink, fontSize: 10.5, fontWeight: FontWeight.w800, letterSpacing: 1.2)),
                ),
              ]),
              const Spacer(),
              const Row(children: [
                _Chip(),
                SizedBox(width: 12),
                Icon(Icons.contactless_outlined, color: ink, size: 26),
              ]),
              const Spacer(),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text('••••  ••••  ••••  $last4',
                    style: const TextStyle(
                        color: ink, fontSize: 21, fontWeight: FontWeight.w700, letterSpacing: 1.6, fontFeatures: Q.tabular)),
              ),
              const SizedBox(height: 10),
              Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Expanded(
                  child: Text((business ?? holder).toUpperCase(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: ink, fontSize: 12.5, fontWeight: FontWeight.w700, letterSpacing: 0.9)),
                ),
                const SizedBox(width: 12),
                const Text('KZT',
                    style: TextStyle(color: ink, fontSize: 12.5, fontWeight: FontWeight.w800, letterSpacing: 1.4)),
              ]),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Контактная площадка чипа: прямоугольник с дорожками.
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
    canvas.drawRRect(body, Paint()..color = Q.accentDeep);
    canvas.drawRRect(body.deflate(0.7), line);
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
  const _CardPainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Q.accent);
    final arc = Paint()
      ..color = Q.accentDeep
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;
    final origin = Offset(size.width * 0.86, size.height * 0.5);
    for (var i = 1; i <= 7; i++) {
      canvas.drawCircle(origin, size.height * 0.16 * i, arc);
    }
    canvas.drawCircle(origin, 4, Paint()..color = Q.accentDeep);
  }

  @override
  bool shouldRepaint(_CardPainter oldDelegate) => false;
}
