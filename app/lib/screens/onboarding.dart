import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:material_ui/material_ui.dart';

import '../state.dart';
import '../theme.dart';
import '../widgets.dart';

/// «Входить по Face ID?» во весь экран — шаг 3 регистрации. «Включить» вызывает системный запрос
/// биометрии; после успеха и после отказа — дальше, без ошибки. «Не сейчас» оставляет вход по коду,
/// включить можно в «Безопасности».
class BiometricOfferScreen extends StatefulWidget {
  const BiometricOfferScreen({super.key, this.steps = false});

  /// Показать полоску шагов регистрации.
  final bool steps;

  @override
  State<BiometricOfferScreen> createState() => _BiometricOfferScreenState();
}

class _BiometricOfferScreenState extends State<BiometricOfferScreen> {
  bool _busy = false;

  Future<void> _answer(bool yes) async {
    final app = AppScope.of(context);
    setState(() => _busy = true);
    await app.answerBiometrics(yes);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context).s;
    final ios = defaultTargetPlatform == TargetPlatform.iOS;
    return Scaffold(
      appBar: QAppBar(middle: widget.steps ? const StepsBar(count: 4, done: 3) : null),
      body: SafeArea(
        top: false,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(
            child: ListView(padding: const EdgeInsets.fromLTRB(Q.gutter, 32, Q.gutter, 16), children: [
              Center(
                child: RadiusRings(
                  size: 224,
                  child: ios ? const FaceIdIcon(size: 64) : const Icon(Icons.fingerprint_rounded, size: 64, color: Q.accent),
                ),
              ),
              const SizedBox(height: 24),
              Text(s.t(ios ? 'bioOfferFace' : 'bioOfferFinger'), textAlign: TextAlign.center, style: Q.titleM.copyWith(color: Q.ink)),
              const SizedBox(height: 8),
              Text(s.t(ios ? 'bioOfferHint' : 'bioOfferHintFinger'), textAlign: TextAlign.center, style: Q.body),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Q.gutter),
            child: QButton(label: s.t('enable'), busy: _busy, onPressed: () => _answer(true)),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 44,
            child: TextButton(
              onPressed: _busy ? null : () => _answer(false),
              style: TextButton.styleFrom(
                textStyle: const TextStyle(fontFamily: Q.font, fontSize: 16, height: 24 / 16, fontWeight: FontWeight.w600),
              ),
              child: Text(s.t('notNow')),
            ),
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }
}
