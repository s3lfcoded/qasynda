import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'theme.dart';
import 'widgets/mark.dart';
import 'widgets/rolling_amount.dart';

const _soft = Color(0xCCFFFFFF);
const _label = Color(0xB8FFFFFF);
const _cardBack = Color(0xFF0A352F);

/// Лицевая сторона карты: глубокий бирюзовый фон, кольца радиуса в правом верхнем углу, белый текст.
/// Высота 200, радиус 24, поля 20.
class CardFront extends StatelessWidget {
  const CardFront({
    super.key,
    required this.holder,
    required this.last4,
    required this.kind,
    this.business,
  });

  final String holder;
  final String last4;

  /// Подпись справа вверху: «Виртуальная» или «Бизнес».
  final String kind;
  final String? business;

  @override
  Widget build(BuildContext context) {
    return _CardShape(
      color: Q.card,
      rings: true,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          height: 24,
          child: Row(children: [
            const QasyndaMark(size: 24, color: Q.onAccent),
            const SizedBox(width: 8),
            const Text('Qasynda', style: TextStyle(color: Q.onAccent, fontSize: 17, height: 24 / 17, fontWeight: FontWeight.w700)),
            const Spacer(),
            Text(kind, style: const TextStyle(color: _soft, fontSize: 13, height: 16 / 13, fontWeight: FontWeight.w500)),
          ]),
        ),
        const Spacer(),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('••\u00A0$last4',
                  style: const TextStyle(
                      color: Q.onAccent,
                      fontSize: 19,
                      height: 24 / 19,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.4,
                      fontFeatures: Q.tabular)),
              const SizedBox(height: 4),
              Text(business ?? holder,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: _soft, fontSize: 13, height: 16 / 13)),
            ]),
          ),
          const SizedBox(width: 12),
          const Text('KZT', style: TextStyle(color: _soft, fontSize: 14, height: 16 / 14, fontWeight: FontWeight.w600)),
        ]),
      ]),
    );
  }
}

/// Оборот виртуальной карты. Открывается закрытым: «•••• •••• •••• 4417», срок «••/••», CVV «•••»,
/// над номером «Подтвердите, чтобы показать реквизиты», справа белая кнопка «Показать» с Face ID.
/// После подтверждения номер и срок открываются roll, появляются копирование и глазок CVV.
class CardBack extends StatelessWidget {
  const CardBack({
    super.key,
    required this.title,
    required this.badge,
    required this.last4,
    required this.expiryLabel,
    required this.number,
    required this.expiry,
    required this.cvv,
    required this.cvvShown,
    required this.copyLabel,
    required this.showCvvLabel,
    required this.hideCvvLabel,
    this.revealed = true,
    this.confirmCaption = '',
    this.revealLabel = '',
    this.biometricIcon,
    this.onReveal,
    this.onCopy,
    this.onToggleCvv,
  });

  final String title;
  final String badge;
  final String last4;
  final String expiryLabel;

  /// Полный номер; null — реквизиты закрыты или ещё не загружены.
  final String? number;
  final String? expiry;
  final String? cvv;
  final bool cvvShown;
  final bool revealed;
  final String confirmCaption;
  final String revealLabel;
  final Widget? biometricIcon;
  final VoidCallback? onReveal;
  final String copyLabel;
  final String showCvvLabel;
  final String hideCvvLabel;
  final VoidCallback? onCopy;
  final VoidCallback? onToggleCvv;

