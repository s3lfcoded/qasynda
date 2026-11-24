import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../api.dart';
import '../l10n.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets.dart';
import '../widgets/code_cells.dart';
import '../widgets/phone_field.dart';
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
  /// Повторное SMS — не раньше чем через минуту.
  static const _resendAfter = 60;

  final _phone = TextEditingController();
  final _cells = GlobalKey<CodeCellsState>();
  _Step _step = _Step.phone;
  SmsChallenge? _challenge;
  bool _busy = false;
  DateTime? _sentAt;
  Timer? _tick;

  @override
  void dispose() {
    _tick?.cancel();
    _phone.dispose();
    super.dispose();
  }

  String get _number => '+7${phoneDigits(_phone.text)}';

  bool get _phoneValid => phoneDigits(_phone.text).length == 10;

  int get _resendLeft {
    final sent = _sentAt;
    if (sent == null) return 0;
    return math.max(0, _resendAfter - DateTime.now().difference(sent).inSeconds);
  }

  void _startResendTimer() {
    _tick?.cancel();
    _sentAt = DateTime.now();
    _tick = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      setState(() {});
      if (_resendLeft == 0) timer.cancel();
    });
  }

  void _stopResendTimer() {
    _tick?.cancel();
    _tick = null;
  }

  Future<void> _start() async {
    final app = AppScope.of(context);
    setState(() => _busy = true);
    try {
      final challenge = await app.startLogin(_number);
      if (!mounted) return;
      setState(() {
        _challenge = challenge;
        _step = challenge == null ? _Step.pin : _Step.code;
      });
      if (challenge != null) {
        _startResendTimer();
      } else {
        _stopResendTimer();
      }
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
      _stopResendTimer();
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
        await app.login(_number, pin);
      } else {
        // Первый вход с этого телефона: на главном предложим привязать карту, если карт нет.
        app.offerCards = true;
        await app.confirm(challenge, pin);
      }
      return true;
    } on ApiError catch (e) {
      app.offerCards = false;
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

  void _back() {
    _stopResendTimer();
    setState(() {
      _step = _Step.phone;
      _challenge = null;
    });
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

  Widget _phoneStep(BuildContext context, bool keyboard) {
    final s = AppScope.of(context).s;
    final ready = _phoneValid && !_busy;
    return SafeArea(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Q.gutter),
          child: SizedBox(
            height: 56,
            child: Row(children: [
              const QasyndaMark(size: 32),
              const SizedBox(width: 8),
              Text('Qasynda', style: Q.section.copyWith(color: Q.ink, letterSpacing: -0.2)),
              const Spacer(),
              if (canChangeServer)
                IconButton(
                  onPressed: _editServer,
                  tooltip: s.t('server'),
                  icon: const Icon(Icons.dns_outlined, color: Q.ink3, size: 20),
                ),
              const LangToggle(),
            ]),
          ),
        ),
        Expanded(
          child: ListView(
            // На цифровой клавиатуре iPhone нет кнопки «Готово»: клавиатура убирается жестом вниз.
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.fromLTRB(Q.gutter, 32, Q.gutter, 24),
            children: [
              Text(s.t('phoneTitle'), style: Q.title.copyWith(color: Q.ink)),
              const SizedBox(height: 8),
              Text(s.t('phoneHint'), style: Q.body),
              const SizedBox(height: 24),
              PhoneField(
                controller: _phone,
                label: s.t('phone'),
                clearLabel: s.t('clear'),
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => ready ? _start() : null,
              ),
            ],
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(Q.gutter, 0, Q.gutter, keyboard ? 12 : 8),
          child: QButton(label: s.t('continue'), onPressed: ready ? _start : null, busy: _busy),
        ),
      ]),
    );
  }

  Widget _codeStep(BuildContext context, SmsChallenge challenge) {
    final s = AppScope.of(context).s;
    final demo = challenge.demoCode;
    final left = _resendLeft;
    final Widget footer;
    if (left > 0) {
      final parts = s.t('resendIn').split('{t}');
      final time = '${left ~/ 60}:${(left % 60).toString().padLeft(2, '0')}';
      const style = TextStyle(fontSize: 15, height: 20 / 15, color: Q.ink2, fontFeatures: Q.tabular);
      footer = Text.rich(TextSpan(style: style, children: [
        TextSpan(text: parts.first),
        WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: RollingAmount(time, style: style),
        ),
        if (parts.length > 1) TextSpan(text: parts.last),
      ]));
    } else {
      footer = Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton(
          onPressed: _busy ? null : _start,
          style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8), minimumSize: const Size(0, 40)),
          child: Text(s.t('resend')),
        ),
      );
    }
    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(Q.gutter, 8, Q.gutter, 24),
      children: [
        Text(s.t('smsTitle'), style: Q.title.copyWith(color: Q.ink)),
        const SizedBox(height: 8),
        Text(s.t('smsHint', {'phone': phoneText(_number)}), style: Q.body),
        if (demo != null) ...[
          const SizedBox(height: 24),
          // Учебный режим сервера: настоящего SMS нет, код показывается здесь.
          Container(
            height: 48,
            padding: const EdgeInsetsDirectional.only(start: 16, end: 4),
            decoration: BoxDecoration(color: Q.amberSoft, borderRadius: BorderRadius.circular(16)),
            child: Row(children: [
              const Icon(Icons.sms_rounded, size: 20, color: Q.amberInk),
              const SizedBox(width: 12),
              Expanded(
                child: Text(s.t('demoSms', {'code': demo}),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Q.label.copyWith(color: Q.amberInk, fontFeatures: Q.tabular)),
              ),
              TextButton(
                onPressed: () => _cells.currentState?.fill(demo),
                style: TextButton.styleFrom(
                  foregroundColor: Q.amberInk,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  minimumSize: const Size(0, 40),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: Text(s.t('paste')),
              ),
            ]),
          ),
        ],
        const SizedBox(height: 24),
        CodeCells(
          key: _cells,
          onCompleted: _code,
          pasteLabel: s.t('paste'),
          semanticLabel: s.t('smsCode'),
          showPaste: demo == null,
          footer: footer,
        ),
      ],
    );
  }

  Widget _pinStep(BuildContext context) {
    final s = AppScope.of(context).s;
    return Column(children: [
      const SizedBox(height: 40),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: Q.gutter),
        child: Column(children: [
          Text(s.t('pinTitle'), textAlign: TextAlign.center, style: Q.titleM.copyWith(color: Q.ink)),
          const SizedBox(height: 8),
          Text(s.t('pinHint', {'phone': phoneText(_number)}),
              textAlign: TextAlign.center, style: Q.body.copyWith(fontFeatures: Q.tabular)),
        ]),
      ),
      const SizedBox(height: 40),
      Expanded(child: PinPad(onSubmit: _pin, deleteLabel: s.t('pinDelete'), expand: true)),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final challenge = _challenge;
    final keyboard = MediaQuery.viewInsetsOf(context).bottom > 0;
    // Шаги входа сменяют друг друга сдвигом, как экраны.
    final Widget body = switch (_step) {
      _Step.phone => _phoneStep(context, keyboard),
      _Step.code => SafeArea(top: false, child: _codeStep(context, challenge!)),
      _Step.pin => SafeArea(top: false, child: _pinStep(context)),
    };
    return PopScope(
      canPop: _step == _Step.phone,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        appBar: _step == _Step.phone ? null : QAppBar(onBack: _back),
        body: _StepSwitcher(step: _step.index, child: KeyedSubtree(key: ValueKey(_step), child: body)),
      ),
    );
  }
}

/// Смена шагов входа: новый шаг въезжает сдвигом и проявляется — вперёд справа, назад слева.
/// Старый шаг убирается сразу, чтобы на экране никогда не было двух клавиатур или полей.
class _StepSwitcher extends StatefulWidget {
  const _StepSwitcher({required this.step, required this.child});
  final int step;
  final Widget child;

  @override
  State<_StepSwitcher> createState() => _StepSwitcherState();
}

class _StepSwitcherState extends State<_StepSwitcher> {
  bool _forward = true;

  @override
  void didUpdateWidget(_StepSwitcher old) {
    super.didUpdateWidget(old);
    if (old.step != widget.step) _forward = widget.step > old.step;
  }

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.disableAnimationsOf(context);
    final dir = _forward ? 1.0 : -1.0;
    return TweenAnimationBuilder<double>(
      key: ValueKey(widget.step),
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: reduced ? 150 : (_forward ? 300 : 200)),
      curve: Curves.easeOutCubic,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: reduced ? child : FractionalTranslation(translation: Offset(dir * 0.08 * (1 - t), 0), child: child),
      ),
      child: widget.child,
    );
  }
}
