import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../api.dart';
import '../bank_card.dart';
import '../cards.dart';
import '../l10n.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets.dart';
import 'add_card.dart';
import 'receive.dart';
import 'send.dart';
import 'settings.dart';
import 'support.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  StreamSubscription<Map<String, dynamic>>? _sub;
  StreamSubscription<Map<String, dynamic>>? _alerts;

  // Скрытые суммы открываются нажатием на баланс на 5 секунд — сразу все: баланс, номер, карта, история.
  bool _reveal = false;
  Timer? _hide;

  // Оборот карты: CVV показывается по глазку и прячется сам через 30 секунд, при уходе в фон
  // и при перевороте обратно. Реквизиты запрашиваются один раз и живут в памяти (AppState).
  bool _cvv = false;
  Timer? _cvvTimer;
  bool _fetchingSecret = false;
  late final AppLifecycleListener _life;
  bool _offered = false;

  @override
  void initState() {
    super.initState();
    _life = AppLifecycleListener(onInactive: _hideCvv, onHide: _hideCvv);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = AppScope.of(context);
    // Первый вход с нового телефона: если карт нет, предлагаем привязать.
    if (app.offerCards && !_offered) {
      _offered = true;
      app.offerCards = false;
      WidgetsBinding.instance.addPostFrameCallback((_) => _offerCards());
    }
    _sub ??= app.incoming.listen((event) {
      // На экране приёма перевод показывается крупно, здесь — короткое уведомление.
      if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
      showError(context,
          // при скрытии сумм уведомление не показывает сумму: его видно и на скриншоте, и через плечо
          '${app.hideSensitive ? app.s.t('receivedHidden') : app.s.t('received', {'sum': money(event['amount'] as int)})} · ${app.s.t('from', {'name': '${event['sender']}'})}');
    });
    // Вход с другого телефона видно сразу, на любом экране.
    if (_alerts == null) {
      _alerts = app.alerts.listen(_showAlert);
      // Предупреждения, пришедшие, пока приложение было заблокировано.
      final pending = app.takePendingAlerts();
      if (pending.isNotEmpty) WidgetsBinding.instance.addPostFrameCallback((_) => pending.forEach(_showAlert));
    }
  }

  void _showAlert(Map<String, dynamic> event) {
    if (!mounted) return;
    final app = AppScope.of(context);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      duration: const Duration(seconds: 10),
      content: Text(app.s.t('newDevice', {'name': '${event['name']}'})),
      action: SnackBarAction(label: app.s.t('settings'), onPressed: () => _open(const SettingsScreen())),
    ));
  }

  void _toggleReveal() {
    _hide?.cancel();
    setState(() => _reveal = !_reveal);
    if (_reveal) _hide = Timer(const Duration(seconds: 5), () => mounted ? setState(() => _reveal = false) : null);
  }

  Future<void> _offerCards() async {
    final app = AppScope.of(context);
    try {
      final list = await CardsApi(app.api).list();
      if (!mounted || list.items.isNotEmpty) return;
      await Navigator.of(context).push<BankCard>(
        MaterialPageRoute(builder: (_) => const AddCardScreen(onboarding: true)),
      );
    } catch (_) {
      // Не получилось узнать про карты — не мешаем: привязать можно в настройках.
    }
  }

  void _onCardSide(bool back) {
    if (back) {
      _loadSecret();
    } else {
      _hideCvv();
    }
  }

  Future<void> _loadSecret() async {
    final app = AppScope.of(context);
    if (app.virtualSecret != null || _fetchingSecret) return;
    _fetchingSecret = true;
    try {
      final secret = await CardsApi(app.api).virtualSecret();
      app.virtualSecret = secret;
      if (mounted) setState(() {});
    } on ApiError catch (e) {
      if (mounted) showError(context, app.s.error(e.code, e.detail));
    } finally {
      _fetchingSecret = false;
    }
  }

  void _hideCvv() {
    _cvvTimer?.cancel();
    if (_cvv && mounted) setState(() => _cvv = false);
  }

  void _toggleCvv() {
    if (_cvv) return _hideCvv();
    setState(() => _cvv = true);
    _cvvTimer = Timer(const Duration(seconds: 30), _hideCvv);
  }

  Future<void> _copyNumber() async {
    final app = AppScope.of(context);
    final secret = app.virtualSecret;
    if (secret == null) return;
    await Clipboard.setData(ClipboardData(text: secret.number));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(duration: const Duration(seconds: 2), content: Text(app.s.t('numberCopied'))));
  }

  @override
  void dispose() {
    _life.dispose();
    _cvvTimer?.cancel();
    _hide?.cancel();
    _sub?.cancel();
    _alerts?.cancel();
    super.dispose();
  }

  void _open(Widget screen) {
    if (!mounted) return;
    final app = AppScope.of(context);
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => screen))
        .then((_) => app.refresh().catchError((_) {}));
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final s = app.s;
    final profile = app.profile!;
    final name = profile['name'] as String;
    final firstName = name.split(' ').first;
    final merchant = profile['is_merchant'] == true;
    final phone = '${profile['phone']}';
    final hiding = app.hideSensitive;
    final shown = !hiding || _reveal;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: lightOverlay,
      child: Scaffold(
        body: SafeArea(
          bottom: false,
          child: RefreshIndicator(
            color: Q.accent,
            backgroundColor: Q.bg,
            onRefresh: () => app.refresh().catchError((_) {}),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(Q.gutter, 0, Q.gutter, 24),
              children: [
                SizedBox(
                  height: 56,
                  child: Row(children: [
                    Avatar(name: firstName, kind: AvatarKind.me, size: 44),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(firstName, maxLines: 1, overflow: TextOverflow.ellipsis, style: Q.rowTitle.copyWith(color: Q.ink)),
                          Text(shown ? phoneText(phone) : phoneMasked(phone),
                              maxLines: 1, style: Q.secondary.copyWith(fontFeatures: Q.tabular)),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    _RoundButton(
                      icon: Icons.support_agent_rounded,
                      tooltip: s.t('support'),
                      onPressed: () => _open(const SupportScreen()),
                    ),
                    const SizedBox(width: 8),
                    _RoundButton(
                      icon: Icons.settings_outlined,
                      tooltip: s.t('settings'),
                      onPressed: () => _open(const SettingsScreen()),
                    ),
                  ]),
                ),
                const SizedBox(height: 16),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: hiding ? _toggleReveal : null,
                  child: Semantics(
                    hint: hiding ? s.t('tapToShow') : null,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      SizedBox(
                        height: 20,
                        child: Row(children: [
                          Text(s.t('balance'), style: Q.label.copyWith(color: Q.ink2, fontWeight: FontWeight.w400)),
                          if (hiding) ...[
                            const SizedBox(width: 8),
                            Icon(shown ? Icons.visibility_outlined : Icons.visibility_off_outlined, size: 16, color: Q.ink2),
                          ],
                        ]),
                      ),
                      const SizedBox(height: 4),
                      SizedBox(
                        height: 48,
                        child: Row(children: [
                          Flexible(
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: AlignmentDirectional.centerStart,
                              child: RollingAmount(
                                money(profile['balance'] as int),
                                style: Q.balance.copyWith(color: Q.ink),
                                hidden: !shown,
                                rollIn: shown,
                              ),
                            ),
                          ),
                          if (!shown) ...[
                            const SizedBox(width: 12),
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 184),
                              child: Text(s.t('tapToShow'),
                                  maxLines: 2,
                                  style: const TextStyle(
                                      fontSize: 14, height: 20 / 14, fontWeight: FontWeight.w600, color: Q.accentInk)),
                            ),
                          ],
                        ]),
                      ),
                    ]),
                  ),
                ),
                const SizedBox(height: 16),
                // Долгое нажатие или свайп переворачивают карту: на обороте реквизиты учебной карты.
                FlipCard(
                  semanticLabel: s.t('flipCard'),
                  onSide: _onCardSide,
                  front: CardFront(
                    holder: name,
                    last4: shown ? '${profile['card_last4'] ?? '0000'}' : masked,
                    kind: s.t(merchant ? 'businessCard' : 'virtualCard'),
                    business: merchant ? '${profile['business_name']}' : null,
                  ),
                  back: CardBack(
                    title: s.t('virtualCardFull'),
                    badge: s.t('training'),
                    last4: '${profile['card_last4'] ?? '••••'}',
                    expiryLabel: s.t('expiryShort'),
                    number: app.virtualSecret?.number,
                    expiry: app.virtualSecret?.expiry,
                    cvv: app.virtualSecret?.cvv,
                    cvvShown: _cvv,
                    copyLabel: s.t('copyNumber'),
                    showCvvLabel: s.t('showCvv'),
                    hideCvvLabel: s.t('hideCvv'),
                    onCopy: app.virtualSecret == null ? null : _copyNumber,
                    onToggleCvv: app.virtualSecret == null ? null : _toggleCvv,
                  ),
                ),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    child: _Tile(
                      primary: true,
                      icon: Icons.arrow_outward_rounded,
                      title: s.t('sendNearby'),
                      onTap: () => _open(const SendScreen()),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _Tile(
                      primary: false,
                      icon: Icons.sensors_rounded,
                      title: s.t('receiveNearby'),
                      onTap: () => _open(const ReceiveScreen()),
                    ),
                  ),
                ]),
                const SizedBox(height: 24),
                Text(s.t('history'), style: Q.section.copyWith(color: Q.ink)),
                const SizedBox(height: 4),
                if (app.history.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(s.t('historyEmpty'), style: Q.secondary),
                  )
                else
                  for (final item in app.history)
                    _HistoryRow(item, s: s, shown: shown, onTapAmount: hiding ? _toggleReveal : null),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({required this.icon, required this.tooltip, required this.onPressed});
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
        onPressed: onPressed,
        tooltip: tooltip,
        style: IconButton.styleFrom(
          backgroundColor: Q.surface,
          fixedSize: const Size.square(44),
          minimumSize: const Size.square(44),
          overlayColor: Q.surface2,
        ),
        icon: Icon(icon, color: Q.ink, size: 24),
      );
}

