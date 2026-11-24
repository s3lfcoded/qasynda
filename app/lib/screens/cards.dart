import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../api.dart';
import '../cards.dart';
import '../cards_l10n.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets.dart';
import 'add_card.dart';

/// «Мои карты» (артборды 17–18): учебная карта Qasynda сверху, ниже привязанные. Основная отмечена
/// кружком — нажатие на кружок делает карту основной. Нажатие на строку открывает шторку
/// «Сделать основной» / «Удалить карту». Удаление без подтверждения: 4 секунды карту можно вернуть.
class CardsScreen extends StatefulWidget {
  const CardsScreen({super.key});

  @override
  State<CardsScreen> createState() => _CardsScreenState();
}

class _CardsScreenState extends State<CardsScreen> {
  CardsApi? _api;
  List<BankCard>? _cards;
  VirtualCard? _virtual;
  int _max = 5;
  bool _busy = false;
  BankCard? _removing;
  Timer? _removeTimer;

  CardText get _t => CardText(AppScope.of(context).lang);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_api != null) return;
    _api = CardsApi(AppScope.of(context).api);
    _load();
  }

  @override
  void dispose() {
    // Ушли с экрана, пока шла отмена удаления, — карта удаляется сразу.
    if (_removeTimer?.isActive == true) {
      _removeTimer!.cancel();
      final card = _removing;
      if (card != null) _api!.delete(card.id).catchError((_) {});
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final list = await _api!.list();
      VirtualCard? virtual;
      try {
        virtual = await _api!.virtualCard();
      } on ApiError {
        virtual = null;
      }
      if (!mounted) return;
      setState(() {
        _cards = list.items;
        _max = list.max;
        _virtual = virtual;
      });
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() => _cards ??= []);
      showCardError(context, _t.error(e));
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
      await _load();
    } on ApiError catch (e) {
      if (mounted) showCardError(context, _t.error(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _remove(BankCard card) {
    final t = _t;
    _flushRemoval();
    setState(() => _removing = card);
    _removeTimer = Timer(const Duration(seconds: 4), () {
      _removing = null;
      _run(() => _api!.delete(card.id));
    });
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        duration: const Duration(seconds: 4),
        content: Text(t.t('deleted')),
        action: SnackBarAction(
          label: t.t('undo'),
          onPressed: () {
            _removeTimer?.cancel();
            if (mounted) setState(() => _removing = null);
          },
        ),
      ));
  }

  /// Новое удаление, пока не закончилось прошлое: прошлое выполняется сразу.
  void _flushRemoval() {
    if (_removeTimer?.isActive != true) return;
    _removeTimer!.cancel();
    final card = _removing!;
    _removing = null;
    _run(() => _api!.delete(card.id));
  }

  Future<void> _actions(BankCard card) async {
    final t = _t;
    await showQSheet<void>(context, (context) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          CardThumb(brand: card.brand, width: 56, height: 36),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_title(card, t), style: Q.appBar.copyWith(color: Q.ink)),
              Text(_subtitle(card), style: Q.secondary.copyWith(fontFeatures: Q.tabular)),
            ]),
          ),
        ]),
        const SizedBox(height: 24),
        QGroup(dividerIndent: 52, children: [
          if (!card.isPrimary)
            QRow(
              leading: const Icon(Icons.check_circle_outline_rounded, color: Q.accent),
              title: t.t('makePrimary'),
              onTap: () {
                Navigator.pop(context);
                _run(() => _api!.setPrimary(card.id));
              },
            ),
          QRow(
            leading: const Icon(Icons.delete_outline_rounded, color: Q.danger),
            title: t.t('deleteCard'),
            titleColor: Q.danger,
            onTap: () {
              Navigator.pop(context);
              _remove(card);
            },
          ),
        ]),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(t.t('deletedHint'), style: Q.secondary),
        ),
        const SizedBox(height: 24),
        QButton(kind: QButtonKind.secondary, label: t.t('cancel'), onPressed: () => Navigator.pop(context)),
      ]);
    });
  }

  Future<void> _add() async {
    _flushRemoval();
    final added = await Navigator.of(context).push<BankCard>(MaterialPageRoute(builder: (_) => const AddCardScreen()));
    if (added != null) await _load();
  }

  static String _title(BankCard card, CardText t) => brandName(card.brand) ?? t.t('card');

  static String _subtitle(BankCard card) => '••\u00A0${card.last4} · ${card.expiry}';

  @override
  Widget build(BuildContext context) {
    final t = _t;
    final cards = _cards?.where((c) => c.id != _removing?.id).toList();
    final virtual = _virtual;
    final noPrimary = cards != null && !cards.any((c) => c.isPrimary);

    Widget radio(bool on, VoidCallback? onTap, String label) => SizedBox.square(
          dimension: 44,
          child: IconButton(
            onPressed: onTap,
            tooltip: label,
            padding: EdgeInsets.zero,
            icon: on
                ? const Icon(Icons.check_circle_rounded, color: Q.accent)
                : const Icon(Icons.radio_button_unchecked_rounded, color: Q.ink3),
          ),
        );

    return Scaffold(
      appBar: QAppBar(title: t.t('title')),
      body: SafeArea(
        top: false,
        child: cards == null
            ? const Center(child: CircularProgressIndicator())
            : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Expanded(
                  child: RefreshIndicator(
                    color: Q.accent,
                    onRefresh: _load,
                    child: ListView(padding: const EdgeInsets.fromLTRB(Q.gutter, 8, Q.gutter, 16), children: [
                      QGroup(dividerIndent: 68, children: [
                        if (virtual != null)
                          QRow(
                            minHeight: 64,
                            padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
                            leading: const CardThumb(brand: CardBrand.qasynda),
                            title: t.t('virtualName'),
                            subtitle: t.t('virtualIssued', {'last4': virtual.last4}),
                            subtitleStyle: Q.secondary.copyWith(fontFeatures: Q.tabular),
                            trailing: radio(noPrimary, null, t.t('primary')),
                          ),
                        for (final card in cards)
                          QRow(
                            minHeight: 64,
                            padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
                            leading: CardThumb(brand: card.brand),
                            title: _title(card, t),
                            subtitle: _subtitle(card),
                            subtitleStyle: Q.secondary.copyWith(fontFeatures: Q.tabular),
                            trailing: radio(
                              card.isPrimary,
                              _busy || card.isPrimary ? null : () => _run(() => _api!.setPrimary(card.id)),
                              t.t('makePrimary'),
                            ),
                            onTap: _busy ? null : () => _actions(card),
                          ),
                      ]),
                      const SizedBox(height: 12),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Text(t.t('primaryHint'), style: Q.secondary),
                      ),
                      if (cards.length >= _max) ...[
                        const SizedBox(height: 8),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Text(t.t('limit', {'max': '$_max'}), style: Q.secondary),
                        ),
                      ],
                    ]),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(Q.gutter, 0, Q.gutter, 8),
                  child: QButton(
                    icon: Icons.add_rounded,
                    label: t.t('add'),
                    onPressed: _busy || cards.length >= _max ? null : _add,
                  ),
                ),
              ]),
      ),
    );
  }
}

