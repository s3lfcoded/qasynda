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
  bool _busy = false;

  @override
  void dispose() {
    _phone.dispose();
    _pin.dispose();
    super.dispose();
  }

  bool get _valid => RegExp(r'^\+7\d{10}$').hasMatch(_phone.text) && RegExp(r'^\d{4,6}$').hasMatch(_pin.text);

  Future<void> _submit() async {
    final app = AppScope.of(context);
    setState(() => _busy = true);
    try {
      await app.login(_phone.text, _pin.text);
    } on ApiError catch (e) {
      if (mounted) showError(context, app.s.error(e.code));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

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

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context).s;
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          children: [
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              IconButton(onPressed: _editServer, icon: const Icon(Icons.dns_outlined, color: Q.muted)),
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
                child: const Icon(Icons.near_me_rounded, size: 38, color: Q.ink),
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
            FilledButton(
              onPressed: _valid && !_busy ? _submit : null,
              child: _busy
                  ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Q.ink))
                  : Text(s.t('login')),
            ),
          ],
        ),
      ),
    );
  }
}
