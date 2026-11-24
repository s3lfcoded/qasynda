import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:material_ui/material_ui.dart';

import '../api.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets.dart';
import '../widgets/pin_pad.dart';

/// Экран блокировки: при запуске и после минуты в фоне. Face ID или отпечаток, иначе PIN-код,
/// который проверяет сервер — подобрать его на украденном телефоне нельзя.
class LockScreen extends StatefulWidget {
  const LockScreen({super.key});

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  bool _asked = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_asked) return;
    _asked = true;
    // Системное окно Face ID открывается само, как только экран показан.
    WidgetsBinding.instance.addPostFrameCallback((_) => _biometrics());
  }

  Future<void> _biometrics() async {
    final app = AppScope.of(context);
    try {
      await app.unlockWithBiometrics();
    } on ApiError catch (e) {
      if (mounted) showError(context, app.s.error(e.code, e.detail));
    }
  }

  Future<bool> _submit(String pin) async {
    final app = AppScope.of(context);
    try {
      await app.unlock(pin);
      return true;
    } on ApiError catch (e) {
      if (mounted) showError(context, app.s.error(e.code, e.detail));
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final s = app.s;
    final name = '${app.profile?['name'] ?? ''}'.split(' ').first;
    final ios = defaultTargetPlatform == TargetPlatform.iOS;
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
          children: [
            Align(alignment: Alignment.centerLeft, child: Avatar(name: name, size: 64)),
            const SizedBox(height: 20),
            Text(s.t('hello', {'name': name}),
                style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w900, height: 1.1)),
            const SizedBox(height: 8),
            Text(s.t('lockTitle'), style: const TextStyle(fontSize: 17, color: Q.muted)),
            const SizedBox(height: 32),
            Center(
              child: PinPad(
                onSubmit: _submit,
                deleteLabel: s.t('pinDelete'),
                leading: app.biometricReady
                    ? IconButton(
                        onPressed: _biometrics,
                        tooltip: s.t('useBio'),
                        iconSize: 32,
                        color: Q.text,
                        icon: Icon(ios ? Icons.face_rounded : Icons.fingerprint_rounded),
                      )
                    : null,
              ),
            ),
            const SizedBox(height: 16),
            Center(
              child: TextButton(onPressed: app.logout, child: Text(s.t('forgot'), style: const TextStyle(color: Q.muted))),
            ),
          ],
        ),
      ),
    );
  }
}
