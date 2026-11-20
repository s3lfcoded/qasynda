import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../l10n.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets.dart';
import 'receive.dart';
import 'send.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  StreamSubscription<Map<String, dynamic>>? _sub;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = AppScope.of(context);
    _sub ??= app.incoming.listen((event) {
      // На экране приёма перевод показывается крупно, здесь — короткое уведомление.
      if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
      showError(context,
          '${app.s.t('received', {'sum': money(event['amount'] as int)})} · ${app.s.t('from', {'name': '${event['sender']}'})}');
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _open(Widget screen) {
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
    final firstName = (profile['name'] as String).split(' ').first;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Qasynda'),
        actions: [
          const LangToggle(),
          IconButton(tooltip: s.t('logout'), onPressed: app.logout, icon: const Icon(Icons.logout_rounded)),
          const SizedBox(width: 8),
        ],
      ),
      body: RefreshIndicator(
        color: Q.ink,
        onRefresh: () => app.refresh().catchError((_) {}),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
              child: Text(s.t('hello', {'name': firstName}), style: const TextStyle(fontSize: 16, color: Q.muted)),
            ),
            QCard(
              color: Q.ink,
              padding: const EdgeInsets.all(24),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(s.t('balance'), style: const TextStyle(color: Colors.white60, fontSize: 15)),
                const SizedBox(height: 6),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(money(profile['balance'] as int),
                      style: const TextStyle(color: Colors.white, fontSize: 40, fontWeight: FontWeight.w800, height: 1.1)),
                ),
                if (profile['is_merchant'] == true) ...[
                  const SizedBox(height: 14),
                  Pill(icon: Icons.verified_rounded, label: '${profile['business_name']}', color: Q.accent),
                ],
              ]),
            ),
            const SizedBox(height: 12),
            IntrinsicHeight(
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Expanded(
                  child: _Action(
                    color: Q.accent,
                    icon: Icons.near_me_rounded,
                    title: s.t('sendNearby'),
                    hint: s.t('sendNearbyHint'),
                    onTap: () => _open(const SendScreen()),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _Action(
                    color: Q.surface,
                    icon: Icons.sensors_rounded,
                    title: s.t('receiveNearby'),
                    hint: s.t('receiveNearbyHint'),
                    onTap: () => _open(const ReceiveScreen()),
                  ),
                ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 28, 4, 12),
              child: Text(s.t('history'), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            ),
            if (app.history.isEmpty)
              QCard(child: Text(s.t('historyEmpty'), style: const TextStyle(color: Q.muted)))
            else
              QCard(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(children: [for (final item in app.history) _HistoryRow(item)]),
              ),
          ],
        ),
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({required this.color, required this.icon, required this.title, required this.hint, required this.onTap});
  final Color color;
  final IconData icon;
  final String title;
  final String hint;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return QCard(
      color: color,
      onTap: onTap,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 30, color: Q.ink),
        const SizedBox(height: 28),
        Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, height: 1.15)),
        const SizedBox(height: 4),
        Text(hint, style: TextStyle(fontSize: 13, color: Q.ink.withValues(alpha: 0.6))),
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
    final at = DateTime.fromMillisecondsSinceEpoch(((item['created_at'] as num) * 1000).round());
    String two(int v) => v.toString().padLeft(2, '0');
    final when = '${two(at.day)}.${two(at.month)} ${two(at.hour)}:${two(at.minute)}';
    final method = item['method'] == 'bluetooth' ? 'Bluetooth' : 'GPS';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(color: Q.bg, borderRadius: BorderRadius.circular(15)),
          child: Icon(incoming ? Icons.south_west_rounded : Icons.north_east_rounded,
              color: incoming ? Q.ok : Q.ink, size: 22),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${item['counterparty']}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text('$method · $when', style: const TextStyle(fontSize: 13, color: Q.muted)),
          ]),
        ),
        const SizedBox(width: 8),
        Text('${incoming ? '+' : '−'}${money(item['amount'] as int)}',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: incoming ? Q.ok : Q.ink)),
      ]),
    );
  }
}
