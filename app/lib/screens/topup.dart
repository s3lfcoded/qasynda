import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../api.dart';
import '../cards.dart';
import '../l10n.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets.dart';
import '../widgets/pin_pad.dart';
import 'add_card.dart';
import 'cards.dart' show CardThumb;

/// Учебное пополнение баланса с привязанной карты: основная карта по умолчанию, «Сменить» — шторка,
/// сумма на клавиатуре и быстрые суммы. Деньги не настоящие — об этом всегда говорит плашка.
class TopupScreen extends StatefulWidget {
  const TopupScreen({super.key});

  static const minAmount = 100 * 100;
  static const maxAmount = 500000 * 100;
  static const quick = [5000 * 100, 10000 * 100, 50000 * 100];

  @override
  State<TopupScreen> createState() => _TopupScreenState();
}

class _TopupScreenState extends State<TopupScreen> {
  List<BankCard>? _cards;
  BankCard? _card;
  String _digits = '';
  bool _busy = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_cards == null) _load();
  }

  Future<void> _load() async {
    final app = AppScope.of(context);
    try {
      final list = await CardsApi(app.api).list();
      if (!mounted) return;
      setState(() {
        _cards = list.items;
        if (_card == null || !list.items.any((c) => c.id == _card!.id)) {
          _card = list.items.where((c) => c.isPrimary).firstOrNull ?? list.items.firstOrNull;
        }
      });
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() => _cards ??= []);
      showError(context, app.s.error(e.code, e.detail));
    }
  }

  int get _tiyn => (int.tryParse(_digits) ?? 0) * 100;

  void _digit(String d) {
    if (_busy) return;
    if (_digits.isEmpty && d == '0') return;
    if (_digits.length >= 6) return;
    HapticFeedback.selectionClick();
    setState(() => _digits += d);
  }

  void _delete() {
    if (_busy || _digits.isEmpty) return;
    HapticFeedback.selectionClick();
    setState(() => _digits = _digits.substring(0, _digits.length - 1));
  }

  Future<void> _bind() async {
    final added = await Navigator.of(context).push<BankCard>(MaterialPageRoute(builder: (_) => const AddCardScreen()));
    if (added != null && mounted) {
      setState(() => _card = added);
      await _load();
    }
  }

  Future<void> _pickCard() async {
    final s = AppScope.of(context).s;
    final cards = _cards ?? const <BankCard>[];
    final picked = await showQSheet<Object>(context, (context) {
      return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(s.t('topupFromCard'), style: Q.appBar.copyWith(color: Q.ink)),
        const SizedBox(height: 16),
        QGroup(dividerIndent: 68, children: [
          for (final card in cards)
            QRow(
              minHeight: 64,
              padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
              leading: CardThumb(brand: card.brand),
              title: brandName(card.brand) ?? s.t('cardLabel'),
              subtitle: _cardLine(card, s),
              subtitleStyle: Q.secondary.copyWith(fontFeatures: Q.tabular),
              trailing: SizedBox.square(
                dimension: 44,
                child: Icon(
                  card.id == _card?.id ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                  color: card.id == _card?.id ? Q.accent : Q.ink3,
                ),
              ),
              onTap: () => Navigator.pop(context, card),
            ),
        ]),
        const SizedBox(height: 8),
        SizedBox(
          height: 44,
          child: TextButton.icon(
            onPressed: () => Navigator.pop(context, 'bind'),
            icon: const Icon(Icons.add_rounded, size: 20),
            label: Text(s.t('bindOther')),
          ),
        ),
      ]);
    });
    if (!mounted) return;
    if (picked is BankCard) setState(() => _card = picked);
    if (picked == 'bind') await _bind();
  }

  static String _cardLine(BankCard card, S s) =>
      '•• ${card.last4}${card.isPrimary ? ', ${s.t('primaryShort')}' : ''}';

  Future<void> _submit() async {
    final app = AppScope.of(context);
    final card = _card;
    if (card == null) return;
    final before = (app.profile?['balance'] as int?) ?? 0;
    setState(() => _busy = true);
    try {
      final result = await app.api.post('/topup', {'card_id': card.id, 'amount': _tiyn});
      final balance = result['balance'] as int;
      app.setBalance(balance);
      HapticFeedback.mediumImpact();
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute<void>(
        builder: (_) => TopupResultScreen(
          amount: result['amount'] as int? ?? _tiyn,
          card: card,
          before: before,
          after: balance,
        ),
      ));
    } on ApiError catch (e) {
      if (mounted) showError(context, app.s.error(e.code, e.detail));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context).s;
    final cards = _cards;
    final card = _card;
    final tiyn = _tiyn;
    final over = tiyn > TopupScreen.maxAmount;
    final ready = card != null && tiyn >= TopupScreen.minAmount && !over && !_busy;
    final glyphs = [
      for (var i = 0; i < _digits.length; i++) (i > 0 && (_digits.length - i) % 3 == 0) ? '$nbsp${_digits[i]}' : _digits[i],
    ];

    Widget chip(int amount) {
      final on = amount == tiyn;
      return GestureDetector(
        onTap: _busy ? null : () => setState(() => _digits = '${amount ~/ 100}'),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: on ? Q.accentSoft : Q.surface,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: on ? Q.accent : Q.surface, width: 1.5),
          ),
          child: Text(money(amount),
              style: Q.label.copyWith(color: on ? Q.accentInk : Q.ink, fontFeatures: Q.tabular)),
        ),
      );
    }

    return Scaffold(
      appBar: QAppBar(title: s.t('topupTitle')),
      body: SafeArea(
        top: false,
        child: cards == null
            ? const Center(child: CircularProgressIndicator())
            : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Expanded(
                  child: ListView(padding: const EdgeInsets.fromLTRB(Q.gutter, 8, Q.gutter, 16), children: [
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(s.t('fromCard'), style: Q.secondary.copyWith(fontWeight: FontWeight.w500)),
                    ),
                    if (card == null)
                      QGroup(children: [
                        QRow(
                          leading: const Icon(Icons.add_card_rounded, color: Q.accent),
                          title: s.t('noCardsTopup'),
                          chevron: true,
                          onTap: _bind,
                        ),
                      ])
                    else
                      QGroup(children: [
                        QRow(
                          minHeight: 64,
                          padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
                          leading: CardThumb(brand: card.brand),
                          title: brandName(card.brand) ?? s.t('cardLabel'),
                          subtitle: _cardLine(card, s),
                          subtitleStyle: Q.secondary.copyWith(fontFeatures: Q.tabular),
                          trailing: TextButton(
                            onPressed: _busy ? null : _pickCard,
                            style: TextButton.styleFrom(minimumSize: const Size(0, 44), padding: const EdgeInsets.symmetric(horizontal: 12)),
                            child: Text(s.t('change')),
                          ),
                        ),
                      ]),
                    const SizedBox(height: 32),
                    SizedBox(
                      height: 60,
                      child: Center(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            if (glyphs.isEmpty)
                              Text('0', style: Q.amountInput.copyWith(color: Q.ink3))
                            else
                              TypedText(glyphs: glyphs, style: Q.amountInput.copyWith(color: Q.ink)),
                            Container(
                              width: 3,
                              height: 44,
                              margin: const EdgeInsets.only(left: 4, right: 8),
                              decoration: BoxDecoration(color: Q.accent, borderRadius: BorderRadius.circular(2)),
                            ),
                            Text('₸', style: Q.amountInput.copyWith(color: Q.ink3)),
                          ]),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      for (var i = 0; i < TopupScreen.quick.length; i++) ...[
                        if (i > 0) const SizedBox(width: 8),
                        chip(TopupScreen.quick[i]),
                      ],
                    ]),
                    if (over) ...[
                      const SizedBox(height: 8),
                      Text(s.t('overLimit', {'sum': money(TopupScreen.maxAmount)}),
                          textAlign: TextAlign.center, style: Q.secondary.copyWith(color: Q.danger)),
                    ],
                    const SizedBox(height: 16),
                    Plaque(text: s.t('demoTopup'), center: true),
                  ]),
                ),
                Keypad(
                  keyHeight: 56,
                  fontSize: 26,
                  onDigit: _digit,
                  onDelete: _digits.isEmpty ? null : _delete,
                  deleteLabel: s.t('pinDelete'),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(Q.gutter, 16, Q.gutter, 8),
                  child: QButton(
                    label: tiyn > 0 ? s.t('topupFor', {'sum': money(tiyn)}) : s.t('topup'),
                    onPressed: ready ? _submit : null,
                    busy: _busy,
                  ),
                ),
              ]),
      ),
    );
  }
}

