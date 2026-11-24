import 'dart:async';

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../api.dart';
import '../bank_card.dart';
import '../cards.dart';
import '../l10n.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets.dart';
import '../widgets/pin_pad.dart';
import 'add_card.dart';
import 'onboarding.dart';
import 'topup.dart';
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

  /// Реквизиты карты (оборот и CVV) показываются только после Face ID или кода. Подтверждение
  /// действует 5 минут и сбрасывается при уходе в фон и когда карта возвращается на лицо.
  DateTime? _detailsUntil;
  bool _revealed = false;

  @override
  void initState() {
    super.initState();
    _life = AppLifecycleListener(onInactive: _hideCvv, onHide: _closeDetails);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = AppScope.of(context);
    // После входа: сначала вопрос про Face ID, затем (с нового телефона и без карт) привязка карты.
    if ((app.offerBiometrics || app.offerCards) && !_offered) {
      _offered = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _afterLogin());
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

  Future<void> _afterLogin() async {
    final app = AppScope.of(context);
    final steps = app.registrationSteps;
    app.registrationSteps = false;
    if (app.offerBiometrics) {
      if (steps) {
        await Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => const BiometricOfferScreen(steps: true)));
      } else {
        await _offerBiometrics();
      }
    }
    if (!mounted || !app.offerCards) return;
    app.offerCards = false;
    await _offerCards(steps: steps);
  }

  /// «Входить по Face ID?» — биометрия привязывается только по «Включить». Закрыли шторку — спросим
  /// при следующем входе; «Не сейчас» — больше не спрашиваем.
  Future<void> _offerBiometrics() async {
    final app = AppScope.of(context);
    final s = app.s;
    final ios = defaultTargetPlatform == TargetPlatform.iOS;
    final answer = await showQSheet<bool>(context, (context) {
      return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Center(
          child: Container(
            width: 64,
            height: 64,
            alignment: Alignment.center,
            decoration: const BoxDecoration(color: Q.accentSoft, shape: BoxShape.circle),
            child: ios ? const FaceIdIcon(size: 32) : const Icon(Icons.fingerprint_rounded, size: 32, color: Q.accent),
          ),
        ),
        const SizedBox(height: 16),
        Text(s.t(ios ? 'bioOfferFace' : 'bioOfferFinger'), textAlign: TextAlign.center, style: Q.titleM.copyWith(color: Q.ink)),
        const SizedBox(height: 8),
        Text(s.t('bioOfferHint'), textAlign: TextAlign.center, style: Q.body),
        const SizedBox(height: 24),
        QButton(label: s.t('enable'), onPressed: () => Navigator.pop(context, true)),
        const SizedBox(height: 8),
        QButton(kind: QButtonKind.secondary, label: s.t('notNow'), onPressed: () => Navigator.pop(context, false)),
      ]);
    });
    if (answer == null) {
      app.offerBiometrics = false;
      return;
    }
    final ok = await app.answerBiometrics(answer);
    if (answer && !ok && mounted) showError(context, s.t('bioFailed'));
  }

  /// Face ID, если биометрия привязана, иначе код (его проверяет сервер).
  Future<bool> _confirmDetails() async {
    final until = _detailsUntil;
    if (until != null && DateTime.now().isBefore(until)) return true;
    final app = AppScope.of(context);
    final ok = app.biometricReady ? await app.confirmWithBiometrics() : await _confirmWithPin();
    if (ok) _detailsUntil = DateTime.now().add(const Duration(minutes: 5));
    return ok;
  }

  Future<bool> _confirmWithPin() async {
    final app = AppScope.of(context);
    final s = app.s;
    final ok = await showQSheet<bool>(context, (context) {
      return Column(mainAxisSize: MainAxisSize.min, children: [
        Text(s.t('confirmTitle'), textAlign: TextAlign.center, style: Q.titleM.copyWith(color: Q.ink)),
        const SizedBox(height: 8),
        Text(s.t('confirmReason'), textAlign: TextAlign.center, style: Q.body),
        const SizedBox(height: 24),
        PinPad(
          deleteLabel: s.t('pinDelete'),
          onSubmit: (pin) async {
            try {
              await app.confirmWithPin(pin);
              if (context.mounted) Navigator.pop(context, true);
              return true;
            } on ApiError catch (e) {
              if (context.mounted) showError(context, app.s.error(e.code, e.detail));
              if (!app.loggedIn && context.mounted) Navigator.pop(context, false);
              return false;
            }
          },
        ),
        const SizedBox(height: 16),
      ]);
    });
    return ok == true;
  }

  Future<void> _offerCards({bool steps = false}) async {
    final app = AppScope.of(context);
    try {
      final list = await CardsApi(app.api).list();
      if (!mounted || list.items.isNotEmpty) return;
      await Navigator.of(context).push<BankCard>(
        MaterialPageRoute(builder: (_) => AddCardScreen(onboarding: true, steps: steps)),
      );
    } catch (_) {
      // Не получилось узнать про карты — не мешаем: привязать можно в настройках.
    }
  }

  /// Оборот открывается закрытым; реквизиты — по «Показать» после Face ID или кода.
  void _onCardSide(bool back) {
    if (!back) _closeDetails();
  }

  void _closeDetails() {
    _detailsUntil = null;
    _cvvTimer?.cancel();
    if (mounted && (_revealed || _cvv)) {
      setState(() {
        _revealed = false;
        _cvv = false;
      });
    }
  }

  Future<void> _revealDetails() async {
    if (!await _confirmDetails() || !mounted) return;
    if (await _loadSecret() && mounted) setState(() => _revealed = true);
  }

  /// Реквизиты запрашиваются один раз и живут в памяти до выхода из аккаунта.
  Future<bool> _loadSecret() async {
    final app = AppScope.of(context);
    if (app.virtualSecret != null) return true;
    if (_fetchingSecret) return false;
    _fetchingSecret = true;
    try {
      app.virtualSecret = await CardsApi(app.api).virtualSecret();
      return true;
    } on ApiError catch (e) {
      if (mounted) showError(context, app.s.error(e.code, e.detail));
      return false;
    } finally {
      _fetchingSecret = false;
    }
  }

  void _hideCvv() {
    _cvvTimer?.cancel();
    if (_cvv && mounted) setState(() => _cvv = false);
  }

  Future<void> _toggleCvv() async {
    if (_cvv) return _hideCvv();
    if (!await _confirmDetails() || !mounted) return;
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
                Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: hiding ? _toggleReveal : null,
                      child: Semantics(
                        hint: hiding ? s.t('tapToShow') : null,
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          SizedBox(
                            height: 20,
                            child: Row(children: [
                              Text(
                                shown ? s.t('balance') : s.t('showBalance'),
                                style: Q.label.copyWith(
                                  color: shown ? Q.ink2 : Q.accentInk,
                                  fontWeight: shown ? FontWeight.w400 : FontWeight.w600,
                                ),
                              ),
                              if (hiding) ...[
                                const SizedBox(width: 8),
                                Icon(shown ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                                    size: 16, color: shown ? Q.ink2 : Q.accentInk),
                              ],
                            ]),
                          ),
                          const SizedBox(height: 4),
                          SizedBox(
                            height: 48,
                            child: Align(
                              alignment: AlignmentDirectional.centerStart,
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
                          ),
                        ]),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: _Pill(icon: Icons.add_rounded, label: s.t('topup'), onTap: () => _open(const TopupScreen())),
                  ),
                ]),
                const SizedBox(height: 16),
                // Нажатие или свайп переворачивают карту: на обороте реквизиты учебной карты, закрытые до Face ID.
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
                    number: _revealed ? app.virtualSecret?.number : null,
                    expiry: _revealed ? app.virtualSecret?.expiry : null,
                    cvv: _revealed ? app.virtualSecret?.cvv : null,
                    cvvShown: _cvv,
                    revealed: _revealed,
                    confirmCaption: s.t('confirmToShow'),
                    revealLabel: s.t('show'),
                    onReveal: _revealDetails,
                    biometricIcon: defaultTargetPlatform == TargetPlatform.iOS
                        ? const FaceIdIcon(size: 20, color: Q.ink)
                        : const Icon(Icons.fingerprint_rounded, size: 20, color: Q.ink),
                    copyLabel: s.t('copyNumber'),
                    showCvvLabel: s.t('showCvv'),
                    hideCvvLabel: s.t('hideCvv'),
                    onCopy: _revealed ? _copyNumber : null,
                    onToggleCvv: _revealed ? _toggleCvv : null,
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
    final method = '${item['method']}';
    final topup = method == 'topup';
    final demo = method == 'demo';
    final at = DateTime.fromMillisecondsSinceEpoch(((item['created_at'] as num) * 1000).round());
    final counterparty = '${item['counterparty']}';
    // «Пополнение с Visa •• 1111» → заголовок «Пополнение с карты», ниже «Visa •• 1111, 24 ноября».
    final card = counterparty.replaceFirst(RegExp(r'^Пополнение с\s*'), '');
    final name = topup ? s.t('topupRow') : counterparty;
    final meta = topup ? '$card, ${s.day(at)}' : s.date(at);
    final metaIcon = topup
        ? Icons.credit_card_rounded
        : demo
            ? Icons.smart_toy_outlined
            : bluetooth
                ? Icons.bluetooth_rounded
                : Icons.location_on_rounded;
    final avatar = topup
        ? AvatarKind.topup
        : demo
            ? (merchant ? AvatarKind.botShop : AvatarKind.bot)
            : (merchant ? AvatarKind.shop : AvatarKind.initial);
    final amount = '${incoming ? '+' : '−'}${money(item['amount'] as int)}';

    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 64),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          Avatar(name: name, kind: avatar),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: Q.rowTitle.copyWith(color: Q.ink)),
              const SizedBox(height: 4),
              SizedBox(
                height: 20,
                child: Row(children: [
                  Icon(metaIcon, size: 16, color: Q.ink2),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(meta,
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

/// Пилюля «Пополнить»: 36, accentSoft, иконка 20, текст 15/600.
class _Pill extends StatelessWidget {
  const _Pill({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
        child: Material(
          color: Q.accentSoft,
          shape: const StadiumBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            highlightColor: const Color(0xFFD2E9E4),
            child: Container(
              height: 36,
              padding: const EdgeInsets.only(left: 8, right: 12),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(icon, size: 20, color: Q.accentInk),
                const SizedBox(width: 4),
                Text(label, style: Q.label.copyWith(color: Q.accentInk)),
              ]),
            ),
          ),
        ),
      );
}
