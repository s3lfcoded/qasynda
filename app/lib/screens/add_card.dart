import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:material_ui/material_ui.dart';

import '../api.dart';
import '../cards.dart';
import '../cards_l10n.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets.dart';
import '../widgets/phone_field.dart' show MaskedField;
import 'card_scan.dart';

/// Привязка карты: камерой или вручную. Номер уходит на сервер один раз, CVV не спрашивается.
/// NFC не предлагается: зрелого пакета для чтения EMV-карт под Flutter нет.
/// Возвращает привязанную карту через Navigator.pop.
/// [onboarding] — экран после первого входа: вместо «назад» кнопка «Позже».
class AddCardScreen extends StatefulWidget {
  const AddCardScreen({super.key, this.scan, this.onboarding = false});

  /// Сканер для тестов; по умолчанию — экран камеры.
  final Future<ScannedCard?> Function(BuildContext context)? scan;
  final bool onboarding;

  @override
  State<AddCardScreen> createState() => _AddCardScreenState();
}

class _AddCardScreenState extends State<AddCardScreen> {
  final _number = TextEditingController();
  final _expiry = TextEditingController();
  final _holder = TextEditingController();
  bool _manual = false;
  bool _scanned = false;
  bool _busy = false;

  static bool get _hasCamera => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  @override
  void dispose() {
    _number.dispose();
    _expiry.dispose();
    _holder.dispose();
    super.dispose();
  }

  bool get _numberOk => cardNumberValid(_number.text);
  bool get _expiryOk => expiryValid(_expiry.text);
  bool get _holderOk => _holder.text.trim().length >= 2;

  Future<void> _scan() async {
    final scan = widget.scan ??
        (context) => Navigator.of(context).push<ScannedCard>(MaterialPageRoute(builder: (_) => const CardScanScreen()));
    final found = await scan(context);
    if (!mounted) return;
    setState(() {
      _manual = true;
      if (found == null) return;
      _scanned = true;
      if (found.number != null) _number.text = formatCardNumber(found.number!);
      if (found.expiry != null) _expiry.text = found.expiry!;
    });
  }

