import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../api.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets.dart';
import '../widgets/code_cells.dart';
import '../widgets/pin_pad.dart';

enum _Step { phone, code, pin }

/// Вход в три шага: номер → код из SMS (только для нового телефона) → PIN.
/// С нового телефона PIN уходит на сервер только после верного кода.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _phone = TextEditingController(text: '+7');
  _Step _step = _Step.phone;
  SmsChallenge? _challenge;
  bool _busy = false;

  @override
  void dispose() {
    _phone.dispose();
    super.dispose();
  }

  bool get _phoneValid => RegExp(r'^\+7\d{10}$').hasMatch(_phone.text);

  Future<void> _start() async {
    final app = AppScope.of(context);
    setState(() => _busy = true);
    try {
      final challenge = await app.startLogin(_phone.text);
      if (!mounted) return;
      setState(() {
        _challenge = challenge;
        _step = challenge == null ? _Step.pin : _Step.code;
      });
    } on ApiError catch (e) {
      if (mounted) showError(context, app.s.error(e.code, e.detail));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _code(String code) async {
    final app = AppScope.of(context);
    try {
      await app.verifyCode(_challenge!, code);
      if (mounted) setState(() => _step = _Step.pin);
      return true;
    } on ApiError catch (e) {
      if (mounted) _failed(e);
      return false;
    }
  }

  Future<bool> _pin(String pin) async {
    final app = AppScope.of(context);
    final challenge = _challenge;
    try {
      if (challenge == null) {
        await app.login(_phone.text, pin);
      } else {
        await app.confirm(challenge, pin);
      }
      return true;
    } on ApiError catch (e) {
      if (mounted) _failed(e);
      return false;
    }
  }

  /// Запрос входа устарел или телефон перестал быть привязанным — вход начинается с номера.
  void _failed(ApiError e) {
    final s = AppScope.of(context).s;
    if (const {'challenge_expired', 'start_over', 'code_required'}.contains(e.code)) _back();
    showError(context, e.code == 'invalid_credentials' ? s.t('pinWrong') : s.error(e.code, e.detail));
  }

  void _back() => setState(() {
        _step = _Step.phone;
        _challenge = null;
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

  List<Widget> _phoneStep(BuildContext context) {
    final s = AppScope.of(context).s;
    final ready = _phoneValid && !_busy;
    return [
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
      TextField(
        controller: _phone,
        keyboardType: TextInputType.phone,
        autofillHints: const [AutofillHints.telephoneNumber],
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[+\d]')), LengthLimitingTextInputFormatter(12)],
        decoration: InputDecoration(labelText: s.t('phone')),
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) => ready ? _start() : null,
      ),
      const SizedBox(height: 24),
      FilledButton(
        onPressed: ready ? _start : null,
        child: _busy
            ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Q.onAccent))
            : Text(s.t('next')),
      ),
    ];
  }

  List<Widget> _header(BuildContext context, String title, String hint) {
    final s = AppScope.of(context).s;
    return [
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        TextButton.icon(
          onPressed: _back,
          icon: const Icon(Icons.arrow_back_rounded),
          label: Text(s.t('back')),
          style: TextButton.styleFrom(foregroundColor: Q.muted),
        ),
        const LangToggle(),
      ]),
      const SizedBox(height: 32),
      Text(title, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, height: 1.15)),
      const SizedBox(height: 8),
      Text(hint, style: const TextStyle(fontSize: 15, color: Q.muted, height: 1.35)),
    ];
  }

  List<Widget> _codeStep(BuildContext context, SmsChallenge challenge) {
    final s = AppScope.of(context).s;
    final demo = challenge.demoCode;
    return [
      ..._header(context, s.t('smsTitle'), s.t('smsHint', {'phone': _phone.text})),
      if (demo != null) ...[
        const SizedBox(height: 16),
        // Учебный режим сервера: настоящего SMS нет, код показывается здесь.
        Align(alignment: Alignment.centerLeft, child: Pill(icon: Icons.sms_outlined, label: s.t('demoSms', {'code': demo}), color: Q.blue)),
      ],
      const SizedBox(height: 24),
      CodeCells(
        key: ValueKey(challenge.id),
        onCompleted: _code,
        pasteLabel: s.t('paste'),
        semanticLabel: s.t('smsCode'),
      ),
    ];
  }

  List<Widget> _pinStep(BuildContext context) {
    final s = AppScope.of(context).s;
    return [
      ..._header(context, s.t('pinTitle'), s.t('pinHint', {'phone': _phone.text})),
      const SizedBox(height: 32),
      Center(child: PinPad(onSubmit: _pin, deleteLabel: s.t('pinDelete'))),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final challenge = _challenge;
    return Scaffold(
      body: SafeArea(
        child: ListView(
          // На цифровой клавиатуре iPhone нет кнопки «Готово»: клавиатура убирается жестом вниз.
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          children: switch (_step) {
            _Step.phone => _phoneStep(context),
            _Step.code => _codeStep(context, challenge!),
            _Step.pin => _pinStep(context),
          },
        ),
      ),
    );
  }
}
