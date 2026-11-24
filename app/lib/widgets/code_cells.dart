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
  });

  final Future<bool> Function(String code) onCompleted;
  final int length;
  final String pasteLabel;
  final String? semanticLabel;

  @override
  State<CodeCells> createState() => _CodeCellsState();
}

class _CodeCellsState extends State<CodeCells> {
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
    final code = digits.length > widget.length ? digits.substring(0, widget.length) : digits;
    _controller.value = TextEditingValue(text: code, selection: TextSelection.collapsed(offset: code.length));
    _changed(code);
  }

  @override
  Widget build(BuildContext context) {
    final text = _controller.text;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Shake(
        trigger: _errors,
        child: SizedBox(
          height: 60,
          child: Stack(children: [
            Row(children: [
              for (var i = 0; i < widget.length; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                Expanded(child: _cell(i < text.length ? text[i] : '', _focus.hasFocus && i == text.length)),
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
          ]),
        ),
      ),
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: _busy ? null : _paste,
          icon: const Icon(Icons.content_paste_rounded, size: 18),
          label: Text(widget.pasteLabel),
        ),
      ),
    ]);
  }

  Widget _cell(String digit, bool active) {
    return Container(
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Q.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: active ? Q.accent : Q.line, width: active ? 1.5 : 1),
      ),
      child: Text(digit, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700, fontFeatures: Q.tabular)),
    );
  }
}