  Future<void> _save() async {
    final app = AppScope.of(context);
    final t = CardText(app.lang);
    setState(() => _busy = true);
    try {
      final card = await CardsApi(app.api).add(number: _number.text, expiry: _expiry.text, holder: _holder.text);
      _number.clear();
      if (mounted) Navigator.of(context).pop(card);
    } on ApiError catch (e) {
      if (mounted) showCardError(context, t.error(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Выбор способа (артборд 4): заголовок, место под карту, способы, пометка о хранении карты.
  Widget _methods(CardText t) {
    Widget method(IconData icon, String title, String hint, VoidCallback onTap) => QRow(
          leading: Container(
            width: 40,
            height: 40,
            decoration: const BoxDecoration(color: Q.accentSoft, shape: BoxShape.circle),
            child: Icon(icon, size: 20, color: Q.accentInk),
          ),
          title: title,
          subtitle: hint,
          chevron: true,
          onTap: onTap,
        );
    return CustomScrollView(slivers: [
      SliverFillRemaining(
        hasScrollBody: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Q.gutter, 8, Q.gutter, 24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(widget.onboarding ? t.t('bindTitle') : t.t('add'), style: Q.title.copyWith(color: Q.ink)),
            const SizedBox(height: 8),
            Text(t.t('bindHint'), style: Q.body),
            const SizedBox(height: 24),
            const _CardSlot(),
            const SizedBox(height: 24),
            QGroup(dividerIndent: 68, children: [
              if (_hasCamera || widget.scan != null)
                method(Icons.photo_camera_outlined, t.t('byCamera'), t.t('byCameraHint'), _scan),
              method(Icons.keyboard_outlined, t.t('manual'), t.t('manualHint'), () => setState(() => _manual = true)),
            ]),
            const Spacer(),
            const SizedBox(height: 24),
            QNote(icon: Icons.lock_outline_rounded, text: t.t('encrypted')),
          ]),
        ),
      ),
    ]);
  }

  /// Ручной ввод (артборд 6): номер во всю ширину, ниже «Срок» 104 и «Имя на карте», пометка о CVV.
  Widget _form(CardText t) {
    final numberDigits = digitsOnly(_number.text).length;
    final brand = brandName(brandOf(_number.text));
    final ready = _numberOk && _expiryOk && _holderOk && !_busy;
    final keyboard = MediaQuery.viewInsetsOf(context).bottom > 0;
    const fieldStyle = TextStyle(fontSize: 16, height: 24 / 16, color: Q.ink, fontFeatures: Q.tabular);
    InputDecoration decoration(String hint, bool error) => InputDecoration(
          hintText: hint,
          contentPadding: const EdgeInsets.fromLTRB(16, 16, 4, 16),
          hintStyle: fieldStyle.copyWith(color: Q.ink3),
          enabledBorder: error
              ? OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Q.danger, width: 2))
              : null,
        );
    Widget label(String text) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(text, style: Q.secondary.copyWith(fontWeight: FontWeight.w500)),
        );
    final expiryBad = _expiry.text.length == 5 && !_expiryOk;

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Expanded(
        child: ListView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.fromLTRB(Q.gutter, 8, Q.gutter, 16),
          children: [
            if (_scanned) ...[
              QNote(icon: Icons.document_scanner_outlined, text: t.t('scanCheck')),
              const SizedBox(height: 16),
            ],
            MaskedField(
              controller: _number,
              label: t.t('number'),
              placeholder: '0000 0000 0000 0000',
              autofocus: !_scanned,
              // Без мигания: экран затихает, пока человек сверяет номер с картой.
              blink: false,
              autofillHints: const [AutofillHints.creditCardNumber],
              formatters: [CardNumberFormatter()],
              glyphs: (text) {
                final d = digitsOnly(text);
                return [for (var i = 0; i < d.length; i++) i > 0 && i % 4 == 0 ? ' ${d[i]}' : d[i]];
              },
              trailing: brand == null
                  ? null
                  : Padding(padding: const EdgeInsets.only(right: 12), child: QTag(kind: TagKind.neutral, label: brand)),
              errorText: numberDigits >= 16 && !_numberOk ? t.t('invalidNumber') : null,
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 16),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(
                width: 104,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  label(t.t('expiry')),
                  TextField(
                    controller: _expiry,
                    keyboardType: TextInputType.number,
                    autofillHints: const [AutofillHints.creditCardExpirationDate],
                    inputFormatters: [ExpiryFormatter()],
                    style: fieldStyle,
                    decoration: decoration(t.t('expiryHint'), expiryBad),
                    onChanged: (_) => setState(() {}),
                  ),
                ]),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  label(t.t('holder')),
                  TextField(
                    controller: _holder,
                    textCapitalization: TextCapitalization.characters,
                    autofillHints: const [AutofillHints.creditCardName],
                    autocorrect: false,
                    inputFormatters: [HolderFormatter()],
                    style: fieldStyle,
                    decoration: decoration(t.t('holderHint'), false),
                    onChanged: (_) => setState(() {}),
                  ),
                ]),
              ),
            ]),
            if (expiryBad) ...[
              const SizedBox(height: 8),
              Text(t.t('invalidExpiry'), style: Q.secondary.copyWith(color: Q.danger)),
            ],
            const SizedBox(height: 16),
            QNote(icon: Icons.lock_outline_rounded, text: t.t('noCvv')),
          ],
        ),
      ),
      Padding(
        padding: EdgeInsets.fromLTRB(Q.gutter, 0, Q.gutter, keyboard ? 12 : 8),
        child: QButton(label: t.t('save'), onPressed: ready ? _save : null, busy: _busy),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final t = CardText(AppScope.of(context).lang);
    final later = TextButton(
      onPressed: () => Navigator.of(context).pop(),
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 44),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        textStyle: const TextStyle(fontFamily: Q.font, fontSize: 16, height: 24 / 16, fontWeight: FontWeight.w600),
      ),
      child: Text(t.t('later')),
    );
    return PopScope(
      canPop: !_manual,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _manual = false);
      },
      child: Scaffold(
        appBar: _manual
            ? QAppBar(title: t.t('addTitle'), onBack: () => setState(() => _manual = false))
            : QAppBar(back: !widget.onboarding, actions: [if (widget.onboarding) later]),
        body: SafeArea(top: false, child: _manual ? _form(t) : _methods(t)),
      ),
    );
  }
}

/// Пустое место под карту: пунктирная рамка 156, в центре значок добавления карты.
class _CardSlot extends StatelessWidget {
  const _CardSlot();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 156,
      child: CustomPaint(
        painter: const _DashedBorder(),
        child: Center(
          child: Container(
            width: 56,
            height: 56,
            decoration: const BoxDecoration(color: Q.accentSoft, shape: BoxShape.circle),
            child: const Icon(Icons.add_card_rounded, color: Q.accentInk),
          ),
        ),
      ),
    );
  }
}

class _DashedBorder extends CustomPainter {
  const _DashedBorder();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Q.surface2
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final path = Path()..addRRect(RRect.fromRectAndRadius((Offset.zero & size).deflate(1), const Radius.circular(20)));
    for (final metric in path.computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += 10) {
        canvas.drawPath(metric.extractPath(d, d + 6), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorder oldDelegate) => false;
}

/// Сообщение об ошибке внизу экрана.
void showCardError(BuildContext context, String message) => showError(context, message);