  static String _group(String digits) {
    final b = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && i % 4 == 0) b.write(' ');
      b.write(digits[i]);
    }
    return b.toString();
  }

  @override
  Widget build(BuildContext context) {
    const value = TextStyle(color: Q.onAccent, fontSize: 16, height: 24 / 16, fontWeight: FontWeight.w600, fontFeatures: Q.tabular);
    const caption = TextStyle(color: _label, fontSize: 12, height: 16 / 12);
    final open = revealed && number != null;
    final masked = '•••• •••• •••• $last4';
    Widget roundButton(IconData icon, String tooltip, VoidCallback? onPressed) => SizedBox.square(
          dimension: 44,
          child: IconButton(
            onPressed: onPressed,
            tooltip: tooltip,
            padding: EdgeInsets.zero,
            style: IconButton.styleFrom(overlayColor: Colors.white24),
            icon: Icon(icon, size: 20, color: onPressed == null ? Colors.white38 : const Color(0xE0FFFFFF)),
          ),
        );

    return _CardShape(
      color: _cardBack,
      rings: false,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          height: 24,
          child: Row(children: [
            Expanded(
              child: Text(title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Q.onAccent, fontSize: 15, height: 24 / 15, fontWeight: FontWeight.w600)),
            ),
            Text(badge, style: const TextStyle(color: _soft, fontSize: 13, height: 16 / 13, fontWeight: FontWeight.w500)),
          ]),
        ),
        const Spacer(),
        AnimatedOpacity(
          duration: const Duration(milliseconds: 200),
          opacity: open ? 0 : 1,
          child: Text(confirmCaption, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: _soft, fontSize: 13, height: 16 / 13)),
        ),
        const SizedBox(height: 4),
        SizedBox(
          height: 28,
          child: Row(children: [
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: RollingAmount(
                  open ? _group(number!) : masked,
                  hidden: !open,
                  mask: masked,
                  style: const TextStyle(
                      color: Q.onAccent, fontSize: 20, height: 28 / 20, fontWeight: FontWeight.w600, letterSpacing: 0.8, fontFeatures: Q.tabular),
                ),
              ),
            ),
            if (open) ...[
              const SizedBox(width: 4),
              SizedBox(width: 44, height: 28, child: OverflowBox(maxHeight: 44, child: roundButton(Icons.content_copy_rounded, copyLabel, onCopy))),
            ],
          ]),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 40,
          child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(expiryLabel, style: caption),
              RollingAmount(open ? (expiry ?? '••/••') : '00/00', style: value, hidden: !open, mask: '••/••'),
            ]),
            const SizedBox(width: 32),
            Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('CVV', style: caption),
              Row(mainAxisSize: MainAxisSize.min, children: [
                RollingAmount(cvv ?? '000', style: value, hidden: !cvvShown || cvv == null, mask: '•••'),
                if (open) ...[
                  const SizedBox(width: 4),
                  SizedBox(
                    width: 44,
                    height: 24,
                    child: OverflowBox(
                      maxHeight: 44,
                      child: roundButton(
                        cvvShown ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                        cvvShown ? hideCvvLabel : showCvvLabel,
                        onToggleCvv,
                      ),
                    ),
                  ),
                ],
              ]),
            ]),
            const Spacer(),
            if (open)
              const Text('KZT', style: TextStyle(color: _soft, fontSize: 14, height: 24 / 14, fontWeight: FontWeight.w600))
            else
              Material(
                color: Colors.white,
                shape: const StadiumBorder(),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: onReveal,
                  child: Container(
                    height: 40,
                    padding: const EdgeInsets.only(left: 12, right: 16),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      ?biometricIcon,
                      const SizedBox(width: 8),
                      Text(revealLabel, style: const TextStyle(color: Q.ink, fontSize: 15, height: 20 / 15, fontWeight: FontWeight.w600)),
                    ]),
                  ),
                ),
              ),
          ]),
        ),
      ]),
    );
  }
}

class _CardShape extends StatelessWidget {
  const _CardShape({required this.color, required this.rings, required this.child});
  final Color color;
  final bool rings;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 200,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(24)),
      child: CustomPaint(
        painter: rings ? const _RingsPainter() : null,
        child: Padding(padding: const EdgeInsets.all(20), child: child),
      ),
    );
  }
}

