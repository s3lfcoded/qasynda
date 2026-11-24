import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../api.dart';
import '../l10n.dart';
import '../nearby.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets.dart';
import 'send.dart' show limitBluetooth, limitGps;

/// «Принять рядом»: пока экран открыт, телефон виден отправителям поблизости.
class ReceiveScreen extends StatefulWidget {
  const ReceiveScreen({super.key});

  @override
  State<ReceiveScreen> createState() => _ReceiveScreenState();
}

class _ReceiveScreenState extends State<ReceiveScreen> {
  final _advertiser = Advertiser();
  late final AppState _app;
  StreamSubscription<Map<String, dynamic>>? _sub;
  Timer? _timer;
  bool _started = false;
  bool _bluetooth = false;
  bool _gps = false;
  bool _online = true;
  bool _checked = false; // Bluetooth и геолокация уже опрошены: до этого предупреждение не показываем
  Map<String, dynamic>? _last;
  String? _bleId;
  bool _disposed = false;

  /// Учебный бот Алия: просьба перевести 5 000 ₸. null — кнопки нет (не учебный режим).
  bool _aliyaAvailable = true;
  bool _aliyaSending = false;
  static const _aliyaAmount = 5000 * 100;

  Future<void> _askAliya() async {
    setState(() => _aliyaSending = true);
    try {
      await _app.api.post('/demo/request', {'amount': _aliyaAmount});
      // Перевод придёт по WebSocket как обычное поступление.
    } on ApiError catch (e) {
      if (!mounted) return;
      if (e.code == 'not_found') {
        setState(() => _aliyaAvailable = false);
      } else {
        showError(context, _app.s.error(e.code, e.detail));
      }
    } finally {
      if (mounted) setState(() => _aliyaSending = false);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _app = AppScope.of(context);
    _sub = _app.incoming.listen((event) {
      if (!mounted) return;
      HapticFeedback.mediumImpact(); // короткий отклик: деньги пришли
      setState(() => _last = event);
    });
    _begin();
  }

  Future<void> _begin() async {
    await _advertise(await _beat());
    if (!mounted) return;
    setState(() => _checked = true);
    _timer = Timer.periodic(const Duration(seconds: 15), (_) async => _advertise(await _beat()));
  }

  /// Сервер периодически выдаёт новую Bluetooth-метку: старую перестаём транслировать.
  Future<void> _advertise(String? bleId) async {
    // Метка запоминается только после удачного запуска трансляции: иначе неудачный запуск
    // не повторялся бы до следующей смены метки.
    if (!mounted || bleId == null || (bleId == _bleId && _bluetooth)) return;
    if (_bleId != null) await _advertiser.stop();
    final ok = await _advertiser.start(bleId);
    if (!mounted) {
      await _advertiser.stop();
      return;
    }
    _bleId = ok ? bleId : null;
    setState(() => _bluetooth = ok);
  }

  /// Продлевает маяк на сервере. Возвращает идентификатор для трансляции по Bluetooth.
  Future<String?> _beat() async {
    final location = await currentLocation();
    // Пока ждали координаты (до 8 секунд), экран могли закрыть: тогда маяк создавать нельзя.
    if (_disposed) return null;
    try {
      final beacon = await _app.api.post('/nearby/beacon', {'location': location});
      if (_disposed) {
        // Запрос ушёл до закрытия экрана, а дошёл после выключения маяка — выключаем ещё раз.
        _app.api.delete('/nearby/beacon').catchError((_) => <String, dynamic>{});
        return null;
      }
      if (mounted) {
        setState(() {
          _gps = beacon['gps'] == 'ok';
          _online = true;
        });
      }
      return beacon['ble_id'] as String;
    } on ApiError {
      if (mounted) setState(() => _online = false);
      return null;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _sub?.cancel();
    _advertiser.stop();
    _app.api.delete('/nearby/beacon').catchError((_) => <String, dynamic>{});
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = _app.s;
    final last = _last;
    final initial = '${_app.profile?['name'] ?? ''}';
    // Лимит приёма зависит от того, что работает: Bluetooth точнее, поэтому до 500 000 ₸.
    Widget status({
      required bool on,
      required IconData onIcon,
      required IconData offIcon,
      required String title,
      required String hint,
      required int sum,
    }) =>
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(children: [
              Icon(on ? onIcon : offIcon, color: on ? Q.accent : Q.amberInk),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: Q.label.copyWith(color: Q.ink)),
                  const SizedBox(height: 4),
                  Text.rich(
                    TextSpan(style: Q.secondary, children: [
                      for (final (i, part) in s.t(hint).split('{sum}').indexed) ...[
                        if (i > 0)
                          WidgetSpan(
                            alignment: PlaceholderAlignment.baseline,
                            baseline: TextBaseline.alphabetic,
                            child: RollingAmount(money(sum), style: Q.secondary.copyWith(fontFeatures: Q.tabular)),
                          ),
                        TextSpan(text: part),
                      ],
                    ]),
                  ),
                ]),
              ),
            ]),
          ),
        );

    return Scaffold(
      appBar: QAppBar(title: s.t('receiveNearby')),
      body: SafeArea(
        top: false,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(Q.gutter, 16, Q.gutter, 16),
              children: last == null
                  ? [
                      Center(
                        child: RadiusRings(
                          size: 192,
                          child: Container(
                            width: 64,
                            height: 64,
                            alignment: Alignment.center,
                            decoration: const BoxDecoration(color: Q.accent, shape: BoxShape.circle),
                            child: Text(initial.isEmpty ? '' : initial.characters.first.toUpperCase(),
                                style: const TextStyle(fontSize: 24, height: 1, fontWeight: FontWeight.w600, color: Q.onAccent)),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Column(children: [
                          Text(_online ? s.t('visible') : s.t('err.network'),
                              textAlign: TextAlign.center, style: Q.titleM.copyWith(color: Q.ink)),
                          const SizedBox(height: 8),
                          Text(s.t('visibleHint'), textAlign: TextAlign.center, style: Q.body),
                        ]),
                      ),
                      const SizedBox(height: 24),
                      QGroup(dividerIndent: 52, children: [
                        status(
                          on: _bluetooth || !_checked,
                          onIcon: Icons.bluetooth_rounded,
                          offIcon: Icons.bluetooth_disabled_rounded,
                          title: s.t(_bluetooth || !_checked ? 'btOn' : 'btOff'),
                          hint: _bluetooth || !_checked ? 'canReceive' : 'btEnable',
                          sum: limitBluetooth,
                        ),
                        status(
                          on: _gps || !_checked,
                          onIcon: Icons.location_on_rounded,
                          offIcon: Icons.location_off_rounded,
                          title: s.t(_gps || !_checked ? 'gpsOn' : 'gpsOff'),
                          hint: _gps || !_checked ? 'canReceive' : 'gpsEnable',
                          sum: limitGps,
                        ),
                      ]),
                      if (_checked && !_bluetooth && !_gps) ...[
                        const SizedBox(height: 16),
                        Text(s.t('needNearby'), textAlign: TextAlign.center, style: Q.secondary.copyWith(color: Q.amberInk)),
                      ],
                    ]
                  : [
                      const SizedBox(height: 32),
                      Center(
                        child: TweenAnimationBuilder<double>(
                          tween: Tween(begin: MediaQuery.disableAnimationsOf(context) ? 1 : 0.6, end: 1),
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
                      Text(s.t('receivedHidden'),
                          textAlign: TextAlign.center, style: Q.appBar.copyWith(color: Q.ink2, fontWeight: FontWeight.w400)),
                      const SizedBox(height: 4),
                      Center(
                        child: Sensitive(
                          builder: (_, shown) => RollingAmount(
                            '+${money(last['amount'] as int)}',
                            key: ValueKey(last),
                            style: Q.balance.copyWith(color: Q.accentInk),
                            hidden: !shown,
                            rollIn: true,
                            delay: const Duration(milliseconds: 120),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(s.t('from', {'name': '${last['sender']}'}),
                          textAlign: TextAlign.center, style: Q.body.copyWith(color: Q.ink2)),
                      if (last['note'] != null && '${last['note']}'.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        Text('«${last['note']}»',
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 16, height: 24 / 16, color: Q.ink)),
                      ],
                    ],
            ),
          ),
          if (_aliyaAvailable && last == null) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Q.gutter),
              child: _BotButton(
                label: _aliyaSending ? s.t('aliyaSending') : s.t('askAliya', {'sum': money(_aliyaAmount)}),
                busy: _aliyaSending,
                onPressed: _aliyaSending ? null : _askAliya,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(Q.gutter + 16, 8, Q.gutter + 16, 16),
              child: Text(s.t('aliyaHint'),
                  textAlign: TextAlign.center, style: const TextStyle(fontSize: 13, height: 16 / 13, color: Q.ink2)),
            ),
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(Q.gutter, 0, Q.gutter, 8),
            child: QButton(label: s.t('done'), onPressed: () => Navigator.pop(context)),
          ),
        ]),
      ),
    );
  }
}

/// Кнопка учебного бота: botSoft, текст botInk, иконка smart_toy.
class _BotButton extends StatelessWidget {
  const _BotButton({required this.label, required this.onPressed, this.busy = false});
  final String label;
  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) => Pressable(
        enabled: onPressed != null,
        child: Material(
          color: Q.botSoft,
          borderRadius: BorderRadius.circular(16),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            highlightColor: const Color(0xFFD9E1EF),
            child: SizedBox(
              height: 56,
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                if (busy)
                  const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2.5, color: Q.botInk))
                else
                  const Icon(Icons.smart_toy_rounded, size: 20, color: Q.botInk),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 17, height: 24 / 17, fontWeight: FontWeight.w600, color: Q.botInk, fontFeatures: Q.tabular)),
                ),
              ]),
            ),
          ),
        ),
      );
}
