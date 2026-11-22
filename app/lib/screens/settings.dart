import 'package:material_ui/material_ui.dart';

import '../api.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets.dart';

/// Настройки: скрытие сумм, Face ID и устройства, на которых открыт аккаунт.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final AppState _app;
  bool _started = false;
  List<Map<String, dynamic>>? _devices;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _app = AppScope.of(context);
    _load();
  }

  Future<void> _load() async {
    try {
      final items = await _app.devices();
      if (mounted) setState(() => _devices = items);
    } on ApiError catch (e) {
      if (mounted) showError(context, _app.s.error(e.code, e.detail));
    }
  }

  Future<bool> _ask(String text) async {
    final s = _app.s;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(text),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(s.t('cancel'))),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(s.t('kick'), style: const TextStyle(color: Q.danger)),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } on ApiError catch (e) {
      if (mounted) showError(context, _app.s.error(e.code, e.detail));
    }
    await _load();
  }

  String _when(num seconds) {
    final at = DateTime.fromMillisecondsSinceEpoch((seconds * 1000).round());
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(at.day)}.${two(at.month)} · ${two(at.hour)}:${two(at.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final s = app.s;
    final devices = _devices;
    final others = devices?.where((d) => d['current'] != true).toList() ?? const [];

    return Scaffold(
      appBar: AppBar(title: Text(s.t('settings'))),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            _Header(s.t('security')),
            QCard(
              padding: EdgeInsets.zero,
              child: Column(children: [
                SwitchListTile(
                  value: app.hideSensitive,
                  onChanged: app.setHideSensitive,
                  title: Text(s.t('hideSensitive')),
                  subtitle: Text(s.t('hideSensitiveHint'), style: const TextStyle(color: Q.muted, fontSize: 13)),
                ),
                if (app.biometricAvailable) ...[
                  const Divider(height: 1, color: Q.line),
                  SwitchListTile(
                    value: app.biometricEnabled,
                    onChanged: app.setBiometric,
                    title: Text(s.t('bio')),
                  ),
                ],
              ]),
            ),
            const SizedBox(height: 24),
            _Header(s.t('devices')),
            if (devices == null)
              const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
            else
              QCard(
                padding: EdgeInsets.zero,
                child: Column(children: [
                  for (var i = 0; i < devices.length; i++) ...[
                    if (i > 0) const Divider(height: 1, color: Q.line),
                    ListTile(
                      leading: Icon(
                        '${devices[i]['name']}' == 'iPhone' ? Icons.phone_iphone_rounded : Icons.phone_android_rounded,
                        color: Q.muted,
                      ),
                      title: Text('${devices[i]['name']}'),
                      subtitle: Text(
                        devices[i]['current'] == true
                            ? s.t('thisDevice')
                            : s.t('lastSeen', {'when': _when(devices[i]['last_seen'] as num)}),
                        style: TextStyle(color: devices[i]['current'] == true ? Q.ok : Q.muted, fontSize: 13),
                      ),
                      trailing: devices[i]['current'] == true
                          ? null
                          : TextButton(
                              onPressed: () async {
                                final device = devices[i];
                                if (await _ask(s.t('kickConfirm', {'name': '${device['name']}'}))) {
                                  await _run(() => app.removeDevice('${device['id']}'));
                                }
                              },
                              child: Text(s.t('kick'), style: const TextStyle(color: Q.danger)),
                            ),
                    ),
                  ],
                ]),
              ),
            if (others.isNotEmpty) ...[
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () async {
                  if (await _ask('${s.t('kickOthers')}?')) await _run(app.logoutOthers);
                },
                child: Text(s.t('kickOthers'), style: const TextStyle(color: Q.danger)),
              ),
            ],
            const SizedBox(height: 32),
            FilledButton.tonal(
              onPressed: () async {
                Navigator.of(context).popUntil((route) => route.isFirst);
                await app.logout();
              },
              child: Text(s.t('logout')),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(6, 0, 6, 10),
        child: Text(text.toUpperCase(),
            style: const TextStyle(fontSize: 12, color: Q.muted, fontWeight: FontWeight.w700, letterSpacing: 1.4)),
      );
}