/// Миниатюра карты 40×28, радиус 4, полоска 12×4 внизу слева; у карты Qasynda — знак в углу.
class CardThumb extends StatelessWidget {
  const CardThumb({super.key, required this.brand, this.width = 40, this.height = 28});
  final CardBrand brand;
  final double width;
  final double height;

  static Color colorOf(CardBrand brand) => switch (brand) {
        CardBrand.qasynda => Q.card,
        CardBrand.visa => const Color(0xFF2D4F7C),
        CardBrand.mastercard => const Color(0xFF3E6B3A),
        CardBrand.unionpay => const Color(0xFF7A3B3B),
        CardBrand.other => const Color(0xFF4A5250),
      };

  @override
  Widget build(BuildContext context) {
    final k = height / 28;
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(color: colorOf(brand), borderRadius: BorderRadius.circular(4 * k)),
      child: Stack(children: [
        Positioned(
          left: 4 * k,
          bottom: 4 * k,
          child: Container(
            width: 12 * k,
            height: 4 * k,
            decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.55), borderRadius: BorderRadius.circular(2 * k)),
          ),
        ),
        if (brand == CardBrand.qasynda)
          Positioned(right: 4 * k, top: 4 * k, child: QasyndaMark(size: 16 * k, color: Q.onAccent)),
      ]),
    );
  }
}