/// Результат пополнения: «+10 000 ₸» появляется roll, новый баланс прокручивается от старого.
class TopupResultScreen extends StatefulWidget {
  const TopupResultScreen({super.key, required this.amount, required this.card, required this.before, required this.after});
  final int amount;
  final BankCard card;
  final int before;
  final int after;

  @override
  State<TopupResultScreen> createState() => _TopupResultScreenState();
}

class _TopupResultScreenState extends State<TopupResultScreen> {
  late int _balance = widget.before;
  final _at = DateTime.now();

  @override
  void initState() {
    super.initState();
    // Баланс сначала старый, затем прокручивается к новому.
    Future<void>.delayed(const Duration(milliseconds: 300), () {
      if (mounted) setState(() => _balance = widget.after);
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context).s;
    final reduced = MediaQuery.disableAnimationsOf(context);
    final cardText = '${brandName(widget.card.brand) ?? s.t('cardLabel')} •• ${widget.card.last4}';
    Widget row(String label, Widget value) => ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(children: [
              Text(label, style: const TextStyle(fontSize: 15, height: 20 / 15, color: Q.ink2)),
              const SizedBox(width: 16),
              Expanded(child: Align(alignment: AlignmentDirectional.centerEnd, child: value)),
            ]),
          ),
        );
    const bold = TextStyle(fontSize: 15, height: 20 / 15, fontWeight: FontWeight.w600, color: Q.ink, fontFeatures: Q.tabular);

