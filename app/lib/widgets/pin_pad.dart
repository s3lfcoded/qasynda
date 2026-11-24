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
  });

  final Future<bool> Function(String pin) onSubmit;
  final int length;
  final Widget? leading;
  final String deleteLabel;

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
    Widget digit(String d) => _PadKey(onTap: () => _digit(d), child: Text(d, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w600, fontFeatures: Q.tabular)));
    Widget row(List<Widget> keys) => Row(mainAxisSize: MainAxisSize.min, children: [
          for (var i = 0; i < keys.length; i++) ...[if (i > 0) const SizedBox(width: 24), keys[i]],
        ]);
    const gap = SizedBox(height: 14);

    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Semantics(
          label: '${_pin.length} / ${widget.length}',
          liveRegion: true,
          child: Shake(
            trigger: _errors,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              for (var i = 0; i < widget.length; i++)
                Container(
                  key: ValueKey('pin-dot-$i'),
                  width: 14,
                  height: 14,
                  margin: const EdgeInsets.symmetric(horizontal: 9),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: i < _pin.length ? Q.accent : Colors.transparent,
                    border: Border.all(color: i < _pin.length ? Q.accent : Q.faint, width: 1.5),
                  ),
                ),
            ]),
          ),
        ),
        SizedBox(
          height: 40,
          child: _busy
              ? const Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)))
              : null,
        ),
        row([digit('1'), digit('2'), digit('3')]),
        gap,
        row([digit('4'), digit('5'), digit('6')]),
        gap,
        row([digit('7'), digit('8'), digit('9')]),
        gap,
        row([
          SizedBox.square(dimension: PinPad.keySize, child: Center(child: widget.leading)),
          digit('0'),
          _PadKey(
            onTap: _pin.isEmpty ? null : _delete,
            plain: true,
            semanticLabel: widget.deleteLabel,
            child: const Icon(Icons.backspace_outlined, size: 26),
          ),
        ]),
      ]),
    );
  }
}

class _PadKey extends StatelessWidget {
  const _PadKey({required this.onTap, required this.child, this.plain = false, this.semanticLabel});
  final VoidCallback? onTap;
  final Widget child;
  final bool plain;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: onTap != null,
      label: semanticLabel,
      excludeSemantics: semanticLabel != null,
      child: SizedBox.square(
        dimension: PinPad.keySize,
        child: Material(
          color: plain ? Colors.transparent : Q.surface,
          shape: CircleBorder(side: plain ? BorderSide.none : const BorderSide(color: Q.line)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Center(
              child: IconTheme.merge(
                data: IconThemeData(color: onTap == null ? Q.faint : Q.text),
                child: DefaultTextStyle.merge(style: const TextStyle(color: Q.text), child: child),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
