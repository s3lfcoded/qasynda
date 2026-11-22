import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../api.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets.dart';

/// Экран блокировки: при запуске и после минуты в фоне. Face ID или отпечаток, иначе PIN-код,
/// который проверяет сервер — подобрать его на украденном телефоне нельзя.
class LockScreen extends StatefulWidget {
  const LockScreen({super.key});

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  final _pin = TextEditingController();
  bool _busy = false;
  bool _asked = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_asked) return;
    _asked = true;
    // Системное окно Face ID открывается само, как только экран показан.
    WidgetsBinding.instance.addPostFrameCallback((_) => _biometrics());
  }

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  bool get _valid => RegExp(r'^\d{4,6}$').hasMatch(_pin.text);

  Future<void> _biometrics() async {
    final app = AppScope.of(context);
    try {
      await app.unlockWithBiometrics();
    } on ApiError catch (e) {
      if (mounted) showError(context, app.s.error(e.code, e.detail));
    }
  }

  Future<void> _submit() async {
    final app = AppScope.of(context);
    setState(() => _busy = true);
    try {
      await app.unlock(_pin.text);
    } on ApiError catch (e) {
      _pin.clear();
      if (mounted) showError(context, app.s.error(e.code, e.detail));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final s = app.s;
    final name = '${app.profile?['name'] ?? ''}'.split(' ').first;
    return Scaffold(
      body: SafeArea(
        child: ListView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.fromLTRB(24, 72, 24, 24),
          children: [
            Align(alignment: Alignment.centerLeft, child: Avatar(name: name, size: 64)),
            const SizedBox(height: 20),
            Text(s.t('hello', {'name': name}),
                style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w900, height: 1.1)),
            const SizedBox(height: 8),
            Text(s.t('lockTitle'), style: const TextStyle(fontSize: 17, color: Q.muted)),
            const SizedBox(height: 32),
            TextField(
              controller: _pin,
              autofocus: !(app.biometricAvailable && app.biometricEnabled),
              keyboardType: TextInputType.number,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
              decoration: InputDecoration(labelText: s.t('lockHint')),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _valid && !_busy ? _submit() : null,
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _valid && !_busy ? _submit : null,
              child: _busy
                  ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Q.onAccent))
                  : Text(s.t('unlock')),
            ),
            if (app.biometricAvailable && app.biometricEnabled) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _busy ? null : _biometrics,
                icon: const Icon(Icons.fingerprint_rounded),
                label: Text(s.t('useBio')),
              ),
            ],
            const SizedBox(height: 24),
            TextButton(onPressed: app.logout, child: Text(s.t('forgot'), style: const TextStyle(color: Q.muted))),
          ],
        ),
      ),
    );
  }
}
