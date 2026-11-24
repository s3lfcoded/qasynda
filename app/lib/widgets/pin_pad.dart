import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../theme.dart';
import 'shake.dart';

/// PIN на собственной цифровой клавиатуре: точки, клавиши 1–9 и 0, «удалить».
/// После последней цифры PIN сразу уходит в [onSubmit]; пока ответа нет, клавиатура не принимает ввод.
/// [onSubmit] возвращает false при ошибке — точки встряхиваются и очищаются.
/// [leading] — клавиша слева от 0 (например, Face ID); без неё место пустое.
/// Цифры можно вводить и с аппаратной клавиатуры.
class PinPad extends StatefulWidget {
  const PinPad({
    super.key,
    required this.onSubmit,
    this.length = 4,
    this.leading,
    this.deleteLabel = 'Удалить',
    this.expand = false,
  });

  final Future<bool> Function(String pin) onSubmit;
  final int length;
  final Widget? leading;
  final String deleteLabel;

  /// Точки сверху, клавиатура прижата вниз (24 до safe area): для экранов входа и блокировки.
  final bool expand;

  static const keySize = 72.0;

  @override
  State<PinPad> createState() => _PinPadState();
}

class _PinPadState extends State<PinPad> {
  String _pin = '';
  bool _busy = false;
  int _errors = 0;

  void _digit(String digit) {
    if (_busy || _pin.length >= widget.length) return;
    HapticFeedback.selectionClick();
    setState(() => _pin += digit);
    if (_pin.length == widget.length) _submit();
  }

  void _delete() {
    if (_busy || _pin.isEmpty) return;
    HapticFeedback.selectionClick();
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  Future<void> _submit() async {
    setState(() => _busy = true);
    var ok = false;
    try {
      ok = await widget.onSubmit(_pin);
    } finally {
      if (mounted) {
        if (!ok) HapticFeedback.heavyImpact();
        setState(() {
          _busy = false;
          if (!ok) {
            _pin = '';
            _errors++;
          }
        });
      }
    }
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final char = event.character;
    if (char != null && RegExp(r'^[0-9]$').hasMatch(char)) {
      _digit(char);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.backspace) {
      _delete();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final dots = Semantics(
      label: '${_pin.length} / ${widget.length}',
      liveRegion: true,
      child: Shake(
        trigger: _errors,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          for (var i = 0; i < widget.length; i++) ...[
            if (i > 0) const SizedBox(width: 16),
            _Dot(index: i, filled: i < _pin.length, animate: !reduced),
          ],
        ]),
      ),
    );
    final keypad = Keypad(
      onDigit: _digit,
      onDelete: _pin.isEmpty ? null : _delete,
      leading: widget.leading,
      deleteLabel: widget.deleteLabel,
    );
    final busy = SizedBox(
      height: 24,
      child: _busy
          ? const Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)))
          : null,
    );

    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: widget.expand
          ? Column(children: [dots, const SizedBox(height: 8), busy, const Spacer(), keypad, const SizedBox(height: 24)])
          : Column(mainAxisSize: MainAxisSize.min, children: [dots, const SizedBox(height: 8), busy, const SizedBox(height: 16), keypad]),
    );
  }
}

/// Точка PIN 16×16: пустая — surface2, заполненная — accent; заполняется с лёгким увеличением.
class _Dot extends StatelessWidget {
  const _Dot({required this.index, required this.filled, required this.animate});
  final int index;
  final bool filled;
  final bool animate;

  @override
  Widget build(BuildContext context) {
    final dot = Container(
      key: ValueKey('pin-dot-$index'),
      width: 16,
      height: 16,
      decoration: BoxDecoration(shape: BoxShape.circle, color: filled ? Q.accent : Q.surface2),
    );
    if (!animate || !filled) return dot;
    return TweenAnimationBuilder<double>(
      key: ValueKey('pin-dot-anim-$index'),
      tween: Tween(begin: 0.6, end: 1),
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOutBack,
      builder: (_, scale, child) => Transform.scale(scale: scale, child: child),
      child: dot,
    );
  }
}

/// Цифровая клавиатура: 3 колонки во всю ширину минус 16 с каждой стороны, между рядами 8.
/// Нажатая клавиша — круг цвета surface. Слева внизу [leading] (Face ID) или пусто, справа «стереть».
/// PIN: клавиши 72, цифры 30. Сумма: клавиши 56, цифры 26.
class Keypad extends StatelessWidget {
  const Keypad({
    super.key,
    required this.onDigit,
    required this.onDelete,
    this.leading,
    this.deleteLabel = 'Удалить',
    this.keyHeight = PinPad.keySize,
    this.fontSize = 30,
  });

  final ValueChanged<String> onDigit;
  final VoidCallback? onDelete;
  final Widget? leading;
  final String deleteLabel;
  final double keyHeight;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    Widget digit(String d) => _PadKey(
          size: keyHeight,
          onTap: () => onDigit(d),
          child: Text(d,
              style: TextStyle(fontSize: fontSize, height: 1.2, fontWeight: FontWeight.w500, color: Q.ink, fontFeatures: Q.tabular)),
        );
    Widget row(List<Widget> keys) => Row(children: [for (final k in keys) Expanded(child: k)]);
    const gap = SizedBox(height: 8);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        row([digit('1'), digit('2'), digit('3')]),
        gap,
        row([digit('4'), digit('5'), digit('6')]),
        gap,
        row([digit('7'), digit('8'), digit('9')]),
        gap,
        row([
          SizedBox(height: keyHeight, child: Center(child: leading)),
          digit('0'),
          _PadKey(
            size: keyHeight,
            onTap: onDelete,
            semanticLabel: deleteLabel,
            child: const Icon(Icons.backspace_outlined, size: 28),
          ),
        ]),
      ]),
    );
  }
}

class _PadKey extends StatelessWidget {
  const _PadKey({required this.size, required this.onTap, required this.child, this.semanticLabel});
  final double size;
  final VoidCallback? onTap;
  final Widget child;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: onTap != null,
      label: semanticLabel,
      excludeSemantics: semanticLabel != null,
      child: SizedBox(
        height: size,
        child: InkResponse(
          onTap: onTap,
          radius: size / 2,
          containedInkWell: false,
          highlightShape: BoxShape.circle,
          highlightColor: Q.surface,
          splashColor: Colors.transparent,
          splashFactory: NoSplash.splashFactory,
          child: Center(
            child: IconTheme.merge(
              data: IconThemeData(color: onTap == null ? Q.ink3 : Q.ink),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}
