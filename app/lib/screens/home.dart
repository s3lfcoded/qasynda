import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../bank_card.dart';
import '../l10n.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets.dart';
import 'receive.dart';
import 'send.dart';
import 'settings.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  StreamSubscription<Map<String, dynamic>>? _sub;
  StreamSubscription<Map<String, dynamic>>? _alerts;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = AppScope.of(context);
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

  @override
  void dispose() {
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

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: darkOverlay,
      child: Scaffold(
        body: SafeArea(
          bottom: false,
          child: RefreshIndicator(
            color: Q.onAccent,
            backgroundColor: Q.accent,
            onRefresh: () => app.refresh().catchError((_) {}),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
              children: [
                Row(children: [
                  Avatar(name: firstName, size: 42),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(firstName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, height: 1.15)),
                      Sensitive(
                        builder: (_, shown) => Text(shown ? '${profile['phone']}' : '+7 $masked ${'${profile['phone']}'.substring(10)}',
                            style: const TextStyle(fontSize: 13, color: Q.muted, fontFeatures: Q.tabular)),
                      ),
                    ]),
                  ),
                  const LangToggle(),
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: s.t('settings'),
                    onPressed: () => _open(const SettingsScreen()),
                    icon: const Icon(Icons.settings_outlined, color: Q.muted, size: 22),
                  ),
                ]),
                const SizedBox(height: 28),
                Text(s.t('balance').toUpperCase(),
                    style: const TextStyle(fontSize: 12, color: Q.muted, fontWeight: FontWeight.w700, letterSpacing: 1.4)),
                const SizedBox(height: 4),
                Sensitive(
                  builder: (_, shown) => FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(shown ? money(profile['balance'] as int) : '$masked ₸',
                        style: const TextStyle(
                            fontSize: 46, fontWeight: FontWeight.w800, height: 1.1, letterSpacing: -1.2, fontFeatures: Q.tabular)),
                  ),
                ),
                const SizedBox(height: 20),
                Sensitive(
                  builder: (_, shown) => BankCard(
                    holder: name,
                    last4: shown ? '${profile['card_last4'] ?? '0000'}' : masked,
                    business: merchant ? '${profile['business_name']}' : null,
                  ),
                ),
                const SizedBox(height: 12),
                IntrinsicHeight(
                  child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Expanded(
                      child: _Action(
                        primary: true,
                        icon: Icons.near_me_rounded,
                        title: s.t('sendNearby'),
                        hint: s.t('sendNearbyHint'),
                        onTap: () => _open(const SendScreen()),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _Action(
                        primary: false,
                        icon: Icons.sensors_rounded,
                        title: s.t('receiveNearby'),
                        hint: s.t('receiveNearbyHint'),
                        onTap: () => _open(const ReceiveScreen()),
                      ),
                    ),
                  ]),
                ),
                const SizedBox(height: 32),
                Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
                  Text(s.t('history'), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
                  const SizedBox(width: 8),
                  if (app.history.isNotEmpty)
                    Text('${app.history.length}',
                        style: const TextStyle(fontSize: 15, color: Q.faint, fontWeight: FontWeight.w700, fontFeatures: Q.tabular)),
                ]),
                const SizedBox(height: 12),
                if (app.history.isEmpty)
                  QCard(
                    child: Row(children: [
                      const Icon(Icons.receipt_long_outlined, color: Q.faint, size: 22),
                      const SizedBox(width: 12),
                      Text(s.t('historyEmpty'), style: const TextStyle(color: Q.muted, fontSize: 15)),
                    ]),
                  )
                else
                  QCard(
                    padding: EdgeInsets.zero,
                    child: Column(children: [
                      for (var i = 0; i < app.history.length; i++) ...[
                        if (i > 0) const Divider(height: 1, thickness: 1, indent: 72, color: Q.line),
                        _HistoryRow(app.history[i]),
                      ],
                    ]),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({required this.primary, required this.icon, required this.title, required this.hint, required this.onTap});
  final bool primary;
  final IconData icon;
  final String title;
  final String hint;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return QCard(
      onTap: onTap,
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(color: primary ? Q.accent : Q.raised, borderRadius: BorderRadius.circular(14)),
            child: Icon(icon, size: 22, color: primary ? Q.onAccent : Q.text),
          ),
          const Spacer(),
          const Icon(Icons.arrow_outward_rounded, size: 18, color: Q.faint),
        ]),
        const SizedBox(height: 22),
        Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, height: 1.2, letterSpacing: -0.2)),
        const SizedBox(height: 4),
        Text(hint, style: const TextStyle(fontSize: 13, color: Q.muted, height: 1.25)),
      ]),
    );
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow(this.item);
  final Map<String, dynamic> item;

  @override
  Widget build(BuildContext context) {
    final incoming = item['direction'] == 'in';
    final bluetooth = item['method'] == 'bluetooth';
    final at = DateTime.fromMillisecondsSinceEpoch(((item['created_at'] as num) * 1000).round());
    String two(int v) => v.toString().padLeft(2, '0');
    final when = '${two(at.day)}.${two(at.month)} · ${two(at.hour)}:${two(at.minute)}';

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Row(children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(color: Q.raised, borderRadius: BorderRadius.circular(14)),
          child: Icon(incoming ? Icons.south_west_rounded : Icons.north_east_rounded,
              color: incoming ? Q.ok : Q.text, size: 20),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${item['counterparty']}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600)),
            const SizedBox(height: 3),
            Row(children: [
              Icon(bluetooth ? Icons.bluetooth_rounded : Icons.location_on_rounded, size: 13, color: Q.faint),
              const SizedBox(width: 3),
              Text('${bluetooth ? 'Bluetooth' : 'GPS'} · $when',
                  style: const TextStyle(fontSize: 12.5, color: Q.muted, fontFeatures: Q.tabular)),
            ]),
          ]),
        ),
        const SizedBox(width: 10),
        Sensitive(
          builder: (_, shown) => Text('${incoming ? '+' : '−'}${shown ? money(item['amount'] as int) : '$masked ₸'}',
              style: TextStyle(
                  fontSize: 15.5, fontWeight: FontWeight.w700, color: incoming ? Q.ok : Q.text, fontFeatures: Q.tabular)),
        ),
      ]),
    );
  }
}