    return Scaffold(
      body: SafeArea(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(
            child: ListView(padding: const EdgeInsets.fromLTRB(Q.gutter, 48, Q.gutter, 16), children: [
              Center(
                child: TweenAnimationBuilder<double>(
                  tween: Tween(begin: reduced ? 1 : 0.6, end: 1),
                  duration: const Duration(milliseconds: 240),
                  curve: Curves.easeOutBack,
                  builder: (_, scale, child) => Transform.scale(scale: scale, child: child),
                  child: Container(
                    width: 72,
                    height: 72,
                    decoration: const BoxDecoration(color: Q.accent, shape: BoxShape.circle),
                    child: const Icon(Icons.check_rounded, size: 40, color: Q.onAccent),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Text(s.t('topupDone'), textAlign: TextAlign.center, style: Q.appBar.copyWith(color: Q.ink2, fontWeight: FontWeight.w400)),
              const SizedBox(height: 4),
              Center(
                child: RollingAmount('+${money(widget.amount)}',
                    style: Q.balance.copyWith(color: Q.accentInk), rollIn: true, delay: const Duration(milliseconds: 120)),
              ),
              const SizedBox(height: 8),
              Text(s.t('fromCardX', {'card': cardText}),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 16, height: 24 / 16, fontWeight: FontWeight.w600, color: Q.ink, fontFeatures: Q.tabular)),
              const SizedBox(height: 32),
              Material(
                color: Q.surface,
                borderRadius: BorderRadius.circular(20),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(children: [
                    row(s.t('newBalance'), RollingAmount(money(_balance), style: bold)),
                    row(s.t('cardLabel'), Text(cardText, style: bold)),
                    row(s.t('date'), Text(s.date(_at), style: bold)),
                  ]),
                ),
              ),
              const SizedBox(height: 16),
              Plaque(text: s.t('demoTopup')),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Q.gutter, 0, Q.gutter, 8),
            child: QButton(label: s.t('done'), onPressed: () => Navigator.of(context).popUntil((route) => route.isFirst)),
          ),
        ]),
      ),
    );
  }
}