/// Три кольца с центром в 48 pt от правого и верхнего края — тот же мотив, что в знаке.
class _RingsPainter extends CustomPainter {
  const _RingsPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width - 48, 48);
    Paint ring(double alpha, double width) => Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..color = Colors.white.withValues(alpha: alpha);
    canvas.drawCircle(c, 56, ring(0.10, 20));
    canvas.drawCircle(c, 104, ring(0.07, 2));
    canvas.drawCircle(c, 144, ring(0.05, 2));
  }

  @override
  bool shouldRepaint(_RingsPainter oldDelegate) => false;
}

/// Карта, которая переворачивается в 3D вокруг вертикальной оси.
/// * Нажатие или долгое нажатие (400 мс, с лёгкой вибрацией) — переворот за 640 мс,
///   Cubic(0.45, 0, 0.2, 1); на ребре карта чуть отдаляется.
/// * Свайп: угол следует за пальцем; после отпускания карта доворачивается, если угол больше 70° или
///   палец быстрый (больше 700 pt/с), иначе возвращается.
/// * [beforeBack] — подтверждение перед показом оборота (Face ID или код). Пока его нет, свайп с лица
///   карту не крутит, а только просит подтвердить.
/// При «уменьшить движение» стороны сменяются кроссфейдом без 3D.
class FlipCard extends StatefulWidget {
  const FlipCard({
    super.key,
    required this.front,
    required this.back,
    this.onSide,
    this.beforeBack,
    this.semanticLabel,
  });
  final Widget front;
  final Widget back;

  /// Сторона после поворота: true — оборот.
  final ValueChanged<bool>? onSide;
  final Future<bool> Function()? beforeBack;
  final String? semanticLabel;

  @override
  State<FlipCard> createState() => FlipCardState();
}

class FlipCardState extends State<FlipCard> with TickerProviderStateMixin {
  /// Мягкий разгон и длинная плавная посадка.
  static const _turn = Cubic(0.45, 0, 0.2, 1);
  static const _turnTime = Duration(milliseconds: 640);

  late final _anim = AnimationController.unbounded(vsync: this);
  double _base = 0;
  bool _pressed = false;
  bool _dragging = false;
  bool _gated = false;
  double _gateDx = 0;
  bool _asking = false;
  bool _back = false;

  bool get _reduced => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  /// Перевернуть (нажатием, долгим нажатием или кнопкой для экранного диктора).
  Future<void> flip([double direction = 1]) => _turnTo(_base + 180 * direction, _turnTime, _turn);

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  /// Поворот на оборот проходит через подтверждение; обратно на лицо — без него.
  Future<void> _turnTo(double target, Duration duration, Curve curve) async {
    final toBack = ((target % 360) + 360) % 360 == 180;
    if (toBack && !_back && widget.beforeBack != null) {
      if (_asking) return;
      _asking = true;
      final ok = await widget.beforeBack!();
      _asking = false;
      if (!ok || !mounted) {
        if (mounted) _animateTo(_base, const Duration(milliseconds: 280), rollCurve);
        return;
      }
    }
    await _animateTo(target, duration, curve);
  }

  void _settle(double target) {
    final normalized = ((target % 360) + 360) % 360;
    _base = normalized;
    _anim.value = normalized;
    final back = normalized == 180;
    if (back != _back) {
      _back = back;
      widget.onSide?.call(back);
    }
    if (mounted) setState(() {});
  }

  Future<void> _animateTo(double target, Duration duration, Curve curve) async {
    if (_reduced) {
      _settle(target);
      return;
    }
    await _anim.animateTo(target, duration: duration, curve: curve);
    if (mounted) _settle(target);
  }

  void _onTap() {
    if (_dragging) return;
    flip();
  }

  void _onLongPress() {
    if (_dragging) return;
    HapticFeedback.lightImpact();
    setState(() => _pressed = false);
    flip();
  }

  void _onDragStart(DragStartDetails d) {
    _dragging = true;
    _anim.stop();
    // С лица на оборот без подтверждения карта не крутится: свайп только просит подтвердить.
    _gated = !_back && widget.beforeBack != null;
    _gateDx = 0;
    setState(() => _pressed = false);
  }

