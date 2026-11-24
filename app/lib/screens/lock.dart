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
      appBar: QAppBar(
        back: false,
        actions: [
          TextButton(
            onPressed: app.logout,
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 44),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              textStyle: const TextStyle(fontFamily: Q.font, fontSize: 16, height: 24 / 16, fontWeight: FontWeight.w600),
            ),
            child: Text(s.t('logout')),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(children: [
          const SizedBox(height: 16),
          Avatar(name: name, kind: AvatarKind.me, size: 64),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Q.gutter),
            child: Column(children: [
              Text(s.t('hello', {'name': name}), textAlign: TextAlign.center, style: Q.titleM.copyWith(color: Q.ink)),
              const SizedBox(height: 8),
              Text(s.t('lockTitle'), textAlign: TextAlign.center, style: Q.body),
            ]),
          ),
          const SizedBox(height: 32),
          Expanded(
            child: PinPad(
              onSubmit: _submit,
              deleteLabel: s.t('pinDelete'),
              expand: true,
              leading: app.biometricReady
                  ? IconButton(
                      onPressed: _biometrics,
                      tooltip: s.t('useBio'),
                      style: IconButton.styleFrom(fixedSize: const Size.square(56)),
                      icon: ios
                          ? const FaceIdIcon(size: 32, color: Q.accent)
                          : const Icon(Icons.fingerprint_rounded, size: 32, color: Q.accent),
                    )
                  : null,
            ),
          ),
        ]),
      ),
    );
  }
}
