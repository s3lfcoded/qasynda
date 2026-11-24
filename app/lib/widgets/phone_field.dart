import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../theme.dart';
import 'rolling_amount.dart';

/// Цифры номера без «+7»: 10 знаков.
String phoneDigits(String text) => text.replaceAll(RegExp(r'\D'), '');

/// 7010000001 → «701 000 00 01».
String formatPhoneDigits(String digits) {
  final b = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i == 3 || i == 6 || i == 8) b.write(' ');
    b.write(digits[i]);
  }
  return b.toString();
}

/// Маска «701 000 00 01». Вставленный номер целиком (+7 701…, 8 701…) теряет код страны.
class PhoneMask extends TextInputFormatter {
  const PhoneMask();

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final before = phoneDigits(oldValue.text);
    var digits = phoneDigits(newValue.text);
    if (digits.length > 10) {
      final pasted = digits.length - before.length > 1;
      if (pasted && digits.length == 11 && (digits.startsWith('7') || digits.startsWith('8'))) {
        digits = digits.substring(1);
      } else if (pasted) {
        digits = digits.substring(digits.length - 10);
      } else {
        return oldValue;
      }
    }
    // Стёрли пробел — стирается цифра перед ним.
    if (newValue.text.length < oldValue.text.length && digits == before && digits.isNotEmpty) {
      digits = digits.substring(0, digits.length - 1);
    }
    final text = formatPhoneDigits(digits);
    return TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
  }
}

/// Поле номера: неизменяемый «+7» и номер на одной базовой линии одним кеглем, маска, мягкий ввод цифр,
/// кнопка очистки. Сам ввод идёт через невидимое поле: работают автоподстановка номера и вставка.
class PhoneField extends StatelessWidget {
  const PhoneField({
    super.key,
    required this.controller,
    this.onChanged,
    this.onSubmitted,
    this.autofocus = true,
    this.label,
    this.clearLabel = 'Очистить',
  });

  final TextEditingController controller;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final bool autofocus;
  final String? label;
  final String clearLabel;

  @override
  Widget build(BuildContext context) {
    return MaskedField(
      controller: controller,
      prefix: '+7',
      placeholder: '700 000 00 00',
      label: label,
      clearLabel: clearLabel,
      autofocus: autofocus,
      keyboardType: TextInputType.phone,
      autofillHints: const [AutofillHints.telephoneNumber],
      formatters: const [PhoneMask()],
      glyphs: (text) {
        final d = phoneDigits(text);
        return [for (var i = 0; i < d.length; i++) (i == 3 || i == 6 || i == 8) ? ' ${d[i]}' : d[i]];
      },
      onChanged: onChanged,
      onSubmitted: onSubmitted,
    );
  }
}

/// Поле с маской (телефон, номер карты): префикс и значение 20/500 на одной базовой линии, цифры
/// появляются снизу, пробелы маски раскрываются плавно. Высота 56, радиус 16, слева 16, справа 4.
/// Фокус — белый фон и рамка accent 2. Справа — крестик очистки или [trailing].
class MaskedField extends StatefulWidget {
  const MaskedField({
    super.key,
    required this.controller,
    required this.glyphs,
    required this.formatters,
    this.prefix,
    this.placeholder = '',
    this.label,
    this.clearLabel,
    this.trailing,
    this.errorText,
    this.autofocus = false,
    this.blink = true,
    this.keyboardType = TextInputType.number,
    this.autofillHints = const [],
    this.onChanged,
    this.onSubmitted,
  });

  final TextEditingController controller;

  /// Знаки для показа: по элементу на введённый символ, с пробелом маски перед ним.
  final List<String> Function(String text) glyphs;
  final List<TextInputFormatter> formatters;
  final String? prefix;
  final String placeholder;
  final String? label;

  /// Подпись крестика очистки; null — крестика нет.
  final String? clearLabel;
  final Widget? trailing;
  final String? errorText;
  final bool autofocus;

  /// Мигающий курсор. Без мигания экран может «успокоиться» (нужно тестам с pumpAndSettle).
  final bool blink;
  final TextInputType keyboardType;
  final List<String> autofillHints;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  static const style = TextStyle(fontSize: 20, height: 28 / 20, fontWeight: FontWeight.w500, color: Q.ink, fontFeatures: Q.tabular);
  static const _strut = StrutStyle(fontSize: 20, height: 28 / 20, forceStrutHeight: true);

  @override
  State<MaskedField> createState() => _MaskedFieldState();
}

class _MaskedFieldState extends State<MaskedField> with SingleTickerProviderStateMixin {
  final _focus = FocusNode();
  late final _blink = AnimationController(vsync: this, duration: const Duration(milliseconds: 1000));

