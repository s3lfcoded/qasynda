import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../theme.dart';
import 'shake.dart';

/// Код из SMS в отдельных ячейках. Под ячейками лежит одно невидимое поле: через него работают
/// системная подстановка кода из SMS (AutofillHints.oneTimeCode), вставка по долгому нажатию
/// и обычная клавиатура. Кнопка «Вставить» берёт цифры из буфера обмена.
/// После последней цифры код сразу уходит в [onCompleted]; false — ошибка, ячейки встряхиваются и очищаются.
class CodeCells extends StatefulWidget {
  const CodeCells({
    super.key,
    required this.onCompleted,
    this.length = 6,
    this.pasteLabel = 'Вставить',
    this.semanticLabel,
    this.showPaste = true,
    this.footer,
  });

  final Future<bool> Function(String code) onCompleted;
  final int length;
  final String pasteLabel;
  final String? semanticLabel;

  /// Кнопка «Вставить» под ячейками; её можно убрать, если вставка есть рядом (плашка учебного SMS).
  final bool showPaste;

  /// Строка под ячейками слева, например «Отправить код ещё раз через 0:42».
  final Widget? footer;

  @override
  State<CodeCells> createState() => CodeCellsState();
}

class CodeCellsState extends State<CodeCells> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  bool _busy = false;
  int _errors = 0;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _changed(String text) {
    setState(() {});
    if (text.length == widget.length && !_busy) _submit(text);
  }

  Future<void> _submit(String code) async {
    setState(() => _busy = true);
    var ok = false;
    try {
      ok = await widget.onCompleted(code);
    } finally {
      if (mounted) {
        if (!ok) {
          HapticFeedback.heavyImpact();
          _controller.clear();
          _errors++;
          _focus.requestFocus();
        }
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final digits = (data?.text ?? '').replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty || _busy || !mounted) return;
    fill(digits);
  }

  /// Подставляет код, как если бы его вставили из буфера обмена.
  void fill(String digits) {
    if (digits.isEmpty || _busy) return;
    final code = digits.length > widget.length ? digits.substring(0, widget.length) : digits;
    _controller.value = TextEditingValue(text: code, selection: TextSelection.collapsed(offset: code.length));
    _changed(code);
  }

  @override
  Widget build(BuildContext context) {
    final text = _controller.text;
    final half = widget.length ~/ 2;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Shake(
        trigger: _errors,
        child: SizedBox(
          height: 56,
          child: LayoutBuilder(builder: (context, box) {
            // Ячейки 48×56 по 8 между ними, тройки разделены гибким промежутком; на узком экране ячейки сужаются.
            final cell = ((box.maxWidth - 8 * (widget.length - 1)) / widget.length).clamp(32.0, 48.0);
            return Stack(children: [
              Row(children: [
                for (var i = 0; i < widget.length; i++) ...[
                  if (i == half && widget.length > 3) const Spacer() else if (i > 0) const SizedBox(width: 8),
                  SizedBox(
                    width: cell,
                    child: _cell(i < text.length ? text[i] : '', _focus.hasFocus && !_busy && i == text.length),
                  ),
                ],
              ]),
              Positioned.fill(
                child: TextSelectionTheme(
                  data: const TextSelectionThemeData(selectionColor: Colors.transparent),
                  child: TextField(
                    controller: _controller,
                    focusNode: _focus,
                    autofocus: true,
                    readOnly: _busy,
                    keyboardType: TextInputType.number,
                    autofillHints: const [AutofillHints.oneTimeCode],
                    autocorrect: false,
                    enableSuggestions: false,
                    showCursor: false,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(widget.length),
                    ],
                    style: const TextStyle(color: Colors.transparent),
                    decoration: InputDecoration(
                      filled: false,
                      border: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding: EdgeInsets.zero,
                      counterText: '',
                      semanticCounterText: '',
                      labelText: widget.semanticLabel,
                      labelStyle: const TextStyle(color: Colors.transparent),
                      floatingLabelBehavior: FloatingLabelBehavior.never,
                    ),
                    onChanged: _changed,
                  ),
                ),
              ),
            ]);
          }),
        ),
      ),
      if (widget.footer != null || widget.showPaste) ...[
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: widget.footer ?? const SizedBox.shrink()),
          if (widget.showPaste)
            TextButton.icon(
              onPressed: _busy ? null : _paste,
              icon: const Icon(Icons.content_paste_rounded, size: 18),
              label: Text(widget.pasteLabel),
            ),
        ]),
      ],
    ]);
  }

  Widget _cell(String digit, bool active) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOut,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: active ? Q.bg : Q.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: active ? Q.accent : Q.surface, width: 2),
      ),
      child: active
          ? Container(width: 2, height: 28, decoration: BoxDecoration(color: Q.accent, borderRadius: BorderRadius.circular(1)))
          : Text(digit,
              style: const TextStyle(fontSize: 26, height: 32 / 26, fontWeight: FontWeight.w600, color: Q.ink, fontFeatures: Q.tabular)),
    );
  }
}