  void _onDragUpdate(DragUpdateDetails d, double width) {
    if (_gated) {
      _gateDx += d.delta.dx;
      return;
    }
    if (_reduced) return;
    _anim.value = _anim.value + d.delta.dx / width * 180;
  }

  void _onDragEnd(DragEndDetails d, double width) {
    // Отмена жеста без перетаскивания (например, победило нажатие) ничего не меняет.
    if (!_dragging) return;
    _dragging = false;
    final v = d.velocity.pixelsPerSecond.dx;
    if (_gated) {
      _gated = false;
      final dir = (_gateDx != 0 ? _gateDx : v).sign;
      if (_gateDx.abs() > width * 0.2 || v.abs() > 700) flip(dir == 0 ? 1 : dir);
      return;
    }
    if (_reduced) {
      if (v.abs() > 300) flip();
      return;
    }
    final delta = _anim.value - _base;
    final dir = (delta == 0 ? v : delta).sign;
    final go = delta.abs() > 70 || v.abs() > 700;
    final target = go ? _base + 180 * (dir == 0 ? 1 : dir) : _base;
    final left = (target - _anim.value).abs();
    final ms = go ? (200 + 280 * (left / 180)).round() : 320;
    _turnTo(target, Duration(milliseconds: ms), rollCurve);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final width = box.maxWidth;
      return Semantics(
        button: true,
        label: widget.semanticLabel,
        onTap: flip,
        child: RawGestureDetector(
          gestures: {
            TapGestureRecognizer: GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
              () => TapGestureRecognizer(),
              (r) => r.onTap = _onTap,
            ),
            LongPressGestureRecognizer: GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
              () => LongPressGestureRecognizer(duration: const Duration(milliseconds: 400)),
              (r) => r
                ..onLongPressDown = ((_) => setState(() => _pressed = true))
                ..onLongPressCancel = (() => setState(() => _pressed = false))
                ..onLongPressUp = (() => setState(() => _pressed = false))
                ..onLongPress = _onLongPress,
            ),
            HorizontalDragGestureRecognizer: GestureRecognizerFactoryWithHandlers<HorizontalDragGestureRecognizer>(
              () => HorizontalDragGestureRecognizer(),
              (r) => r
                ..onStart = _onDragStart
                ..onUpdate = ((d) => _onDragUpdate(d, width))
                ..onEnd = ((d) => _onDragEnd(d, width))
                ..onCancel = (() => _onDragEnd(DragEndDetails(), width)),
            ),
          },
          child: AnimatedScale(
            scale: _pressed ? 0.98 : 1,
            duration: const Duration(milliseconds: 100),
            child: _reduced ? _crossfade() : _rotating(),
          ),
        ),
      );
    });
  }

  Widget _crossfade() => AnimatedSwitcher(
        duration: const Duration(milliseconds: 150),
        child: KeyedSubtree(key: ValueKey(_back), child: _back ? widget.back : widget.front),
      );

  Widget _rotating() {
    return AnimatedBuilder(
      animation: _anim,
      builder: (context, _) {
        final a = ((_anim.value % 360) + 360) % 360;
        final showBack = a > 90 && a < 270;
        // На ребре карта чуть отдаляется: масштаб 1 → 0.96 → 1 по синусу угла.
        final depth = 1 - 0.04 * math.sin(a * math.pi / 180).abs();
        final m = Matrix4.identity()
          ..setEntry(3, 2, 0.0012)
          ..rotateY(a * math.pi / 180)
          ..scaleByDouble(depth, depth, 1, 1);
        return Transform(
          alignment: Alignment.center,
          transform: m,
          child: showBack
              ? Transform(alignment: Alignment.center, transform: Matrix4.rotationY(math.pi), child: widget.back)
              : widget.front,
        );
      },
    );
  }
}