  @override
  void initState() {
    super.initState();
    _focus.addListener(_sync);
    widget.controller.addListener(_sync);
  }

  @override
  void didUpdateWidget(MaskedField old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_sync);
      widget.controller.addListener(_sync);
    }
  }

  void _sync() {
    if (!mounted) return;
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (_focus.hasFocus && !reduced && widget.blink) {
      // После каждого ввода курсор сначала виден, потом мигает.
      _blink.value = 0;
      _blink.repeat();
    } else {
      _blink.stop();
    }
    setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_sync);
    _focus.dispose();
    _blink.dispose();
    super.dispose();
  }

  void _clear() {
    widget.controller.clear();
    widget.onChanged?.call('');
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final text = widget.controller.text;
    final glyphs = widget.glyphs(text);
    final focused = _focus.hasFocus;
    final error = widget.errorText;
    final caret = AnimatedBuilder(
      animation: _blink,
      builder: (_, _) => Opacity(
        opacity: !focused ? 0 : (_blink.isAnimating && _blink.value > 0.5 ? 0 : 1),
        child: Container(
          width: 2,
          height: 24,
          margin: const EdgeInsets.only(left: 2),
          decoration: BoxDecoration(color: Q.accent, borderRadius: BorderRadius.circular(1)),
        ),
      ),
    );
    final clear = widget.clearLabel;

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      if (widget.label != null) ...[
        Text(widget.label!, style: Q.secondary.copyWith(fontWeight: FontWeight.w500)),
        const SizedBox(height: 8),
      ],
      GestureDetector(
        onTap: _focus.requestFocus,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          height: 56,
          padding: const EdgeInsets.only(left: 16, right: 4),
          decoration: BoxDecoration(
            color: focused ? Q.bg : Q.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: error != null ? Q.danger : (focused ? Q.accent : Q.surface), width: 2),
          ),
          child: Row(children: [
            if (widget.prefix != null) ...[
              Text(widget.prefix!, style: MaskedField.style.copyWith(color: Q.ink2)),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Stack(alignment: AlignmentDirectional.centerStart, children: [
                ClipRect(
                  child: Row(children: [
                    if (glyphs.isEmpty) ...[
                      caret,
                      Flexible(
                        child: Text(widget.placeholder,
                            maxLines: 1,
                            overflow: TextOverflow.clip,
                            softWrap: false,
                            style: MaskedField.style.copyWith(color: Q.ink3, fontWeight: FontWeight.w400)),
                      ),
                    ] else ...[
                      Flexible(child: TypedText(glyphs: glyphs, style: MaskedField.style)),
                      caret,
                    ],
                  ]),
                ),
                Positioned.fill(
                  child: TextSelectionTheme(
                    data: const TextSelectionThemeData(selectionColor: Colors.transparent),
                    child: TextField(
                      controller: widget.controller,
                      focusNode: _focus,
                      autofocus: widget.autofocus,
                      keyboardType: widget.keyboardType,
                      autofillHints: widget.autofillHints,
                      autocorrect: false,
                      enableSuggestions: false,
                      showCursor: false,
                      inputFormatters: widget.formatters,
                      style: MaskedField.style.copyWith(color: Colors.transparent),
                      strutStyle: MaskedField._strut,
                      decoration: InputDecoration(
                        filled: false,
                        isCollapsed: true,
                        border: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(vertical: 12),
                        hintText: widget.label,
                        hintStyle: const TextStyle(color: Colors.transparent),
                      ),
                      onChanged: widget.onChanged,
                      onSubmitted: widget.onSubmitted,
                    ),
                  ),
                ),
              ]),
            ),
            ?widget.trailing,
            if (clear != null)
              AnimatedOpacity(
                duration: const Duration(milliseconds: 160),
                opacity: text.isEmpty ? 0 : 1,
                child: AnimatedScale(
                  duration: const Duration(milliseconds: 160),
                  curve: Curves.easeOut,
                  scale: text.isEmpty ? 0.8 : 1,
                  child: SizedBox.square(
                    dimension: 44,
                    child: IconButton(
                      onPressed: text.isEmpty ? null : _clear,
                      tooltip: clear,
                      padding: EdgeInsets.zero,
                      style: IconButton.styleFrom(overlayColor: Q.surface2, shape: const CircleBorder()),
                      icon: const Icon(Icons.close_rounded, size: 20, color: Q.ink2),
                    ),
                  ),
                ),
              ),
          ]),
        ),
      ),
      if (error != null) ...[
        const SizedBox(height: 8),
        Text(error, style: Q.secondary.copyWith(color: Q.danger)),
      ],
    ]);
  }
}