/// Плитка действия 104: иконка сверху, название в две строки снизу.
class _Tile extends StatelessWidget {
  const _Tile({required this.primary, required this.icon, required this.title, required this.onTap});
  final bool primary;
  final IconData icon;
  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = primary ? Q.onAccent : Q.ink;
    // Названия всегда в две строки, на обоих языках одинаково.
    final twoLines = title.replaceFirst(' ', '\n');
    return Semantics(
      button: true,
      label: title,
      excludeSemantics: true,
      child: Pressable(
        child: Material(
          color: primary ? Q.accent : Q.surface,
          borderRadius: BorderRadius.circular(20),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            highlightColor: primary ? Q.accentPress : Q.surface2,
            child: SizedBox(
              height: 104,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Icon(icon, size: 24, color: primary ? Q.onAccent : Q.accent),
                    Text(twoLines,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 17, height: 24 / 17, fontWeight: FontWeight.w600, color: fg)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow(this.item, {required this.s, required this.shown, this.onTapAmount});
  final Map<String, dynamic> item;
  final S s;
  final bool shown;
  final VoidCallback? onTapAmount;

  @override
  Widget build(BuildContext context) {
    final incoming = item['direction'] == 'in';
    final bluetooth = item['method'] == 'bluetooth';
    final merchant = item['is_merchant'] == true;
    final at = DateTime.fromMillisecondsSinceEpoch(((item['created_at'] as num) * 1000).round());
    final name = '${item['counterparty']}';
    final amount = '${incoming ? '+' : '−'}${money(item['amount'] as int)}';

    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 64),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          Avatar(name: name, kind: merchant ? AvatarKind.shop : AvatarKind.initial),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: Q.rowTitle.copyWith(color: Q.ink)),
              const SizedBox(height: 4),
              SizedBox(
                height: 20,
                child: Row(children: [
                  Icon(bluetooth ? Icons.bluetooth_rounded : Icons.location_on_rounded, size: 16, color: Q.ink2),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(s.date(at),
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: Q.secondary.copyWith(fontFeatures: Q.tabular)),
                  ),
                ]),
              ),
            ]),
          ),
          const SizedBox(width: 12),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTapAmount,
            child: RollingAmount(
              amount,
              mask: '•••••',
              hidden: !shown,
              style: TextStyle(
                fontSize: 16,
                height: 20 / 16,
                fontWeight: FontWeight.w600,
                color: incoming && shown ? Q.accentInk : Q.ink,
                fontFeatures: Q.tabular,
              ),
            ),
          ),
        ]),
      ),
    );
  }
}
