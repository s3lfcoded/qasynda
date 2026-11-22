import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../api.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _phone = TextEditingController(text: '+7');
  final _pin = TextEditingController();
  final _code = TextEditingController();
  bool _busy = false;
  SmsChallenge? _challenge;

  @override
  void dispose() {
    _phone.dispose();
    _pin.dispose();
    _code.dispose();
    super.dispose();
  }

  bool get _valid => RegExp(r'^\+7\d{10}$').hasMatch(_phone.text) && RegExp(r'^\d{4,6}$').hasMatch(_pin.text);
  bool get _codeValid => RegExp(r'^\d{6}$').hasMatch(_code.text);

  Future<void> _submit() async {
    final app = AppScope.of(context);
    setState(() => _busy = true);
    try {
      final challenge = _challenge;
      if (challenge == null) {
        final next = await app.login(_phone.text, _pin.text);
        if (mounted && next != null) setState(() => _challenge = next);
      } else {
        await app.confirm(challenge, _code.text, _pin.text);
      }
    } on ApiError catch (e) {
      if (!mounted) return;
      if (e.code == 'challenge_expired') _back();
      final message = _challenge != null && e.code == 'invalid_credentials' ? app.s.t('smsWrong') : app.s.error(e.code, e.detail);
      showError(context, message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _back() => setState(() {
        _challenge = null;
        _code.clear();
      });

  Future<void> _editServer() async {
    final app = AppScope.of(context);
    final controller = TextEditingController(text: app.api.baseUrl);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(app.s.t('server')),
        content: TextField(controller: controller, keyboardType: TextInputType.url, autocorrect: false),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, controller.text), child: Text(app.s.t('save'))),
        ],
      ),
    );
    if (value != null && value.trim().isNotEmpty) await app.setServer(value);
  }

  Widget _spinner() =>
      const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Q.onAccent));

  List<Widget> _credentials(BuildContext context) {
    final s = AppScope.of(context).s;
    return [
      TextField(
        controller: _phone,
        keyboardType: TextInputType.phone,
        autofillHints: const [AutofillHints.telephoneNumber],
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[+\d]')), LengthLimitingTextInputFormatter(12)],
        decoration: InputDecoration(labelText: s.t('phone')),
        onChanged: (_) => setState(() {}),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _pin,
        keyboardType: TextInputType.number,
        obscureText: true,
        enableSuggestions: false,
        autocorrect: false,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
        decoration: InputDecoration(labelText: s.t('pin')),
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) => _valid && !_busy ? _submit() : null,
      ),
      const SizedBox(height: 24),
      FilledButton(onPressed: _valid && !_busy ? _submit : null, child: _busy ? _spinner() : Text(s.t('login'))),
    ];
  }

  List<Widget> _sms(BuildContext context, SmsChallenge challenge) {
    final s = AppScope.of(context).s;
    final demo = challenge.demoCode;
    return [
      Text(s.t('smsTitle'), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
      const SizedBox(height: 8),
      Text(s.t('smsHint', {'phone': _phone.text}), style: const TextStyle(fontSize: 15, color: Q.muted, height: 1.35)),
      if (demo != null) ...[
        const SizedBox(height: 16),
        // Учебный режим сервера: настоящего SMS нет, код показывается здесь.
        Pill(icon: Icons.sms_outlined, label: s.t('demoSms', {'code': demo}), color: Q.blue),
      ],
      const SizedBox(height: 20),
      TextField(
        controller: _code,
        autofocus: true,
        keyboardType: TextInputType.number,
        autofillHints: const [AutofillHints.oneTimeCode],
        inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
        style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: 6),
        decoration: InputDecoration(labelText: s.t('smsCode')),
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) => _codeValid && !_busy ? _submit() : null,
      ),
      const SizedBox(height: 24),
      FilledButton(onPressed: _codeValid && !_busy ? _submit : null, child: _busy ? _spinner() : Text(s.t('confirm'))),
      const SizedBox(height: 8),
      TextButton(onPressed: _busy ? null : _back, child: Text(s.t('back'), style: const TextStyle(color: Q.muted))),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context).s;
    final challenge = _challenge;
    return Scaffold(
      body: SafeArea(
        child: ListView(
          // На цифровой клавиатуре iPhone нет кнопки «Готово»: клавиатура убирается жестом вниз.
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          children: [
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              if (canChangeServer)
                IconButton(onPressed: _editServer, icon: const Icon(Icons.dns_outlined, color: Q.muted))
              else
                const SizedBox(height: 48),
              const LangToggle(),
            ]),
            const SizedBox(height: 48),
            // ListView растягивает детей на всю ширину, поэтому логотип выравниваем явно.
            Align(
              alignment: Alignment.centerLeft,
              child: Container(
                width: 76,
                height: 76,
                decoration: BoxDecoration(color: Q.accent, borderRadius: BorderRadius.circular(26)),
                child: const Icon(Icons.near_me_rounded, size: 38, color: Q.onAccent),
              ),
            ),
            const SizedBox(height: 24),
            const Text('Qasynda', style: TextStyle(fontSize: 40, fontWeight: FontWeight.w900, height: 1)),
            const SizedBox(height: 8),
            Text(s.t('tagline'), style: const TextStyle(fontSize: 17, color: Q.muted)),
            const SizedBox(height: 40),
            ...(challenge == null ? _credentials(context) : _sms(context, challenge)),
          ],
        ),
      ),
    );
  }
}
